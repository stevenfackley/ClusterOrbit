package kubebackend

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stevenfackley/clusterorbit/app/gateway/internal/api"
	"github.com/stevenfackley/clusterorbit/app/gateway/internal/kubeconfig"
)

// drainPods returns a pod list for worker-1 covering each classification:
// two evictable (ReplicaSet-controlled) pods, plus a DaemonSet pod, a
// mirror/static pod, and an already-Succeeded pod that drain must skip.
func drainPods() map[string]any {
	return list(
		map[string]any{
			"metadata": map[string]any{
				"namespace":       "platform",
				"name":            "api-1",
				"ownerReferences": []any{map[string]any{"kind": "ReplicaSet", "name": "api-rs", "controller": true}},
			},
			"status": map[string]any{"phase": "Running"},
		},
		map[string]any{
			"metadata": map[string]any{
				"namespace":       "platform",
				"name":            "api-2",
				"ownerReferences": []any{map[string]any{"kind": "ReplicaSet", "name": "api-rs", "controller": true}},
			},
			"status": map[string]any{"phase": "Running"},
		},
		map[string]any{
			"metadata": map[string]any{
				"namespace":       "kube-system",
				"name":            "ds-1",
				"ownerReferences": []any{map[string]any{"kind": "DaemonSet", "name": "fluentd", "controller": true}},
			},
			"status": map[string]any{"phase": "Running"},
		},
		map[string]any{
			"metadata": map[string]any{
				"namespace":   "kube-system",
				"name":        "mirror-1",
				"annotations": map[string]any{"kubernetes.io/config.mirror": "abc123"},
			},
			"status": map[string]any{"phase": "Running"},
		},
		map[string]any{
			"metadata": map[string]any{
				"namespace":       "batch",
				"name":            "job-1",
				"ownerReferences": []any{map[string]any{"kind": "Job", "name": "nightly", "controller": true}},
			},
			"status": map[string]any{"phase": "Succeeded"},
		},
	)
}

func newDrainBackend(t *testing.T, serverURL string) *KubeBackend {
	t.Helper()
	b, err := NewKubeBackend(&kubeconfig.ResolvedCluster{Server: serverURL, ContextName: "test"})
	if err != nil {
		t.Fatalf("new backend: %v", err)
	}
	// Keep PDB-retry backoff and pod-gone polling tiny so the test runs fast.
	b.drainBackoff = time.Millisecond
	b.drainMaxBackoff = 5 * time.Millisecond
	b.drainPollInterval = time.Millisecond
	b.newJobID = func() string { return "job-1" }
	return b
}

func waitDrain(t *testing.T, b *KubeBackend, node, jobID string) api.DrainJob {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		job, err := b.DrainStatus(context.Background(), "test", node, jobID)
		if err != nil {
			t.Fatalf("DrainStatus: %v", err)
		}
		if job.Phase == api.DrainPhaseSucceeded || job.Phase == api.DrainPhaseFailed {
			return job
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatalf("drain did not reach a terminal phase in time")
	return api.DrainJob{}
}

// waitUntil polls cond until it holds, failing the test after 3s.
func waitUntil(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

// managedPod is a running, ReplicaSet-controlled pod in namespace platform.
func managedPod(name, uid string) map[string]any {
	return map[string]any{
		"metadata": map[string]any{
			"namespace":       "platform",
			"name":            name,
			"uid":             uid,
			"ownerReferences": []any{map[string]any{"kind": "ReplicaSet", "name": "api-rs", "controller": true}},
		},
		"status": map[string]any{"phase": "Running"},
	}
}

func TestKubeBackendDrainCordonsAndEvictsWithPDBRetry(t *testing.T) {
	var mu sync.Mutex
	cordonCalls := 0
	evictionCalls := map[string]int{}

	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPatch && r.URL.Path == "/api/v1/nodes/worker-1":
			mu.Lock()
			cordonCalls++
			mu.Unlock()
			_, _ = w.Write([]byte(`{"kind":"Node"}`))
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/pods":
			if !strings.Contains(r.URL.RawQuery, "spec.nodeName") {
				t.Errorf("pod list missing nodeName selector: %q", r.URL.RawQuery)
			}
			_ = json.NewEncoder(w).Encode(drainPods())
		case r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/eviction"):
			mu.Lock()
			evictionCalls[r.URL.Path]++
			n := evictionCalls[r.URL.Path]
			mu.Unlock()
			// First eviction of api-1 is blocked by a PodDisruptionBudget.
			if strings.Contains(r.URL.Path, "/pods/api-1/") && n == 1 {
				http.Error(w, "Cannot evict pod as it would violate the pod's disruption budget.", http.StatusTooManyRequests)
				return
			}
			w.WriteHeader(http.StatusCreated)
			_, _ = w.Write([]byte(`{"kind":"Eviction"}`))
		default:
			http.Error(w, "not routed: "+r.Method+" "+r.URL.Path, http.StatusNotFound)
		}
	}))
	defer ts.Close()

	b := newDrainBackend(t, ts.URL)

	started, err := b.StartDrain(context.Background(), "test", "worker-1")
	if err != nil {
		t.Fatalf("StartDrain: %v", err)
	}
	if started.ID != "job-1" || started.NodeID != "worker-1" {
		t.Fatalf("started job = %+v", started)
	}

	final := waitDrain(t, b, "worker-1", "job-1")
	if final.Phase != api.DrainPhaseSucceeded {
		t.Fatalf("phase = %q, error = %q", final.Phase, final.Error)
	}
	if final.Remaining != 0 {
		t.Fatalf("remaining = %d, want 0", final.Remaining)
	}
	if !containsAll(final.Evicted, "platform/api-1", "platform/api-2") {
		t.Fatalf("evicted = %+v", final.Evicted)
	}
	if !containsAll(final.Skipped, "kube-system/ds-1", "kube-system/mirror-1", "batch/job-1") {
		t.Fatalf("skipped = %+v", final.Skipped)
	}

	mu.Lock()
	defer mu.Unlock()
	if cordonCalls < 1 {
		t.Fatalf("expected node to be cordoned, cordonCalls = %d", cordonCalls)
	}
	if evictionCalls["/api/v1/namespaces/platform/pods/api-1/eviction"] != 2 {
		t.Fatalf("api-1 should be retried after 429, calls = %d",
			evictionCalls["/api/v1/namespaces/platform/pods/api-1/eviction"])
	}
	if evictionCalls["/api/v1/namespaces/platform/pods/api-2/eviction"] != 1 {
		t.Fatalf("api-2 eviction calls = %d, want 1",
			evictionCalls["/api/v1/namespaces/platform/pods/api-2/eviction"])
	}
	if _, ok := evictionCalls["/api/v1/namespaces/kube-system/pods/ds-1/eviction"]; ok {
		t.Fatalf("DaemonSet pod should not be evicted")
	}
}

func TestKubeBackendDrainRejectsBadInput(t *testing.T) {
	b := newDrainBackend(t, "http://example.com")
	if _, err := b.StartDrain(context.Background(), "test", ""); !errors.Is(err, api.ErrBadRequest) {
		t.Fatalf("empty node: expected ErrBadRequest, got %v", err)
	}
	if _, err := b.StartDrain(context.Background(), "other", "worker-1"); !errors.Is(err, api.ErrNotFound) {
		t.Fatalf("unknown cluster: expected ErrNotFound, got %v", err)
	}
}

func TestKubeBackendDrainStatusUnknownJobIsNotFound(t *testing.T) {
	b := newDrainBackend(t, "http://example.com")
	if _, err := b.DrainStatus(context.Background(), "test", "worker-1", "nope"); !errors.Is(err, api.ErrNotFound) {
		t.Fatalf("expected ErrNotFound for unknown job, got %v", err)
	}
}

func TestKubeBackendDrainFailsWhenEvictionErrors(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPatch:
			_, _ = w.Write([]byte(`{"kind":"Node"}`))
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/pods":
			_ = json.NewEncoder(w).Encode(drainPods())
		case strings.HasSuffix(r.URL.Path, "/eviction"):
			http.Error(w, "boom", http.StatusInternalServerError)
		default:
			http.Error(w, "not routed", http.StatusNotFound)
		}
	}))
	defer ts.Close()

	b := newDrainBackend(t, ts.URL)
	if _, err := b.StartDrain(context.Background(), "test", "worker-1"); err != nil {
		t.Fatalf("StartDrain: %v", err)
	}
	final := waitDrain(t, b, "worker-1", "job-1")
	if final.Phase != api.DrainPhaseFailed {
		t.Fatalf("phase = %q, want failed", final.Phase)
	}
	if final.Error == "" {
		t.Fatalf("expected an error message on failed drain")
	}
}

func TestKubeBackendDrainWaitsUntilEvictedPodIsGone(t *testing.T) {
	// Once released, the pod GET reports the pod gone in one of the two ways
	// kubectl accepts: deleted, or replaced by a same-named pod (new UID).
	cases := map[string]func(http.ResponseWriter){
		"deleted": func(w http.ResponseWriter) { http.Error(w, "not found", http.StatusNotFound) },
		"replaced": func(w http.ResponseWriter) {
			_, _ = w.Write([]byte(`{"metadata":{"name":"api-1","uid":"uid-2"}}`))
		},
	}
	for name, gone := range cases {
		t.Run(name, func(t *testing.T) {
			var released atomic.Bool
			var polls atomic.Int32
			ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch {
				case r.Method == http.MethodPatch:
					_, _ = w.Write([]byte(`{"kind":"Node"}`))
				case r.Method == http.MethodGet && r.URL.Path == "/api/v1/pods":
					_ = json.NewEncoder(w).Encode(list(managedPod("api-1", "uid-1")))
				case r.Method == http.MethodPost && r.URL.Path == "/api/v1/namespaces/platform/pods/api-1/eviction":
					w.WriteHeader(http.StatusCreated)
				case r.Method == http.MethodGet && r.URL.Path == "/api/v1/namespaces/platform/pods/api-1":
					polls.Add(1)
					if released.Load() {
						gone(w)
						return
					}
					_, _ = w.Write([]byte(`{"metadata":{"name":"api-1","uid":"uid-1"}}`))
				default:
					http.Error(w, "not routed", http.StatusNotFound)
				}
			}))
			defer ts.Close()

			b := newDrainBackend(t, ts.URL)
			if _, err := b.StartDrain(context.Background(), "test", "worker-1"); err != nil {
				t.Fatalf("StartDrain: %v", err)
			}
			var job api.DrainJob
			waitUntil(t, "the evicted pod to be polled", func() bool {
				job, _ = b.DrainStatus(context.Background(), "test", "worker-1", "job-1")
				if job.Phase == api.DrainPhaseSucceeded || job.Phase == api.DrainPhaseFailed {
					t.Fatalf("drain finished while the evicted pod still exists: %+v", job)
				}
				return polls.Load() >= 2
			})
			if job.Phase != api.DrainPhaseRunning || job.Remaining != 1 || len(job.Evicted) != 0 {
				t.Fatalf("while the pod lingers, job = %+v", job)
			}

			released.Store(true)
			final := waitDrain(t, b, "worker-1", "job-1")
			if final.Phase != api.DrainPhaseSucceeded || final.Remaining != 0 {
				t.Fatalf("phase = %q, remaining = %d, error = %q", final.Phase, final.Remaining, final.Error)
			}
			if !containsAll(final.Evicted, "platform/api-1") {
				t.Fatalf("evicted = %+v", final.Evicted)
			}
		})
	}
}

func TestKubeBackendDrainFailsWhenEvictedPodLingers(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPatch:
			_, _ = w.Write([]byte(`{"kind":"Node"}`))
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/pods":
			_ = json.NewEncoder(w).Encode(list(managedPod("api-1", "uid-1")))
		case strings.HasSuffix(r.URL.Path, "/eviction"):
			w.WriteHeader(http.StatusCreated)
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/namespaces/platform/pods/api-1":
			_, _ = w.Write([]byte(`{"metadata":{"name":"api-1","uid":"uid-1"}}`))
		default:
			http.Error(w, "not routed", http.StatusNotFound)
		}
	}))
	defer ts.Close()

	b := newDrainBackend(t, ts.URL)
	b.drainTimeout = 50 * time.Millisecond
	if _, err := b.StartDrain(context.Background(), "test", "worker-1"); err != nil {
		t.Fatalf("StartDrain: %v", err)
	}
	final := waitDrain(t, b, "worker-1", "job-1")
	if final.Phase != api.DrainPhaseFailed || !strings.Contains(final.Error, "waiting for pod deletion") {
		t.Fatalf("phase = %q, error = %q, want a deletion timeout", final.Phase, final.Error)
	}
	if len(final.Evicted) != 0 || final.Remaining != 1 {
		t.Fatalf("lingering pod must not count as evicted: %+v", final)
	}
}

func TestKubeBackendDrainEvictsPastAPDBBlockedPod(t *testing.T) {
	var released atomic.Bool
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPatch:
			_, _ = w.Write([]byte(`{"kind":"Node"}`))
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/pods":
			_ = json.NewEncoder(w).Encode(list(
				managedPod("api-1", "uid-1"),
				managedPod("api-2", "uid-2"),
				managedPod("api-3", "uid-3"),
			))
		case r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/eviction"):
			// api-1 is held by its PodDisruptionBudget until released.
			if strings.Contains(r.URL.Path, "/pods/api-1/") && !released.Load() {
				http.Error(w, "would violate the pod's disruption budget", http.StatusTooManyRequests)
				return
			}
			w.WriteHeader(http.StatusCreated)
		default:
			// Includes the pod GETs: 404 means the evicted pod is gone.
			http.Error(w, "not routed", http.StatusNotFound)
		}
	}))
	defer ts.Close()

	b := newDrainBackend(t, ts.URL)
	if _, err := b.StartDrain(context.Background(), "test", "worker-1"); err != nil {
		t.Fatalf("StartDrain: %v", err)
	}
	var job api.DrainJob
	waitUntil(t, "api-2 and api-3 to be evicted past the blocked api-1", func() bool {
		job, _ = b.DrainStatus(context.Background(), "test", "worker-1", "job-1")
		if job.Phase == api.DrainPhaseSucceeded || job.Phase == api.DrainPhaseFailed {
			t.Fatalf("drain finished while api-1 is still blocked: %+v", job)
		}
		return containsAll(job.Evicted, "platform/api-2", "platform/api-3")
	})
	if containsAll(job.Evicted, "platform/api-1") || job.Remaining != 1 {
		t.Fatalf("api-1 should still be pending, job = %+v", job)
	}

	released.Store(true)
	final := waitDrain(t, b, "worker-1", "job-1")
	if final.Phase != api.DrainPhaseSucceeded {
		t.Fatalf("phase = %q, error = %q", final.Phase, final.Error)
	}
	if !containsAll(final.Evicted, "platform/api-1", "platform/api-2", "platform/api-3") {
		t.Fatalf("evicted = %+v", final.Evicted)
	}
}

func TestKubeBackendDrainRefusesUnmanagedPods(t *testing.T) {
	cases := map[string]map[string]any{
		"bare pod": {
			"metadata": map[string]any{"namespace": "platform", "name": "bare"},
			"status":   map[string]any{"phase": "Running"},
		},
		"non-controller owner": {
			"metadata": map[string]any{
				"namespace":       "platform",
				"name":            "bare",
				"ownerReferences": []any{map[string]any{"kind": "ConfigMap", "name": "cfg"}},
			},
			"status": map[string]any{"phase": "Running"},
		},
	}
	for name, unmanaged := range cases {
		t.Run(name, func(t *testing.T) {
			var mu sync.Mutex
			var patches []string
			evictions := 0
			ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch {
				case r.Method == http.MethodPatch && r.URL.Path == "/api/v1/nodes/worker-1":
					body, _ := io.ReadAll(r.Body)
					mu.Lock()
					patches = append(patches, string(body))
					mu.Unlock()
					_, _ = w.Write([]byte(`{"kind":"Node"}`))
				case r.Method == http.MethodGet && r.URL.Path == "/api/v1/pods":
					pods := drainPods()
					pods["items"] = append(pods["items"].([]any), unmanaged)
					_ = json.NewEncoder(w).Encode(pods)
				case strings.HasSuffix(r.URL.Path, "/eviction"):
					mu.Lock()
					evictions++
					mu.Unlock()
					w.WriteHeader(http.StatusCreated)
				default:
					http.Error(w, "not routed", http.StatusNotFound)
				}
			}))
			defer ts.Close()

			b := newDrainBackend(t, ts.URL)
			if _, err := b.StartDrain(context.Background(), "test", "worker-1"); err != nil {
				t.Fatalf("StartDrain: %v", err)
			}
			final := waitDrain(t, b, "worker-1", "job-1")
			if final.Phase != api.DrainPhaseFailed {
				t.Fatalf("phase = %q, want failed", final.Phase)
			}
			if !strings.Contains(final.Error, "platform/bare") {
				t.Fatalf("error should name the unmanaged pod, got %q", final.Error)
			}
			if len(final.Evicted) != 0 {
				t.Fatalf("evicted = %+v, want none", final.Evicted)
			}

			mu.Lock()
			defer mu.Unlock()
			if evictions != 0 {
				t.Fatalf("no pod may be evicted when one is unmanaged, got %d evictions", evictions)
			}
			if len(patches) != 1 || !strings.Contains(patches[0], `"unschedulable":true`) {
				t.Fatalf("node should be cordoned once and left cordoned, patches = %q", patches)
			}
		})
	}
}

func containsAll(haystack []string, needles ...string) bool {
	set := map[string]struct{}{}
	for _, h := range haystack {
		set[h] = struct{}{}
	}
	for _, n := range needles {
		if _, ok := set[n]; !ok {
			return false
		}
	}
	return true
}
