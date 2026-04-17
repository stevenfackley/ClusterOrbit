package kubebackend

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/stevenfackley/clusterorbit/app/gateway/internal/api"
	"github.com/stevenfackley/clusterorbit/app/gateway/internal/kubeconfig"
)

// kubeRoutes is a tiny fake apiserver. Each path returns a Kubernetes-style
// list response for the resources the backend fetches.
type kubeRoutes map[string]any

func newFakeKubeServer(t *testing.T, routes kubeRoutes) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, ok := routes[r.URL.Path]
		if !ok {
			http.Error(w, "not routed: "+r.URL.Path, http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(body)
	}))
}

func list(items ...map[string]any) map[string]any {
	raw := make([]any, 0, len(items))
	for _, it := range items {
		raw = append(raw, it)
	}
	return map[string]any{"items": raw}
}

func TestKubeBackendLoadSnapshotTransformsLists(t *testing.T) {
	routes := kubeRoutes{
		"/api/v1/nodes": list(map[string]any{
			"metadata": map[string]any{
				"name":   "node-a",
				"labels": map[string]any{"node-role.kubernetes.io/control-plane": ""},
			},
			"spec": map[string]any{"unschedulable": false},
			"status": map[string]any{
				"conditions": []any{
					map[string]any{"type": "Ready", "status": "True"},
				},
				"capacity": map[string]any{"cpu": "4", "memory": "16Gi"},
				"nodeInfo": map[string]any{"kubeletVersion": "v1.30.0", "osImage": "Ubuntu"},
			},
		}),
		"/api/v1/pods": list(map[string]any{
			"metadata": map[string]any{
				"namespace": "platform",
				"name":      "api-pod-1",
				"labels":    map[string]any{"app": "api"},
				"ownerReferences": []any{
					map[string]any{"kind": "ReplicaSet", "name": "api-rs"},
				},
			},
			"spec": map[string]any{"nodeName": "node-a"},
			"status": map[string]any{
				"phase":             "Running",
				"containerStatuses": []any{map[string]any{"restartCount": float64(0)}},
			},
		}),
		"/api/v1/services": list(map[string]any{
			"metadata": map[string]any{"namespace": "platform", "name": "api"},
			"spec": map[string]any{
				"type":      "ClusterIP",
				"clusterIP": "10.0.0.1",
				"selector":  map[string]any{"app": "api"},
				"ports": []any{
					map[string]any{"port": float64(80), "targetPort": float64(8080), "protocol": "TCP"},
				},
			},
		}),
		"/apis/apps/v1/deployments": list(map[string]any{
			"metadata": map[string]any{"namespace": "platform", "name": "api"},
			"spec": map[string]any{
				"replicas": float64(1),
				"template": map[string]any{"spec": map[string]any{
					"containers": []any{map[string]any{"image": "ghcr.io/example/api:1.0"}},
				}},
			},
			"status": map[string]any{"readyReplicas": float64(1)},
		}),
		"/apis/apps/v1/daemonsets":   list(),
		"/apis/apps/v1/statefulsets": list(),
		"/apis/batch/v1/jobs":        list(),
		"/apis/apps/v1/replicasets": list(map[string]any{
			"metadata": map[string]any{
				"namespace": "platform",
				"name":      "api-rs",
				"ownerReferences": []any{
					map[string]any{"kind": "Deployment", "name": "api"},
				},
			},
		}),
	}
	ts := newFakeKubeServer(t, routes)
	defer ts.Close()

	backend, err := NewKubeBackend(&kubeconfig.ResolvedCluster{
		Server:      ts.URL,
		ContextName: "test",
		ClusterName: "test",
	})
	if err != nil {
		t.Fatalf("new backend: %v", err)
	}

	snap, err := backend.LoadSnapshot(context.Background(), "")
	if err != nil {
		t.Fatalf("LoadSnapshot: %v", err)
	}
	if snap.Profile.ID != "test" {
		t.Fatalf("profile id = %q", snap.Profile.ID)
	}
	if len(snap.Nodes) != 1 || snap.Nodes[0].Name != "node-a" {
		t.Fatalf("nodes = %+v", snap.Nodes)
	}
	if snap.Nodes[0].PodCount != 1 {
		t.Fatalf("expected 1 pod on node-a, got %d", snap.Nodes[0].PodCount)
	}
	if len(snap.Workloads) != 1 {
		t.Fatalf("workloads = %+v", snap.Workloads)
	}
	w := snap.Workloads[0]
	if w.Kind != "deployment" || w.Namespace != "platform" || w.Name != "api" {
		t.Fatalf("workload = %+v", w)
	}
	if w.DesiredReplicas != 1 || w.ReadyReplicas != 1 {
		t.Fatalf("workload replicas = %d/%d", w.ReadyReplicas, w.DesiredReplicas)
	}
	if len(w.NodeIDs) != 1 || w.NodeIDs[0] != "node-a" {
		t.Fatalf("workload nodeIDs = %+v", w.NodeIDs)
	}
	if len(snap.Services) != 1 {
		t.Fatalf("services = %+v", snap.Services)
	}
	s := snap.Services[0]
	if len(s.TargetWorkloadIDs) != 1 || !strings.HasSuffix(s.TargetWorkloadIDs[0], "platform/api") {
		t.Fatalf("service targets = %+v", s.TargetWorkloadIDs)
	}
	if s.ClusterIP == nil || *s.ClusterIP != "10.0.0.1" {
		t.Fatalf("service clusterIP = %+v", s.ClusterIP)
	}
	if len(snap.Links) < 2 {
		t.Fatalf("expected links (workload + service), got %+v", snap.Links)
	}
}

func TestKubeBackendLoadSnapshotUnknownClusterIsNotFound(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatalf("should not call apiserver for unknown cluster id")
	}))
	defer ts.Close()

	backend, err := NewKubeBackend(&kubeconfig.ResolvedCluster{
		Server: ts.URL, ContextName: "prod",
	})
	if err != nil {
		t.Fatalf("new backend: %v", err)
	}
	if _, err := backend.LoadSnapshot(context.Background(), "something-else"); !errors.Is(err, api.ErrNotFound) {
		t.Fatalf("expected ErrNotFound, got %v", err)
	}
}

func TestKubeBackendLoadEventsFiltersByFieldSelector(t *testing.T) {
	var gotQuery, gotPath string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotQuery = r.URL.RawQuery
		gotPath = r.URL.Path
		_ = json.NewEncoder(w).Encode(map[string]any{
			"items": []any{
				map[string]any{
					"type":          "Warning",
					"reason":        "Pulling",
					"message":       "pulling image",
					"lastTimestamp": "2026-04-16T10:00:00Z",
					"count":         float64(3),
					"source":        map[string]any{"component": "kubelet"},
				},
				map[string]any{
					"type":          "Normal",
					"reason":        "Created",
					"message":       "created container",
					"lastTimestamp": "2026-04-16T10:00:05Z",
				},
			},
		})
	}))
	defer ts.Close()

	backend, err := NewKubeBackend(&kubeconfig.ResolvedCluster{
		Server: ts.URL, ContextName: "test",
	})
	if err != nil {
		t.Fatalf("new backend: %v", err)
	}
	events, err := backend.LoadEvents(context.Background(), "test", "deployment", "api", "platform", 5)
	if err != nil {
		t.Fatalf("LoadEvents: %v", err)
	}
	if gotPath != "/api/v1/namespaces/platform/events" {
		t.Fatalf("path = %q", gotPath)
	}
	if !strings.Contains(gotQuery, "fieldSelector=") ||
		!strings.Contains(gotQuery, "involvedObject.name%3Dapi") ||
		!strings.Contains(gotQuery, "involvedObject.kind%3DDeployment") {
		t.Fatalf("query = %q", gotQuery)
	}
	if len(events) != 2 {
		t.Fatalf("events = %+v", events)
	}
	// newest first
	if events[0].Reason != "Created" {
		t.Fatalf("expected newest first, got %+v", events)
	}
	if events[1].SourceComponent == nil || *events[1].SourceComponent != "kubelet" {
		t.Fatalf("source = %+v", events[1].SourceComponent)
	}
	want := time.Date(2026, 4, 16, 10, 0, 5, 0, time.UTC).UnixMilli()
	if events[0].LastTimestamp != want {
		t.Fatalf("lastTimestamp = %d, want %d", events[0].LastTimestamp, want)
	}
}

func TestKubeBackendLoadEventsRequiresObjectName(t *testing.T) {
	backend, err := NewKubeBackend(&kubeconfig.ResolvedCluster{
		Server: "http://localhost", ContextName: "test",
	})
	if err != nil {
		t.Fatalf("new backend: %v", err)
	}
	if _, err := backend.LoadEvents(context.Background(), "test", "deployment", "", "", 5); err == nil {
		t.Fatalf("expected error for missing objectName")
	}
}

func TestKubeBackendScaleDeploymentPatchesScaleSubresource(t *testing.T) {
	var gotMethod, gotPath, gotContentType, gotBody string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod = r.Method
		gotPath = r.URL.Path
		gotContentType = r.Header.Get("Content-Type")
		buf := make([]byte, 256)
		n, _ := r.Body.Read(buf)
		gotBody = string(buf[:n])
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"kind":"Scale"}`))
	}))
	defer ts.Close()

	backend, err := NewKubeBackend(&kubeconfig.ResolvedCluster{
		Server: ts.URL, ContextName: "test",
	})
	if err != nil {
		t.Fatalf("new backend: %v", err)
	}

	if err := backend.ScaleWorkload(context.Background(), "test", "deployment:platform/api", 5); err != nil {
		t.Fatalf("ScaleWorkload: %v", err)
	}
	if gotMethod != "PATCH" {
		t.Fatalf("method = %q", gotMethod)
	}
	if gotPath != "/apis/apps/v1/namespaces/platform/deployments/api/scale" {
		t.Fatalf("path = %q", gotPath)
	}
	if gotContentType != "application/merge-patch+json" {
		t.Fatalf("content-type = %q", gotContentType)
	}
	if !strings.Contains(gotBody, `"replicas":5`) {
		t.Fatalf("body = %q", gotBody)
	}
}

func TestKubeBackendScaleRejectsBadID(t *testing.T) {
	backend, err := NewKubeBackend(&kubeconfig.ResolvedCluster{
		Server: "http://example.com", ContextName: "test",
	})
	if err != nil {
		t.Fatalf("new backend: %v", err)
	}
	if err := backend.ScaleWorkload(context.Background(), "test", "bogus-id", 1); !errors.Is(err, api.ErrBadRequest) {
		t.Fatalf("expected ErrBadRequest for bad id, got %v", err)
	}
	if err := backend.ScaleWorkload(context.Background(), "test", "daemonSet:ns/name", 1); !errors.Is(err, api.ErrBadRequest) {
		t.Fatalf("expected ErrBadRequest for non-scalable kind, got %v", err)
	}
	if err := backend.ScaleWorkload(context.Background(), "test", "deployment:ns/name", -1); !errors.Is(err, api.ErrBadRequest) {
		t.Fatalf("expected ErrBadRequest for negative replicas, got %v", err)
	}
}

func TestKubeBackendListClustersReturnsProfile(t *testing.T) {
	backend, err := NewKubeBackend(&kubeconfig.ResolvedCluster{
		Server:           "https://example.com",
		ContextName:      "prod-east",
		ClusterName:      "prod-east",
		EnvironmentLabel: "Production",
	})
	if err != nil {
		t.Fatalf("new backend: %v", err)
	}
	clusters, err := backend.ListClusters(context.Background())
	if err != nil {
		t.Fatalf("ListClusters: %v", err)
	}
	if len(clusters) != 1 {
		t.Fatalf("clusters = %+v", clusters)
	}
	if clusters[0].ID != "prod-east" {
		t.Fatalf("id = %q", clusters[0].ID)
	}
	if clusters[0].APIServerHost != "example.com" {
		t.Fatalf("apiServerHost = %q", clusters[0].APIServerHost)
	}
	if clusters[0].ConnectionMode != "gateway" {
		t.Fatalf("connectionMode = %q", clusters[0].ConnectionMode)
	}
}
