package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
)

func newTestServer(token string) *httptest.Server {
	s := &Server{
		Backend: NewSampleBackend(),
		Token:   token,
	}
	return httptest.NewServer(s.Handler())
}

func TestListClustersRequiresToken(t *testing.T) {
	ts := newTestServer("s3cret")
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/v1/clusters")
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", resp.StatusCode)
	}
}

func TestListClustersWithToken(t *testing.T) {
	ts := newTestServer("s3cret")
	defer ts.Close()

	req, _ := http.NewRequest(http.MethodGet, ts.URL+"/v1/clusters", nil)
	req.Header.Set(AuthHeader, "s3cret")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	var clusters []ClusterProfile
	if err := json.NewDecoder(resp.Body).Decode(&clusters); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(clusters) == 0 {
		t.Fatalf("expected at least one cluster")
	}
	if clusters[0].ConnectionMode != "gateway" {
		t.Fatalf("connectionMode = %q, want gateway", clusters[0].ConnectionMode)
	}
}

func TestSnapshotReturnsJSON(t *testing.T) {
	ts := newTestServer("")
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/v1/clusters/gateway-demo/snapshot")
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status = %d, body = %s", resp.StatusCode, body)
	}
	var snap ClusterSnapshot
	if err := json.NewDecoder(resp.Body).Decode(&snap); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if snap.Profile.ID != "gateway-demo" {
		t.Fatalf("profile.id = %q, want gateway-demo", snap.Profile.ID)
	}
	if len(snap.Nodes) == 0 {
		t.Fatalf("expected nodes in snapshot")
	}
}

func TestSnapshotUnknownCluster(t *testing.T) {
	ts := newTestServer("")
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/v1/clusters/does-not-exist/snapshot")
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", resp.StatusCode)
	}
}

func TestEventsRequiresKindAndName(t *testing.T) {
	ts := newTestServer("")
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/v1/clusters/gateway-demo/events")
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", resp.StatusCode)
	}
}

func TestEventsSuccess(t *testing.T) {
	ts := newTestServer("")
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/v1/clusters/gateway-demo/events?kind=node&objectName=cp-1.gateway-demo")
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	var events []ClusterEvent
	if err := json.NewDecoder(resp.Body).Decode(&events); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(events) == 0 {
		t.Fatalf("expected at least one event")
	}
	if events[0].Reason == "" {
		t.Fatalf("event reason should not be empty")
	}
}

func TestMethodNotAllowed(t *testing.T) {
	ts := newTestServer("")
	defer ts.Close()

	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/v1/clusters", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, want 405", resp.StatusCode)
	}
}

func TestServerAcceptsAnyOfMultipleTokens(t *testing.T) {
	s := &Server{
		Backend: NewSampleBackend(),
		Tokens:  []string{"new-token", "old-token"},
	}
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	for _, tok := range []string{"new-token", "old-token"} {
		req, _ := http.NewRequest(http.MethodGet, ts.URL+"/v1/clusters", nil)
		req.Header.Set(AuthHeader, tok)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("token %q: %v", tok, err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("token %q status = %d, want 200", tok, resp.StatusCode)
		}
	}
}

func TestServerRejectsUnknownToken(t *testing.T) {
	s := &Server{
		Backend: NewSampleBackend(),
		Tokens:  []string{"valid"},
	}
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	req, _ := http.NewRequest(http.MethodGet, ts.URL+"/v1/clusters", nil)
	req.Header.Set(AuthHeader, "bogus")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", resp.StatusCode)
	}
}

type recordingBackend struct {
	ClusterBackend
	mu          sync.Mutex
	scaleCalls  int
	gotCluster  string
	gotWorkload string
	gotReplicas int
	returnErr   error
}

func (r *recordingBackend) ScaleWorkload(_ context.Context, clusterID, workloadID string, replicas int) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.scaleCalls++
	r.gotCluster = clusterID
	r.gotWorkload = workloadID
	r.gotReplicas = replicas
	return r.returnErr
}

func TestScaleWorkloadSuccessAndAudit(t *testing.T) {
	sample := NewSampleBackend()
	rb := &recordingBackend{ClusterBackend: sample}
	var entries []AuditEntry
	s := &Server{
		Backend: rb,
		AuditSink: func(e AuditEntry) {
			entries = append(entries, e)
		},
	}
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	body := bytes.NewBufferString(`{"replicas":5}`)
	resp, err := http.Post(ts.URL+"/v1/clusters/demo/workloads/deployment:platform/api/scale",
		"application/json", body)
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		raw, _ := io.ReadAll(resp.Body)
		t.Fatalf("status = %d body = %s", resp.StatusCode, raw)
	}
	if rb.scaleCalls != 1 || rb.gotReplicas != 5 || rb.gotWorkload != "deployment:platform/api" {
		t.Fatalf("scale args wrong: %+v", rb)
	}
	if rb.gotCluster != "demo" {
		t.Fatalf("cluster id = %q", rb.gotCluster)
	}
	if len(entries) != 1 || entries[0].Status != http.StatusOK {
		t.Fatalf("audit entries = %+v", entries)
	}
	if entries[0].Replicas == nil || *entries[0].Replicas != 5 {
		t.Fatalf("audit replicas = %+v", entries[0].Replicas)
	}
}

func TestScaleWorkloadBadBody(t *testing.T) {
	s := &Server{Backend: NewSampleBackend()}
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	resp, err := http.Post(ts.URL+"/v1/clusters/demo/workloads/deployment:ns/name/scale",
		"application/json", bytes.NewBufferString(`not json`))
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", resp.StatusCode)
	}
}

func TestScaleWorkloadNegativeReplicas(t *testing.T) {
	s := &Server{Backend: NewSampleBackend()}
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	resp, err := http.Post(ts.URL+"/v1/clusters/demo/workloads/deployment:ns/name/scale",
		"application/json", bytes.NewBufferString(`{"replicas":-1}`))
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", resp.StatusCode)
	}
}

func TestScaleWorkloadUnsupportedBackend(t *testing.T) {
	rb := &recordingBackend{ClusterBackend: NewSampleBackend(), returnErr: ErrUnsupported}
	s := &Server{Backend: rb}
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	resp, err := http.Post(ts.URL+"/v1/clusters/demo/workloads/deployment:ns/name/scale",
		"application/json", bytes.NewBufferString(`{"replicas":2}`))
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotImplemented {
		t.Fatalf("status = %d, want 501", resp.StatusCode)
	}
}

func TestScaleWorkloadPathValidation(t *testing.T) {
	s := &Server{Backend: NewSampleBackend()}
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	// Wrong subpath — should 404.
	resp, _ := http.Post(ts.URL+"/v1/clusters/demo/workloads/deployment:ns/name/frobnicate",
		"application/json", bytes.NewBufferString(`{}`))
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", resp.StatusCode)
	}
}

func TestSampleBackendScaleReturnsUnsupported(t *testing.T) {
	sb := NewSampleBackend()
	if err := sb.ScaleWorkload(context.Background(), "", "deployment:ns/name", 1); !errors.Is(err, ErrUnsupported) {
		t.Fatalf("expected ErrUnsupported, got %v", err)
	}
}

func TestServerRateLimits(t *testing.T) {
	s := &Server{
		Backend: NewSampleBackend(),
		Tokens:  []string{"t"},
		Limiter: NewRateLimiter(0.001, 2), // burst 2, effectively no refill during test
	}
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	var last int
	for i := 0; i < 3; i++ {
		req, _ := http.NewRequest(http.MethodGet, ts.URL+"/v1/clusters", nil)
		req.Header.Set(AuthHeader, "t")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("request %d: %v", i, err)
		}
		resp.Body.Close()
		last = resp.StatusCode
	}
	if last != http.StatusTooManyRequests {
		t.Fatalf("3rd request status = %d, want 429", last)
	}
}
