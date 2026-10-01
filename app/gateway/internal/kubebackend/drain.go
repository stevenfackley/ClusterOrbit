package kubebackend

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/stevenfackley/clusterorbit/app/gateway/internal/api"
)

// StartDrain cordons the node and kicks off background pod eviction, returning
// a Pending job immediately. The eviction loop runs in a detached goroutine
// with its own deadline — it must NOT inherit the HTTP request context, which
// is cancelled the moment this handler returns.
func (b *KubeBackend) StartDrain(_ context.Context, clusterID, nodeID string) (api.DrainJob, error) {
	if clusterID != "" && clusterID != b.profile.ID {
		return api.DrainJob{}, api.ErrNotFound
	}
	if nodeID == "" {
		return api.DrainJob{}, fmt.Errorf("%w: nodeID is required", api.ErrBadRequest)
	}

	now := b.now().UnixMilli()
	job := &api.DrainJob{
		ID:        b.newJobID(),
		NodeID:    nodeID,
		Phase:     api.DrainPhasePending,
		Evicted:   []string{},
		Skipped:   []string{},
		StartedAt: now,
		UpdatedAt: now,
	}

	b.drainMu.Lock()
	b.drainJobs[job.ID] = job
	b.drainMu.Unlock()

	go b.runDrain(job.ID, nodeID)

	// Return a snapshot copy so the caller can't race the worker.
	return b.snapshotJob(job.ID)
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

// snapshotJob returns a locked copy of a job by ID. Assumes the job exists
// (StartDrain just registered it).
func (b *KubeBackend) snapshotJob(jobID string) (api.DrainJob, error) {
	b.drainMu.Lock()
	defer b.drainMu.Unlock()
	job, ok := b.drainJobs[jobID]
	if !ok {
		return api.DrainJob{}, api.ErrNotFound
	}
	return copyJob(job), nil
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

// drainWorkers bounds how many pods one drain evicts at once, so a single
// PDB-blocked pod doesn't hold up the rest of the node.
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

	query := url.Values{}
	query.Set("fieldSelector", "spec.nodeName="+nodeID)
	body, err := b.client.GetJSON(ctx, "/api/v1/pods", query)
	if err != nil {
		b.failDrain(jobID, fmt.Sprintf("list pods: %v", err))
		return
	}

	var evictable []podRef
	var unmanaged []string
	for _, pod := range listItems(body) {
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

	if err := b.evictAll(ctx, jobID, evictable); err != nil {
		b.failDrain(jobID, err.Error())
		return
	}

	b.update(jobID, func(j *api.DrainJob) {
		j.Phase = api.DrainPhaseSucceeded
		j.Remaining = 0
	})
}

// evictAll evicts pods on up to drainWorkers goroutines, recording each one
// once it is gone. It returns the first failure, which cancels the rest.
func (b *KubeBackend) evictAll(ctx context.Context, jobID string, pods []podRef) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	var (
		wg       sync.WaitGroup
		failOnce sync.Once
		firstErr error
	)
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
				if err == nil {
					err = b.waitPodGone(ctx, ref)
				}
				if err != nil {
					failOnce.Do(func() {
						firstErr = fmt.Errorf("evict %s: %w", ref.key(), err)
						cancel()
					})
					continue
				}
				b.update(jobID, func(j *api.DrainJob) {
					j.Evicted = append(j.Evicted, ref.key())
					if j.Remaining > 0 {
						j.Remaining--
					}
				})
			}
		}()
	}
	for _, ref := range pods {
		work <- ref
	}
	close(work)
	wg.Wait()
	return firstErr
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
	path := fmt.Sprintf("/api/v1/namespaces/%s/pods/%s/eviction", ref.namespace, ref.name)
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

// waitPodGone polls the pod until it is deleted (404) or replaced by a new pod
// with the same name (different UID), as kubectl drain does. Honors the
// context deadline.
func (b *KubeBackend) waitPodGone(ctx context.Context, ref podRef) error {
	path := fmt.Sprintf("/api/v1/namespaces/%s/pods/%s", ref.namespace, ref.name)
	for {
		pod, err := b.client.GetJSON(ctx, path, nil)
		var statusErr *StatusError
		switch {
		case errors.As(err, &statusErr) && statusErr.Code == http.StatusNotFound:
			return nil
		case err == nil && stringAt(pod, "metadata", "uid") != ref.uid:
			return nil
		case err != nil && ctx.Err() == nil:
			return err
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("timed out waiting for pod deletion: %w", ctx.Err())
		case <-time.After(b.drainPollInterval):
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
