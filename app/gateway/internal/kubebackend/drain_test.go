package kubebackend

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
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

// fakeNode is an apiserver holding one node's pods for a drain. It accepts
// the cordon PATCH and serves the pod list and single-pod GETs. An evicted pod
// stays listed for linger, as a terminating pod does, then is gone. While
// block returns true for a pod, its eviction gets a PDB 429.
type fakeNode struct {
	t      *testing.T
	node   string
	linger time.Duration
	block  func(key string) bool

	mu        sync.Mutex
	pods      []map[string]any
	evictedAt map[string]time.Time
	evictions map[string]int
	cordons   int
}

func newFakeNode(t *testing.T, node string, linger time.Duration, pods ...map[string]any) *fakeNode {
	return &fakeNode{
		t: t, node: node, linger: linger, pods: pods,
		evictedAt: map[string]time.Time{},
		evictions: map[string]int{},
	}
}

func podKey(pod map[string]any) string {
	return stringAt(pod, "metadata", "namespace") + "/" + stringAt(pod, "metadata", "name")
}

// present reports whether the pod with key still exists. Callers hold mu.
func (n *fakeNode) present(key string) bool {
	at, evicted := n.evictedAt[key]
	return !evicted || time.Since(at) < n.linger
}

func (n *fakeNode) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	const nsPrefix = "/api/v1/namespaces/"
	n.mu.Lock()
	defer n.mu.Unlock()
	switch {
	case r.Method == http.MethodPatch && r.URL.Path == "/api/v1/nodes/"+n.node:
		n.cordons++
		_, _ = w.Write([]byte(`{"kind":"Node"}`))
	case r.Method == http.MethodGet && r.URL.Path == "/api/v1/pods":
		if got := r.URL.Query().Get("fieldSelector"); got != "spec.nodeName="+n.node {
			n.t.Errorf("pod list fieldSelector = %q, want spec.nodeName=%s", got, n.node)
		}
		var items []map[string]any
		for _, pod := range n.pods {
			if n.present(podKey(pod)) {
				items = append(items, pod)
			}
		}
		_ = json.NewEncoder(w).Encode(list(items...))
	case r.Method == http.MethodPost && strings.HasPrefix(r.URL.Path, nsPrefix) && strings.HasSuffix(r.URL.Path, "/eviction"):
		key := strings.Replace(strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, nsPrefix), "/eviction"), "/pods/", "/", 1)
		n.evictions[key]++
		if n.block != nil && n.block(key) {
			http.Error(w, "Cannot evict pod as it would violate the pod's disruption budget.", http.StatusTooManyRequests)
			return
		}
		if _, ok := n.evictedAt[key]; !ok {
			n.evictedAt[key] = time.Now()
		}
		w.WriteHeader(http.StatusCreated)
	case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, nsPrefix):
		key := strings.Replace(strings.TrimPrefix(r.URL.Path, nsPrefix), "/pods/", "/", 1)
		for _, pod := range n.pods {
			if podKey(pod) == key && n.present(key) {
				_ = json.NewEncoder(w).Encode(pod)
				return
			}
		}
		http.Error(w, "not found", http.StatusNotFound)
	default:
		http.Error(w, "not routed: "+r.Method+" "+r.URL.Path, http.StatusNotFound)
	}
}

// Waiting for an evicted pod to terminate must not hold an eviction worker:
// otherwise a node with more than drainWorkers pods drains in waves, one
// grace period per drainWorkers pods, and times out on ordinary nodes.
func TestKubeBackendDrainAwaitsTerminatingPodsTogether(t *testing.T) {
	const linger = 250 * time.Millisecond
	pods := make([]map[string]any, 3*drainWorkers)
	for i := range pods {
		pods[i] = managedPod(fmt.Sprintf("api-%d", i), fmt.Sprintf("uid-%d", i))
	}
	ts := httptest.NewServer(newFakeNode(t, "worker-1", linger, pods...))
	defer ts.Close()

	b := newDrainBackend(t, ts.URL)
	// Under 2x linger: enough for one grace period, not for three waves.
	b.drainTimeout = linger * 9 / 5
	if _, err := b.StartDrain(context.Background(), "test", "worker-1"); err != nil {
		t.Fatalf("StartDrain: %v", err)
	}
	final := waitDrain(t, b, "worker-1", "job-1")
	if final.Phase != api.DrainPhaseSucceeded {
		t.Fatalf("phase = %q, error = %q, want succeeded within %v", final.Phase, final.Error, b.drainTimeout)
	}
	if len(final.Evicted) != len(pods) || final.Remaining != 0 {
		t.Fatalf("evicted %d of %d, remaining %d", len(final.Evicted), len(pods), final.Remaining)
	}
}

func TestKubeBackendDrainCordonsAndEvictsWithPDBRetry(t *testing.T) {
	node := newFakeNode(t, "worker-1", 0, listItems(drainPods())...)
	// First eviction of api-1 is blocked by a PodDisruptionBudget. block runs
	// under node.mu, after the attempt is counted.
	node.block = func(key string) bool { return key == "platform/api-1" && node.evictions[key] == 1 }
	ts := httptest.NewServer(node)
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

	node.mu.Lock()
	defer node.mu.Unlock()
	if node.cordons < 1 {
		t.Fatalf("expected node to be cordoned, cordons = %d", node.cordons)
	}
	if node.evictions["platform/api-1"] != 2 {
		t.Fatalf("api-1 should be retried after 429, calls = %d", node.evictions["platform/api-1"])
	}
	if node.evictions["platform/api-2"] != 1 {
		t.Fatalf("api-2 eviction calls = %d, want 1", node.evictions["platform/api-2"])
	}
	if _, ok := node.evictions["kube-system/ds-1"]; ok {
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
	// Once released, the node's pod list reports the pod gone in one of the
	// two ways kubectl accepts: deleted, or replaced by a same-named pod (new
	// UID).
	cases := map[string]map[string]any{
		"deleted":  list(),
		"replaced": list(managedPod("api-1", "uid-2")),
	}
	for name, gone := range cases {
		t.Run(name, func(t *testing.T) {
			var released atomic.Bool
			var lists atomic.Int32
			ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch {
				case r.Method == http.MethodPatch:
					_, _ = w.Write([]byte(`{"kind":"Node"}`))
				case r.Method == http.MethodGet && r.URL.Path == "/api/v1/pods":
					lists.Add(1)
					if released.Load() {
						_ = json.NewEncoder(w).Encode(gone)
						return
					}
					_ = json.NewEncoder(w).Encode(list(managedPod("api-1", "uid-1")))
				case r.Method == http.MethodPost && r.URL.Path == "/api/v1/namespaces/platform/pods/api-1/eviction":
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
			var job api.DrainJob
			waitUntil(t, "the evicted pod to be polled", func() bool {
				job, _ = b.DrainStatus(context.Background(), "test", "worker-1", "job-1")
				if job.Phase == api.DrainPhaseSucceeded || job.Phase == api.DrainPhaseFailed {
					t.Fatalf("drain finished while the evicted pod still exists: %+v", job)
				}
				// The first list enumerates the pods; later ones poll.
				return lists.Load() >= 3
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
	ts := httptest.NewServer(newFakeNode(t, "worker-1", time.Hour, managedPod("api-1", "uid-1")))
	defer ts.Close()

	b := newDrainBackend(t, ts.URL)
	b.drainTimeout = 50 * time.Millisecond
	if _, err := b.StartDrain(context.Background(), "test", "worker-1"); err != nil {
		t.Fatalf("StartDrain: %v", err)
	}
	final := waitDrain(t, b, "worker-1", "job-1")
	if final.Phase != api.DrainPhaseFailed || !strings.Contains(final.Error, "waiting for pod deletion of platform/api-1") {
		t.Fatalf("phase = %q, error = %q, want a deletion timeout naming the pod", final.Phase, final.Error)
	}
	if len(final.Evicted) != 0 || final.Remaining != 1 {
		t.Fatalf("lingering pod must not count as evicted: %+v", final)
	}
}

func TestKubeBackendDrainEvictsPastAPDBBlockedPod(t *testing.T) {
	var released atomic.Bool
	node := newFakeNode(t, "worker-1", 0,
		managedPod("api-1", "uid-1"),
		managedPod("api-2", "uid-2"),
		managedPod("api-3", "uid-3"),
	)
	// api-1 is held by its PodDisruptionBudget until released.
	node.block = func(key string) bool { return key == "platform/api-1" && !released.Load() }
	ts := httptest.NewServer(node)
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

// gatedDrainServer serves a cordon-and-empty-node drain. The pod list for any
// node whose name starts with "slow" blocks until release is called; cleanup
// releases it before closing the server so a failing test doesn't hang.
func gatedDrainServer(t *testing.T) (ts *httptest.Server, release func()) {
	t.Helper()
	gate := make(chan struct{})
	ts = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPatch:
			_, _ = w.Write([]byte(`{"kind":"Node"}`))
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/pods":
			if strings.Contains(r.URL.Query().Get("fieldSelector"), "=slow") {
				<-gate
			}
			_ = json.NewEncoder(w).Encode(list())
		default:
			http.Error(w, "not routed", http.StatusNotFound)
		}
	}))
	release = sync.OnceFunc(func() { close(gate) })
	t.Cleanup(ts.Close)
	t.Cleanup(release) // cleanups run last-in first-out
	return ts, release
}

// countingJobIDs makes b mint job-1, job-2, ... in order.
func countingJobIDs(b *KubeBackend) {
	n := 0
	b.newJobID = func() string {
		n++
		return fmt.Sprintf("job-%d", n)
	}
}

func TestKubeBackendStartDrainJoinsInFlightJob(t *testing.T) {
	ts, release := gatedDrainServer(t)

	b := newDrainBackend(t, ts.URL)
	countingJobIDs(b)
	ctx := context.Background()

	first, err := b.StartDrain(ctx, "test", "slow-1")
	if err != nil {
		t.Fatalf("StartDrain: %v", err)
	}
	again, err := b.StartDrain(ctx, "test", "slow-1")
	if err != nil {
		t.Fatalf("repeat StartDrain: %v", err)
	}
	if again.ID != first.ID {
		t.Fatalf("repeat drain of a busy node started job %q, want the in-flight %q", again.ID, first.ID)
	}
	other, err := b.StartDrain(ctx, "test", "slow-2")
	if err != nil {
		t.Fatalf("StartDrain other node: %v", err)
	}
	if other.ID == first.ID {
		t.Fatalf("a different node must get its own job, got %q", other.ID)
	}

	release()
	waitDrain(t, b, "slow-1", first.ID)
	waitDrain(t, b, "slow-2", other.ID)

	// A finished job no longer blocks a fresh drain of the same node.
	next, err := b.StartDrain(ctx, "test", "slow-1")
	if err != nil {
		t.Fatalf("StartDrain after finish: %v", err)
	}
	if next.ID == first.ID {
		t.Fatalf("drain after a finished job reused %q", next.ID)
	}
	waitDrain(t, b, "slow-1", next.ID)
}

func TestKubeBackendStartDrainPrunesFinishedJobs(t *testing.T) {
	ts, release := gatedDrainServer(t)

	b := newDrainBackend(t, ts.URL)
	countingJobIDs(b)
	var clock atomic.Int64
	clock.Store(time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC).UnixMilli())
	b.now = func() time.Time { return time.UnixMilli(clock.Load()) }
	advance := func(d time.Duration) { clock.Add(d.Milliseconds()) }
	ctx := context.Background()

	start := func(node string) string {
		t.Helper()
		job, err := b.StartDrain(ctx, "test", node)
		if err != nil {
			t.Fatalf("StartDrain %s: %v", node, err)
		}
		return job.ID
	}
	known := func(node, id string) bool {
		t.Helper()
		_, err := b.DrainStatus(ctx, "test", node, id)
		if err != nil && !errors.Is(err, api.ErrNotFound) {
			t.Fatalf("DrainStatus %s: %v", id, err)
		}
		return err == nil
	}

	inFlight := start("slow-1") // stays Running until release
	oldest := start("worker-1")
	waitDrain(t, b, "worker-1", oldest)

	advance(30 * time.Minute)
	younger := start("worker-2")
	waitDrain(t, b, "worker-2", younger)
	if !known("worker-1", oldest) {
		t.Fatalf("a job finished 30m ago must still be pollable")
	}

	advance(31 * time.Minute)
	latest := start("worker-3")
	if known("worker-1", oldest) {
		t.Fatalf("a job finished 61m ago should be pruned on the next StartDrain")
	}
	if !known("worker-2", younger) {
		t.Fatalf("a job finished 31m ago must survive pruning")
	}
	if !known("slow-1", inFlight) {
		t.Fatalf("an in-flight job must never be pruned")
	}

	release()
	waitDrain(t, b, "slow-1", inFlight)
	waitDrain(t, b, "worker-3", latest)
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
