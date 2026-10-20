package api

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"sync"
	"testing"
	"time"
)

// recordingBackend counts and records every mutation and drain-status call,
// returning returnErr (or the canned drain jobs). Other reads go to the
// embedded backend.
type recordingBackend struct {
	ClusterBackend
	mu               sync.Mutex
	scaleCalls       int
	restartCalls     int
	cordonCalls      int
	startDrainCalls  int
	drainStatusCalls int
	gotCluster       string
	gotWorkload      string
	gotNode          string
	gotJobID         string
	gotReplicas      int
	gotUnschedulable bool
	drainJob         DrainJob
	statusJob        DrainJob
	returnErr        error
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

func (r *recordingBackend) RestartWorkload(_ context.Context, clusterID, workloadID string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.restartCalls++
	r.gotCluster = clusterID
	r.gotWorkload = workloadID
	return r.returnErr
}

func (r *recordingBackend) CordonNode(_ context.Context, clusterID, nodeID string, unschedulable bool) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.cordonCalls++
	r.gotCluster = clusterID
	r.gotNode = nodeID
	r.gotUnschedulable = unschedulable
	return r.returnErr
}

func (r *recordingBackend) StartDrain(_ context.Context, clusterID, nodeID string) (DrainJob, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.startDrainCalls++
	r.gotCluster = clusterID
	r.gotNode = nodeID
	if r.returnErr != nil {
		return DrainJob{}, r.returnErr
	}
	return r.drainJob, nil
}

func (r *recordingBackend) DrainStatus(_ context.Context, clusterID, nodeID, jobID string) (DrainJob, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.drainStatusCalls++
	r.gotCluster = clusterID
	r.gotNode = nodeID
	r.gotJobID = jobID
	if r.returnErr != nil {
		return DrainJob{}, r.returnErr
	}
	return r.statusJob, nil
}

func intPtr(n int) *int { return &n }

// newApprovalServer serves rb with two tokens, tok-a and tok-b, and parks ops
// for approval.
func newApprovalServer(rb *recordingBackend, ops ...string) *Server {
	return &Server{
		Backend:   rb,
		Tokens:    []string{"tok-a", "tok-b"},
		Approvals: NewApprovalStore(15*time.Minute, ops...),
	}
}

func postAs(t *testing.T, url, token, body string) *http.Response {
	t.Helper()
	var rdr io.Reader
	if body != "" {
		rdr = bytes.NewBufferString(body)
	}
	req, _ := http.NewRequest(http.MethodPost, url, rdr)
	req.Header.Set(AuthHeader, token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("post %s: %v", url, err)
	}
	return resp
}

func decodePending(t *testing.T, resp *http.Response) PendingRequest {
	t.Helper()
	defer resp.Body.Close()
	var pr PendingRequest
	if err := json.NewDecoder(resp.Body).Decode(&pr); err != nil {
		t.Fatalf("decode pending: %v", err)
	}
	return pr
}

func getAs(t *testing.T, url, token string) *http.Response {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, url, nil)
	req.Header.Set(AuthHeader, token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("get %s: %v", url, err)
	}
	return resp
}
