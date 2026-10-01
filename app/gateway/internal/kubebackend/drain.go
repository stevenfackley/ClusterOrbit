package kubebackend

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/stevenfackley/clusterorbit/app/gateway/internal/api"
)

// drainJobRetention is how long a finished drain job stays pollable before
// the next StartDrain prunes it.
const drainJobRetention = time.Hour

// StartDrain cordons the node and kicks off background pod eviction, returning
// a Pending job immediately. If the node already has a Pending or Running job,
// that job is returned instead and no second worker starts. The eviction loop
// runs in a detached goroutine with its own deadline — it must NOT inherit the
// HTTP request context, which is cancelled the moment this handler returns.
func (b *KubeBackend) StartDrain(_ context.Context, clusterID, nodeID string) (api.DrainJob, error) {
	if clusterID != "" && clusterID != b.profile.ID {
		return api.DrainJob{}, api.ErrNotFound
	}
	// Validate before any worker starts: runDrain splices nodeID into API
	// paths and the pod fieldSelector.
	if err := api.ValidateNodeID(nodeID); err != nil {
		return api.DrainJob{}, err
	}

	b.drainMu.Lock()
	defer b.drainMu.Unlock()
	for _, job := range b.drainJobs {
		if job.NodeID == nodeID && !drainFinished(job) {
			return copyJob(job), nil
		}
	}

	now := b.now()
	b.pruneDrainJobs(now)
	job := &api.DrainJob{
		ID:        b.newJobID(),
		NodeID:    nodeID,
		Phase:     api.DrainPhasePending,
		Evicted:   []string{},
		Skipped:   []string{},
		StartedAt: now.UnixMilli(),
		UpdatedAt: now.UnixMilli(),
	}
	b.drainJobs[job.ID] = job

	// The worker blocks on drainMu until we return, so this copy is the
	// Pending state and can't race it.
	go b.runDrain(job.ID, nodeID)
	return copyJob(job), nil
}

func drainFinished(j *api.DrainJob) bool {
	return j.Phase == api.DrainPhaseSucceeded || j.Phase == api.DrainPhaseFailed
}

// pruneDrainJobs drops finished jobs last updated more than drainJobRetention
// before now. Callers hold drainMu.
func (b *KubeBackend) pruneDrainJobs(now time.Time) {
	cutoff := now.Add(-drainJobRetention).UnixMilli()
	for id, job := range b.drainJobs {
		if drainFinished(job) && job.UpdatedAt < cutoff {
			delete(b.drainJobs, id)
		}
	}
}

// DrainStatus returns a copy of the job's current state. ErrNotFound when the
// ID is unknown or belongs to a different node (defends against a client
// pairing a stale jobID with the wrong node path).
func (b *KubeBackend) DrainStatus(_ context.Context, clusterID, nodeID, jobID string) (api.DrainJob, error) {
	if clusterID != "" && clusterID != b.profile.ID {
		return api.DrainJob{}, api.ErrNotFound
	}
	b.drainMu.Lock()
	job, ok := b.drainJobs[jobID]
	if !ok || job.NodeID != nodeID {
		b.drainMu.Unlock()
		return api.DrainJob{}, api.ErrNotFound
	}
	out := copyJob(job)
	b.drainMu.Unlock()
	return out, nil
}

// copyJob deep-copies a job so callers never alias the slices the worker
// mutates under the lock.
func copyJob(j *api.DrainJob) api.DrainJob {
	out := *j
	out.Evicted = append([]string{}, j.Evicted...)
	out.Skipped = append([]string{}, j.Skipped...)
	return out
}

// update applies fn to the live job under the lock and bumps UpdatedAt.
func (b *KubeBackend) update(jobID string, fn func(*api.DrainJob)) {
	b.drainMu.Lock()
	defer b.drainMu.Unlock()
	job, ok := b.drainJobs[jobID]
	if !ok {
		return
	}
	fn(job)
	job.UpdatedAt = b.now().UnixMilli()
}

// drainWorkers bounds how many evictions one drain has in flight, so a single
// PDB-blocked pod doesn't hold up the rest of the node. Waiting for an evicted
// pod to terminate holds no worker.
const drainWorkers = 5

// runDrain is the background worker: cordon, enumerate pods, then evict the
// non-skipped ones respecting PodDisruptionBudgets (429 → back off and retry)
// and wait for each to be gone. A node running unmanaged pods fails the job
// before any eviction.
func (b *KubeBackend) runDrain(jobID, nodeID string) {
	ctx, cancel := context.WithTimeout(context.Background(), b.drainTimeout)
	defer cancel()

	b.update(jobID, func(j *api.DrainJob) { j.Phase = api.DrainPhaseRunning })

	if err := b.CordonNode(ctx, b.profile.ID, nodeID, true); err != nil {
		b.failDrain(jobID, fmt.Sprintf("cordon: %v", err))
		return
	}

	pods, err := b.listNodePods(ctx, nodeID)
	if err != nil {
		b.failDrain(jobID, fmt.Sprintf("list pods: %v", err))
		return
	}

	var evictable []podRef
	var unmanaged []string
	for _, pod := range pods {
		ref, action := classifyPod(pod)
		if ref.name == "" {
			continue
		}
		switch action {
		case podSkip:
			b.update(jobID, func(j *api.DrainJob) { j.Skipped = append(j.Skipped, ref.key()) })
		case podBlock:
			unmanaged = append(unmanaged, ref.key())
		default:
			evictable = append(evictable, ref)
		}
	}

	// Evicting a pod with no controller deletes it for good, so refuse the
	// whole drain before touching anything (kubectl drain without --force).
	// The node stays cordoned.
	if len(unmanaged) > 0 {
		b.failDrain(jobID, "refusing to drain: pods without a controller would be lost: "+
			strings.Join(unmanaged, ", "))
		return
	}

	b.update(jobID, func(j *api.DrainJob) { j.Remaining = len(evictable) })

	if err := b.evictAll(ctx, jobID, nodeID, evictable); err != nil {
		b.failDrain(jobID, err.Error())
		return
	}

	b.update(jobID, func(j *api.DrainJob) {
		j.Phase = api.DrainPhaseSucceeded
		j.Remaining = 0
	})
}

// listNodePods lists the pods bound to nodeID.
func (b *KubeBackend) listNodePods(ctx context.Context, nodeID string) ([]map[string]any, error) {
	query := url.Values{}
	query.Set("fieldSelector", "spec.nodeName="+nodeID)
	body, err := b.client.GetJSON(ctx, "/api/v1/pods", query)
	if err != nil {
		return nil, err
	}
	return listItems(body), nil
}

// evictAll evicts pods on up to drainWorkers goroutines and records each one
// once it is gone. A worker is busy only while its eviction (with any PDB
// backoff) is in flight; accepted evictions go to one poller, so the pods
// terminate together rather than drainWorkers at a time. The first failure
// cancels the rest and is returned.
func (b *KubeBackend) evictAll(ctx context.Context, jobID, nodeID string, pods []podRef) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	var (
		failOnce sync.Once
		firstErr error
	)
	fail := func(err error) {
		failOnce.Do(func() {
			firstErr = err
			cancel()
		})
	}

	// Room for every pod, so a worker never blocks on the poller.
	accepted := make(chan podRef, len(pods))
	polled := make(chan struct{})
	go func() {
		defer close(polled)
		if err := b.awaitPodsGone(ctx, jobID, nodeID, accepted); err != nil {
			fail(err)
		}
	}()

	var wg sync.WaitGroup
	work := make(chan podRef)
	for range min(drainWorkers, len(pods)) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for ref := range work {
				// Once cancelled, drain the queue without touching the API.
				err := ctx.Err()
				if err == nil {
					err = b.evictPod(ctx, ref)
				}
				if err != nil {
					fail(fmt.Errorf("evict %s: %w", ref.key(), err))
					continue
				}
				accepted <- ref
			}
		}()
	}
	for _, ref := range pods {
		work <- ref
	}
	close(work)
	wg.Wait()
	close(accepted)
	<-polled
	return firstErr
}

// awaitPodsGone waits for each pod received on accepted to be gone: deleted,
// or replaced by a same-named pod with a new UID, as kubectl drain checks.
// Rather than GET each pod, it lists the node's pods every drainPollInterval
// and records the pods missing from the list on the job. It returns nil once
// accepted is closed and every pod is gone, or an error if a list fails or
// ctx ends first.
func (b *KubeBackend) awaitPodsGone(ctx context.Context, jobID, nodeID string, accepted <-chan podRef) error {
	pending := map[podRef]struct{}{}
	timedOut := func() error {
		keys := make([]string, 0, len(pending))
		for ref := range pending {
			keys = append(keys, ref.key())
		}
		if len(keys) == 0 {
			return fmt.Errorf("timed out waiting for pod deletion: %w", ctx.Err())
		}
		sort.Strings(keys)
		return fmt.Errorf("timed out waiting for pod deletion of %s: %w", strings.Join(keys, ", "), ctx.Err())
	}

	tick := time.NewTicker(b.drainPollInterval)
	defer tick.Stop()
	for accepted != nil || len(pending) > 0 {
		select {
		case ref, ok := <-accepted:
			if ok {
				pending[ref] = struct{}{}
			} else {
				accepted = nil
			}
			continue
		case <-ctx.Done():
			return timedOut()
		case <-tick.C:
		}
		if len(pending) == 0 {
			continue
		}

		pods, err := b.listNodePods(ctx, nodeID)
		if err != nil {
			if ctx.Err() != nil {
				return timedOut()
			}
			return fmt.Errorf("list pods: %w", err)
		}
		present := make(map[podRef]struct{}, len(pods))
		for _, pod := range pods {
			ref, _ := classifyPod(pod)
			present[ref] = struct{}{}
		}
		var gone []string
		for ref := range pending {
			if _, ok := present[ref]; !ok {
				delete(pending, ref)
				gone = append(gone, ref.key())
			}
		}
		if len(gone) > 0 {
			sort.Strings(gone)
			b.update(jobID, func(j *api.DrainJob) {
				j.Evicted = append(j.Evicted, gone...)
				j.Remaining = max(j.Remaining-len(gone), 0)
			})
		}
	}
	return nil
}

func (b *KubeBackend) failDrain(jobID, msg string) {
	b.update(jobID, func(j *api.DrainJob) {
		j.Phase = api.DrainPhaseFailed
		j.Error = msg
	})
}

// podRef is the minimal identity needed to evict a pod and to tell it apart
// from a same-named replacement.
type podRef struct {
	namespace string
	name      string
	uid       string
}

func (p podRef) key() string { return p.namespace + "/" + p.name }

// podAction is what drain does with one pod on the node.
type podAction int

const (
	podEvict podAction = iota
	podSkip
	podBlock
)

// classifyPod returns the pod's identity and what drain should do with it.
// Skipped: DaemonSet-managed pods, mirror/static pods, and already-terminal
// (Succeeded/Failed) pods, which drain leaves in place (kubectl deletes
// terminal pods instead; they hold no running workload either way). Blocked:
// any other pod with no controller ownerReference, which nothing would
// recreate after eviction. Everything else is evicted. emptyDir data is not
// protected: like kubectl --delete-emptydir-data, eviction discards it.
func classifyPod(pod map[string]any) (ref podRef, action podAction) {
	ref = podRef{
		namespace: stringAt(pod, "metadata", "namespace"),
		name:      stringAt(pod, "metadata", "name"),
		uid:       stringAt(pod, "metadata", "uid"),
	}
	if ref.namespace == "" {
		ref.namespace = "default"
	}
	if ref.name == "" {
		return podRef{}, podSkip
	}

	if _, ok := mapAt(pod, "metadata", "annotations")["kubernetes.io/config.mirror"]; ok {
		return ref, podSkip
	}
	controlled := false
	for _, owner := range listAt(pod, "metadata", "ownerReferences") {
		m, ok := owner.(map[string]any)
		if !ok {
			continue
		}
		if stringAt(m, "kind") == "DaemonSet" {
			return ref, podSkip
		}
		if boolAt(m, "controller") {
			controlled = true
		}
	}
	switch strings.ToLower(stringAt(pod, "status", "phase")) {
	case "succeeded", "failed":
		return ref, podSkip
	}
	if !controlled {
		return ref, podBlock
	}
	return ref, podEvict
}

// evictPod POSTs an Eviction, retrying with exponential backoff while the API
// server returns 429 (a PodDisruptionBudget would be violated). 404/410 mean
// the pod is already gone — success. Honors the context deadline.
func (b *KubeBackend) evictPod(ctx context.Context, ref podRef) error {
	path := fmt.Sprintf("/api/v1/namespaces/%s/pods/%s/eviction", url.PathEscape(ref.namespace), url.PathEscape(ref.name))
	payload := []byte(fmt.Sprintf(
		`{"apiVersion":"policy/v1","kind":"Eviction","metadata":{"name":%q,"namespace":%q}}`,
		ref.name, ref.namespace,
	))

	backoff := b.drainBackoff
	for {
		status, respBody, err := b.client.Post(ctx, path, "application/json", payload)
		if err != nil {
			return err
		}
		switch {
		case status >= 200 && status < 300:
			return nil
		case status == 404 || status == 410:
			// Pod vanished between listing and eviction — treat as evicted.
			return nil
		case status == 429:
			select {
			case <-ctx.Done():
				return fmt.Errorf("timed out waiting for PodDisruptionBudget: %w", ctx.Err())
			case <-time.After(backoff):
			}
			backoff *= 2
			if backoff > b.drainMaxBackoff {
				backoff = b.drainMaxBackoff
			}
		default:
			return newStatusError(status, respBody)
		}
	}
}

// randomJobID returns a 128-bit hex string. crypto/rand failures are
// effectively impossible here; we fall back to a timestamp so a drain can
// still start rather than panicking.
func randomJobID() string {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		return fmt.Sprintf("job-%d", time.Now().UnixNano())
	}
	return hex.EncodeToString(buf)
}
