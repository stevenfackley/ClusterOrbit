package api

import (
	"context"
	"time"
)

// SampleBackend is an in-memory backend that returns deterministic fixture
// data. It is intended for development, integration testing, and demo mode.
type SampleBackend struct {
	now func() time.Time
}

func NewSampleBackend() *SampleBackend {
	return &SampleBackend{now: time.Now}
}

func (s *SampleBackend) ListClusters(_ context.Context) ([]ClusterProfile, error) {
	return []ClusterProfile{sampleProfile()}, nil
}

func (s *SampleBackend) LoadSnapshot(_ context.Context, clusterID string) (ClusterSnapshot, error) {
	profile := sampleProfile()
	if clusterID != "" && clusterID != profile.ID {
		return ClusterSnapshot{}, ErrNotFound
	}
	return sampleSnapshot(profile, s.now()), nil
}

// ScaleWorkload is a no-op on the sample backend — scale requests against
// fixture data have nowhere to land. We still validate the arguments so
// integration tests catch malformed clients without spinning up real kube.
func (s *SampleBackend) ScaleWorkload(_ context.Context, _, workloadID string, replicas int) error {
	if workloadID == "" {
		return ErrBadRequest
	}
	if replicas < 0 {
		return ErrBadRequest
	}
	return ErrUnsupported
}

// RestartWorkload mirrors ScaleWorkload: validate the id so integration tests
// catch malformed clients, then report ErrUnsupported since fixture data has
// nothing to restart.
func (s *SampleBackend) RestartWorkload(_ context.Context, _, workloadID string) error {
	if workloadID == "" {
		return ErrBadRequest
	}
	return ErrUnsupported
}

// CordonNode mirrors the other mutations on the sample backend: validate the
// id so integration tests catch malformed clients, then report ErrUnsupported
// since fixture nodes have nothing to cordon.
func (s *SampleBackend) CordonNode(_ context.Context, _, nodeID string, _ bool) error {
	if nodeID == "" {
		return ErrBadRequest
	}
	return ErrUnsupported
}

// StartDrain mirrors the other mutations on the sample backend: validate the
// id so integration tests catch malformed clients, then report ErrUnsupported
// since fixture nodes have nothing to drain.
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

func (s *SampleBackend) LoadEvents(_ context.Context, _, kind, objectName, _ string, limit int) ([]ClusterEvent, error) {
	if limit <= 0 {
		limit = 5
	}
	events := sampleEvents(s.now(), kind, objectName)
	if len(events) > limit {
		events = events[:limit]
	}
	return events, nil
}

func sampleProfile() ClusterProfile {
	return ClusterProfile{
		ID:               "gateway-demo",
		Name:             "gateway-demo",
		APIServerHost:    "https://gateway.local",
		EnvironmentLabel: "Demo",
		ConnectionMode:   "gateway",
	}
}

func sampleSnapshot(profile ClusterProfile, now time.Time) ClusterSnapshot {
	platformNS := "platform"
	clusterIP := "10.0.0.42"
	nodes := []ClusterNode{
		{
			ID: "node-cp-1", Name: "cp-1.gateway-demo",
			Role: "controlPlane", Version: "v1.30.1", Zone: "us-east-1a",
			PodCount: 22, Schedulable: true, Health: "healthy",
			CPUCapacity: "4 cores", MemoryCapacity: "16 GiB",
			OSImage: "Ubuntu 22.04 LTS",
		},
		{
			ID: "node-worker-1", Name: "worker-1.gateway-demo",
			Role: "worker", Version: "v1.30.1", Zone: "us-east-1a",
			PodCount: 48, Schedulable: true, Health: "healthy",
			CPUCapacity: "16 cores", MemoryCapacity: "64 GiB",
			OSImage: "Ubuntu 22.04 LTS",
		},
	}
	workloads := []ClusterWorkload{
		{
			ID: "deployment:platform/api", Namespace: platformNS, Name: "api",
			Kind: "deployment", DesiredReplicas: 3, ReadyReplicas: 3,
			NodeIDs: []string{"node-worker-1"}, Health: "healthy",
			Images: []string{"ghcr.io/example/api:1.2.3"},
		},
	}
	services := []ClusterService{
		{
			ID: "svc-api", Namespace: platformNS, Name: "api",
			Exposure: "clusterIp", TargetWorkloadIDs: []string{"deployment:platform/api"},
			Ports:  []ServicePort{{Port: 80, TargetPort: 8080, Protocol: "TCP"}},
			Health: "healthy", ClusterIP: &clusterIP,
		},
	}
	alerts := []ClusterAlert{
		{
			ID: "alert-healthy", Title: "Cluster healthy",
			Summary: "No active alerts reported from the gateway backend.",
			Level:   "healthy", Scope: "cluster",
		},
	}
	links := []TopologyLink{
		{SourceID: "deployment:platform/api", TargetID: "node-worker-1", Kind: "workload"},
		{SourceID: "svc-api", TargetID: "deployment:platform/api", Kind: "service"},
	}
	return ClusterSnapshot{
		Profile:     profile,
		GeneratedAt: now.UnixMilli(),
		Nodes:       nodes,
		Workloads:   workloads,
		Services:    services,
		Alerts:      alerts,
		Links:       links,
	}
}

func sampleEvents(now time.Time, _, objectName string) []ClusterEvent {
	return []ClusterEvent{
		{
			Type:          "normal",
			Reason:        "Synced",
			Message:       "Reconciliation complete for " + objectName,
			LastTimestamp: now.Add(-2 * time.Minute).UnixMilli(),
			Count:         1,
		},
	}
}
