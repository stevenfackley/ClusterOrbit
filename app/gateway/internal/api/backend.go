package api

import (
	"context"
	"errors"
)

// ErrNotFound is returned by ClusterBackend implementations when the caller
// references a cluster ID the backend does not know about. Handlers map it
// to HTTP 404. Any other error is treated as an upstream failure (502).
var ErrNotFound = errors.New("cluster not found")

// ClusterBackend provides the data a gateway serves. The sample implementation
// is used for development and integration testing; the kube implementation
// talks to a real Kubernetes API server.
type ClusterBackend interface {
	ListClusters(ctx context.Context) ([]ClusterProfile, error)
	LoadSnapshot(ctx context.Context, clusterID string) (ClusterSnapshot, error)
	LoadEvents(ctx context.Context, clusterID, kind, objectName, namespace string, limit int) ([]ClusterEvent, error)
	// ScaleWorkload updates a Deployment or StatefulSet's replica count.
	// workloadID is "{kind}:{namespace}/{name}" per the snapshot schema.
	// Backends that don't support mutations may return ErrUnsupported.
	ScaleWorkload(ctx context.Context, clusterID, workloadID string, replicas int) error
	// RestartWorkload triggers a rolling restart of a Deployment, StatefulSet,
	// or DaemonSet by touching its pod template (kubectl rollout restart
	// semantics). workloadID is "{kind}:{namespace}/{name}". Backends that
	// don't support mutations may return ErrUnsupported.
	RestartWorkload(ctx context.Context, clusterID, workloadID string) error
	// CordonNode toggles a node's schedulability (spec.unschedulable). Pass
	// unschedulable=true to cordon, false to uncordon. nodeID is the node name
	// (snapshot node IDs equal their names). Backends that don't support
	// mutations may return ErrUnsupported. Note: this does not evict pods —
	// draining is a separate, multi-step operation.
	CordonNode(ctx context.Context, clusterID, nodeID string, unschedulable bool) error
	// StartDrain cordons a node and evicts its pods in the background, returning
	// a DrainJob handle to poll. nodeID is the node name. Backends that don't
	// support mutations may return ErrUnsupported.
	StartDrain(ctx context.Context, clusterID, nodeID string) (DrainJob, error)
	// DrainStatus returns the current state of a drain job by its ID.
	// ErrNotFound when the job is unknown to the backend.
	DrainStatus(ctx context.Context, clusterID, nodeID, jobID string) (DrainJob, error)
}

// ErrUnsupported indicates a backend cannot perform a requested mutation
// (e.g. sample mode). Handlers map it to 501.
var ErrUnsupported = errors.New("operation not supported by this backend")

// ErrBadRequest is a sentinel for malformed caller input surfaced from a
// backend (bad workload ID, negative replicas, etc). Handlers map it to 400.
var ErrBadRequest = errors.New("invalid request")
