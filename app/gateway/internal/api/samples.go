package api

import "time"

// ClusterBackend provides the data a gateway serves. The sample implementation
// is used when no real Kubernetes client is wired in; production deployments
// are expected to substitute a real backend later.
type ClusterBackend interface {
	ListClusters() []ClusterProfile
	LoadSnapshot(clusterID string) (ClusterSnapshot, bool)
	LoadEvents(clusterID, kind, objectName, namespace string, limit int) []ClusterEvent
}

// SampleBackend is an in-memory backend that returns deterministic fixture
// data. It is intended for development and integration testing until a real
// Kubernetes client is plumbed in.
type SampleBackend struct {
	now func() time.Time
}

func NewSampleBackend() *SampleBackend {
	return &SampleBackend{now: time.Now}
}

func (s *SampleBackend) ListClusters() []ClusterProfile {
	return []ClusterProfile{sampleProfile()}
}

func (s *SampleBackend) LoadSnapshot(clusterID string) (ClusterSnapshot, bool) {
	profile := sampleProfile()
	if clusterID != "" && clusterID != profile.ID {
		return ClusterSnapshot{}, false
	}
	return sampleSnapshot(profile, s.now()), true
}

func (s *SampleBackend) LoadEvents(clusterID, kind, objectName, namespace string, limit int) []ClusterEvent {
	if limit <= 0 {
		limit = 5
	}
	events := sampleEvents(s.now(), kind, objectName)
	if len(events) > limit {
		events = events[:limit]
	}
	return events
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
			ID: "wl-api", Namespace: platformNS, Name: "api",
			Kind: "deployment", DesiredReplicas: 3, ReadyReplicas: 3,
			NodeIDs: []string{"node-worker-1"}, Health: "healthy",
			Images: []string{"ghcr.io/example/api:1.2.3"},
		},
	}
	services := []ClusterService{
		{
			ID: "svc-api", Namespace: platformNS, Name: "api",
			Exposure: "clusterIp", TargetWorkloadIDs: []string{"wl-api"},
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
		{SourceID: "wl-api", TargetID: "node-worker-1", Kind: "workload"},
		{SourceID: "svc-api", TargetID: "wl-api", Kind: "service"},
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
