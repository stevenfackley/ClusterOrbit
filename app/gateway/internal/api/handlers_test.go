package api

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
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
