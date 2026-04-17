package kubebackend

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stevenfackley/clusterorbit/app/gateway/internal/api"
	"github.com/stevenfackley/clusterorbit/app/gateway/internal/kubeconfig"
)

func TestMultiClusterBackendRoutesByID(t *testing.T) {
	emptyList := func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{"items": []any{}})
	}
	ts := httptest.NewServer(http.HandlerFunc(emptyList))
	defer ts.Close()

	clusters := []*kubeconfig.ResolvedCluster{
		{ContextName: "prod", ClusterName: "prod", Server: ts.URL},
		{ContextName: "stage", ClusterName: "stage", Server: ts.URL},
	}
	mb, errs := NewMultiClusterBackend(clusters)
	if len(errs) != 0 {
		t.Fatalf("unexpected errors: %v", errs)
	}
	if mb.Len() != 2 {
		t.Fatalf("Len = %d, want 2", mb.Len())
	}

	profiles, err := mb.ListClusters(context.Background())
	if err != nil {
		t.Fatalf("ListClusters: %v", err)
	}
	if len(profiles) != 2 {
		t.Fatalf("profiles = %+v", profiles)
	}

	if _, err := mb.LoadSnapshot(context.Background(), "prod"); err != nil {
		t.Fatalf("LoadSnapshot prod: %v", err)
	}
	if _, err := mb.LoadSnapshot(context.Background(), "unknown"); !errors.Is(err, api.ErrNotFound) {
		t.Fatalf("LoadSnapshot unknown = %v, want ErrNotFound", err)
	}
}

func TestMultiClusterBackendSkipsBadClusters(t *testing.T) {
	clusters := []*kubeconfig.ResolvedCluster{
		{ContextName: "good", Server: "https://example.com"},
		{ContextName: "bad", Server: "not a url"},
	}
	mb, errs := NewMultiClusterBackend(clusters)
	if mb.Len() != 1 {
		t.Fatalf("Len = %d, want 1 (bad cluster skipped)", mb.Len())
	}
	if len(errs) != 1 {
		t.Fatalf("expected 1 init error, got %v", errs)
	}
}
