package api

import "context"

// Drain phase values. A job starts Pending, moves to Running once the worker
// picks it up, and ends Succeeded or Failed. These strings cross the wire to
// the mobile client, so don't rename them without updating the app.
const (
	DrainPhasePending   = "pending"
	DrainPhaseRunning   = "running"
	DrainPhaseSucceeded = "succeeded"
	DrainPhaseFailed    = "failed"
)

// DrainJob is the observable state of an asynchronous node drain. StartDrain
// returns one in the Pending/Running phase with a freshly minted ID; the
// client polls DrainStatus with that ID until Phase is terminal.
//
// Evicted and Skipped hold "namespace/name" pod identifiers. Skipped covers
// DaemonSet-managed, mirror/static, and already-terminal pods that drain
// intentionally leaves in place (kubectl drain semantics). Remaining is the
// count of still-to-evict pods; it reaches 0 on success.
type DrainJob struct {
	ID        string   `json:"id"`
	NodeID    string   `json:"nodeId"`
	Phase     string   `json:"phase"`
	Evicted   []string `json:"evicted"`
	Skipped   []string `json:"skipped"`
	Remaining int      `json:"remaining"`
	Error     string   `json:"error,omitempty"`
	StartedAt int64    `json:"startedAt"`
	UpdatedAt int64    `json:"updatedAt"`
}

// StartDrain begins draining a node: cordon, then evict every non-skipped pod
// respecting PodDisruptionBudgets. It returns immediately with a job handle;
// the eviction work runs in the background. Backends that can't drain (sample
// mode) return ErrUnsupported.
func (s *SampleBackend) StartDrain(_ context.Context, _, nodeID string) (DrainJob, error) {
	if nodeID == "" {
		return DrainJob{}, ErrBadRequest
	}
	return DrainJob{}, ErrUnsupported
}

// DrainStatus returns the current state of a previously started drain job.
// ErrNotFound when the job ID is unknown. Sample mode never starts jobs, so it
// validates input and reports ErrUnsupported.
func (s *SampleBackend) DrainStatus(_ context.Context, _, nodeID, jobID string) (DrainJob, error) {
	if nodeID == "" || jobID == "" {
		return DrainJob{}, ErrBadRequest
	}
	return DrainJob{}, ErrUnsupported
}
