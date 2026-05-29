package kubebackend

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"net/url"
	"strings"
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

// runDrain is the background worker: cordon, enumerate pods, then evict the
// non-skipped ones respecting PodDisruptionBudgets (429 → back off and retry).
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
	for _, pod := range listItems(body) {
		ref, skip := classifyPod(pod)
		if ref.name == "" {
			continue
		}
		if skip {
			b.update(jobID, func(j *api.DrainJob) { j.Skipped = append(j.Skipped, ref.key()) })
			continue
		}
		evictable = append(evictable, ref)
	}

	b.update(jobID, func(j *api.DrainJob) { j.Remaining = len(evictable) })

	for _, ref := range evictable {
		if err := b.evictPod(ctx, ref); err != nil {
			b.failDrain(jobID, fmt.Sprintf("evict %s: %v", ref.key(), err))
			return
		}
		b.update(jobID, func(j *api.DrainJob) {
			j.Evicted = append(j.Evicted, ref.key())
			if j.Remaining > 0 {
				j.Remaining--
			}
		})
	}

	b.update(jobID, func(j *api.DrainJob) {
		j.Phase = api.DrainPhaseSucceeded
		j.Remaining = 0
	})
}

func (b *KubeBackend) failDrain(jobID, msg string) {
	b.update(jobID, func(j *api.DrainJob) {
		j.Phase = api.DrainPhaseFailed
		j.Error = msg
	})
}

// podRef is the minimal identity needed to evict a pod.
type podRef struct {
	namespace string
	name      string
}

func (p podRef) key() string { return p.namespace + "/" + p.name }

// classifyPod returns the pod's identity and whether drain should skip it.
// Mirrors kubectl drain: skip DaemonSet-managed pods, mirror/static pods, and
// already-terminal (Succeeded/Failed) pods.
func classifyPod(pod map[string]any) (ref podRef, skip bool) {
	ref = podRef{
		namespace: stringAt(pod, "metadata", "namespace"),
		name:      stringAt(pod, "metadata", "name"),
	}
	if ref.namespace == "" {
		ref.namespace = "default"
	}
	if ref.name == "" {
		return podRef{}, false
	}

	if _, ok := mapAt(pod, "metadata", "annotations")["kubernetes.io/config.mirror"]; ok {
		return ref, true
	}
	for _, owner := range listAt(pod, "metadata", "ownerReferences") {
		m, ok := owner.(map[string]any)
		if !ok {
			continue
		}
		if stringAt(m, "kind") == "DaemonSet" {
			return ref, true
		}
	}
	switch strings.ToLower(stringAt(pod, "status", "phase")) {
	case "succeeded", "failed":
		return ref, true
	}
	return ref, false
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
			return fmt.Errorf("eviction returned %d: %s", status, strings.TrimSpace(string(respBody)))
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
