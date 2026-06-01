package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestApprovalPolicyRequires(t *testing.T) {
	var nilPolicy *ApprovalPolicy
	if nilPolicy.Requires(OpDrain) {
		t.Fatal("nil policy must require nothing")
	}
	empty := &ApprovalPolicy{}
	if empty.Requires(OpScale) {
		t.Fatal("empty policy must require nothing")
	}
	p := &ApprovalPolicy{RequiredOps: map[string]bool{OpDrain: true}}
	if !p.Requires(OpDrain) {
		t.Fatal("drain should require approval")
	}
	if p.Requires(OpScale) {
		t.Fatal("scale not configured, should not require approval")
	}
}

func TestParkRecordsPendingRequest(t *testing.T) {
	st := NewApprovalStore(15 * time.Minute)
	base := time.Unix(1_700_000_000, 0)
	st.now = func() time.Time { return base }

	replicas := 4
	req := st.Park(OpScale, "demo", "deployment:platform/api", &replicas, "tok-a")

	if req.ID == "" {
		t.Fatal("Park must mint an ID")
	}
	if req.Phase != ApprovalPhasePending {
		t.Fatalf("phase = %q, want pending", req.Phase)
	}
	if req.Op != OpScale || req.ClusterID != "demo" || req.TargetID != "deployment:platform/api" {
		t.Fatalf("fields wrong: %+v", req)
	}
	if req.Replicas == nil || *req.Replicas != 4 {
		t.Fatalf("replicas = %v", req.Replicas)
	}
	if req.Requester != "tok-a" {
		t.Fatalf("requester = %q", req.Requester)
	}
	if req.ExpiresAt != base.Add(15*time.Minute).UnixMilli() {
		t.Fatalf("expiresAt = %d", req.ExpiresAt)
	}
}

func TestParkReturnsCopy(t *testing.T) {
	st := NewApprovalStore(time.Minute)
	replicas := 1
	req := st.Park(OpScale, "demo", "deployment:ns/a", &replicas, "tok-a")
	*req.Replicas = 999 // mutate the returned copy
	got, ok := st.Get(req.ID)
	if !ok {
		t.Fatal("request missing")
	}
	if *got.Replicas != 1 {
		t.Fatalf("stored replicas mutated through returned copy: %d", *got.Replicas)
	}
}

func TestPendingRequestExpiresOnRead(t *testing.T) {
	st := NewApprovalStore(10 * time.Minute)
	clock := time.Unix(1_700_000_000, 0)
	st.now = func() time.Time { return clock }

	req := st.Park(OpDrain, "demo", "worker-1", nil, "tok-a")

	// Still fresh.
	got, _ := st.Get(req.ID)
	if got.Phase != ApprovalPhasePending {
		t.Fatalf("phase = %q, want pending while fresh", got.Phase)
	}

	// Advance past TTL.
	clock = clock.Add(11 * time.Minute)
	got, _ = st.Get(req.ID)
	if got.Phase != ApprovalPhaseExpired {
		t.Fatalf("phase = %q, want expired after TTL", got.Phase)
	}
}

func TestApproveByDistinctIdentitySucceeds(t *testing.T) {
	st := NewApprovalStore(time.Minute)
	req := st.Park(OpScale, "demo", "deployment:ns/a", intPtr(2), "tok-a")

	approved, err := st.Approve(req.ID, "tok-b")
	if err != nil {
		t.Fatalf("approve: %v", err)
	}
	if approved.Phase != ApprovalPhaseApproved {
		t.Fatalf("phase = %q, want approved", approved.Phase)
	}
	if approved.Approver != "tok-b" {
		t.Fatalf("approver = %q", approved.Approver)
	}
}

func TestApproveBySameIdentityRejected(t *testing.T) {
	st := NewApprovalStore(time.Minute)
	req := st.Park(OpDrain, "demo", "worker-1", nil, "tok-a")
	if _, err := st.Approve(req.ID, "tok-a"); !errors.Is(err, ErrSelfApprove) {
		t.Fatalf("err = %v, want ErrSelfApprove", err)
	}
}

func TestApproveUnknownIsNotFound(t *testing.T) {
	st := NewApprovalStore(time.Minute)
	if _, err := st.Approve("nope", "tok-b"); !errors.Is(err, ErrApprovalNotFound) {
		t.Fatalf("err = %v, want ErrApprovalNotFound", err)
	}
}

func TestApproveTerminalIsConflict(t *testing.T) {
	st := NewApprovalStore(time.Minute)
	req := st.Park(OpScale, "demo", "deployment:ns/a", intPtr(1), "tok-a")
	if _, err := st.Reject(req.ID, "cancel"); err != nil {
		t.Fatalf("reject: %v", err)
	}
	if _, err := st.Approve(req.ID, "tok-b"); !errors.Is(err, ErrApprovalTerminal) {
		t.Fatalf("err = %v, want ErrApprovalTerminal", err)
	}
}

func TestRejectResolves(t *testing.T) {
	st := NewApprovalStore(time.Minute)
	req := st.Park(OpScale, "demo", "deployment:ns/a", intPtr(1), "tok-a")
	rejected, err := st.Reject(req.ID, "not now")
	if err != nil {
		t.Fatalf("reject: %v", err)
	}
	if rejected.Phase != ApprovalPhaseRejected || rejected.Reason != "not now" {
		t.Fatalf("rejected = %+v", rejected)
	}
}

func TestCompleteSucceededAndFailed(t *testing.T) {
	st := NewApprovalStore(time.Minute)
	req := st.Park(OpDrain, "demo", "worker-1", nil, "tok-a")
	if _, err := st.Approve(req.ID, "tok-b"); err != nil {
		t.Fatalf("approve: %v", err)
	}
	done, err := st.Complete(req.ID, "job-9", "")
	if err != nil {
		t.Fatalf("complete: %v", err)
	}
	if done.Phase != ApprovalPhaseSucceeded || done.ResultID != "job-9" {
		t.Fatalf("done = %+v", done)
	}

	req2 := st.Park(OpScale, "demo", "deployment:ns/a", intPtr(1), "tok-a")
	if _, err := st.Approve(req2.ID, "tok-b"); err != nil {
		t.Fatalf("approve2: %v", err)
	}
	failed, err := st.Complete(req2.ID, "", "backend exploded")
	if err != nil {
		t.Fatalf("complete2: %v", err)
	}
	if failed.Phase != ApprovalPhaseFailed || failed.Reason != "backend exploded" {
		t.Fatalf("failed = %+v", failed)
	}
}

func intPtr(n int) *int { return &n }

func newApprovalServer(rb *recordingBackend, ops ...string) *Server {
	required := map[string]bool{}
	for _, op := range ops {
		required[op] = true
	}
	return &Server{
		Backend:        rb,
		Tokens:         []string{"tok-a", "tok-b"},
		ApprovalPolicy: &ApprovalPolicy{RequiredOps: required},
		Approvals:      NewApprovalStore(15 * time.Minute),
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

func TestScaleParksWhenApprovalRequired(t *testing.T) {
	rb := &recordingBackend{ClusterBackend: NewSampleBackend()}
	s := newApprovalServer(rb, OpScale)
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	resp := postAs(t, ts.URL+"/v1/clusters/demo/workloads/deployment:platform/api/scale", "tok-a", `{"replicas":5}`)
	if resp.StatusCode != http.StatusAccepted {
		t.Fatalf("status = %d, want 202", resp.StatusCode)
	}
	pr := decodePending(t, resp)
	if pr.Phase != ApprovalPhasePending || pr.Op != OpScale {
		t.Fatalf("pending = %+v", pr)
	}
	if rb.scaleCalls != 0 {
		t.Fatalf("backend must NOT be called on park, got %d", rb.scaleCalls)
	}
}

func TestScaleExecutesInlineWhenNotGated(t *testing.T) {
	rb := &recordingBackend{ClusterBackend: NewSampleBackend()}
	s := newApprovalServer(rb, OpDrain) // scale NOT gated
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	resp := postAs(t, ts.URL+"/v1/clusters/demo/workloads/deployment:platform/api/scale", "tok-a", `{"replicas":2}`)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200 (not gated)", resp.StatusCode)
	}
	if rb.scaleCalls != 1 {
		t.Fatalf("backend should execute inline, got %d", rb.scaleCalls)
	}
}

func TestDrainParksWhenApprovalRequired(t *testing.T) {
	rb := &recordingBackend{
		ClusterBackend: NewSampleBackend(),
		drainJob:       DrainJob{ID: "job-1", NodeID: "worker-1", Phase: DrainPhasePending},
	}
	s := newApprovalServer(rb, OpDrain)
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	resp := postAs(t, ts.URL+"/v1/clusters/demo/nodes/worker-1/drain", "tok-a", "")
	if resp.StatusCode != http.StatusAccepted {
		t.Fatalf("status = %d, want 202", resp.StatusCode)
	}
	pr := decodePending(t, resp)
	if pr.Op != OpDrain || pr.TargetID != "worker-1" {
		t.Fatalf("pending = %+v", pr)
	}
	if rb.startDrainCalls != 0 {
		t.Fatalf("StartDrain must NOT run on park, got %d", rb.startDrainCalls)
	}
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

func TestApproveExecutesAndCompletes(t *testing.T) {
	rb := &recordingBackend{ClusterBackend: NewSampleBackend()}
	s := newApprovalServer(rb, OpScale)
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	park := decodePending(t, postAs(t, ts.URL+"/v1/clusters/demo/workloads/deployment:platform/api/scale", "tok-a", `{"replicas":5}`))

	resp := postAs(t, ts.URL+"/v1/clusters/demo/approvals/"+park.ID+"/approve", "tok-b", "")
	if resp.StatusCode != http.StatusOK {
		raw, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		t.Fatalf("status = %d body = %s, want 200", resp.StatusCode, raw)
	}
	done := decodePending(t, resp)
	if done.Phase != ApprovalPhaseSucceeded {
		t.Fatalf("phase = %q, want succeeded", done.Phase)
	}
	if rb.scaleCalls != 1 || rb.gotReplicas != 5 {
		t.Fatalf("backend not executed correctly: %+v", rb)
	}
}

func TestSelfApproveIsConflict(t *testing.T) {
	rb := &recordingBackend{ClusterBackend: NewSampleBackend()}
	s := newApprovalServer(rb, OpScale)
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	park := decodePending(t, postAs(t, ts.URL+"/v1/clusters/demo/workloads/deployment:platform/api/scale", "tok-a", `{"replicas":5}`))
	resp := postAs(t, ts.URL+"/v1/clusters/demo/approvals/"+park.ID+"/approve", "tok-a", "")
	resp.Body.Close()
	if resp.StatusCode != http.StatusConflict {
		t.Fatalf("status = %d, want 409", resp.StatusCode)
	}
	if rb.scaleCalls != 0 {
		t.Fatalf("self-approve must not execute, got %d", rb.scaleCalls)
	}
}

func TestRejectBlocksExecution(t *testing.T) {
	rb := &recordingBackend{ClusterBackend: NewSampleBackend()}
	s := newApprovalServer(rb, OpScale)
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	park := decodePending(t, postAs(t, ts.URL+"/v1/clusters/demo/workloads/deployment:platform/api/scale", "tok-a", `{"replicas":5}`))
	resp := postAs(t, ts.URL+"/v1/clusters/demo/approvals/"+park.ID+"/reject", "tok-a", "")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("reject status = %d, want 200", resp.StatusCode)
	}
	if decodePending(t, resp).Phase != ApprovalPhaseRejected {
		t.Fatal("phase not rejected")
	}
	if rb.scaleCalls != 0 {
		t.Fatalf("rejected request must not execute, got %d", rb.scaleCalls)
	}
}

func TestDrainApprovalReturnsDrainJobID(t *testing.T) {
	rb := &recordingBackend{
		ClusterBackend: NewSampleBackend(),
		drainJob:       DrainJob{ID: "job-77", NodeID: "worker-1", Phase: DrainPhasePending},
	}
	s := newApprovalServer(rb, OpDrain)
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	park := decodePending(t, postAs(t, ts.URL+"/v1/clusters/demo/nodes/worker-1/drain", "tok-a", ""))
	done := decodePending(t, postAs(t, ts.URL+"/v1/clusters/demo/approvals/"+park.ID+"/approve", "tok-b", ""))
	if done.Phase != ApprovalPhaseSucceeded || done.ResultID != "job-77" {
		t.Fatalf("done = %+v, want succeeded with resultId job-77", done)
	}
	if rb.startDrainCalls != 1 {
		t.Fatalf("StartDrain calls = %d, want 1", rb.startDrainCalls)
	}
}

func TestListAndGetApprovals(t *testing.T) {
	rb := &recordingBackend{ClusterBackend: NewSampleBackend()}
	s := newApprovalServer(rb, OpScale)
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	park := decodePending(t, postAs(t, ts.URL+"/v1/clusters/demo/workloads/deployment:platform/api/scale", "tok-a", `{"replicas":5}`))

	listResp := getAs(t, ts.URL+"/v1/clusters/demo/approvals", "tok-a")
	defer listResp.Body.Close()
	var list []PendingRequest
	if err := json.NewDecoder(listResp.Body).Decode(&list); err != nil {
		t.Fatalf("decode list: %v", err)
	}
	if len(list) != 1 || list[0].ID != park.ID {
		t.Fatalf("list = %+v", list)
	}

	getResp := getAs(t, ts.URL+"/v1/clusters/demo/approvals/"+park.ID, "tok-a")
	if getResp.StatusCode != http.StatusOK {
		t.Fatalf("get status = %d", getResp.StatusCode)
	}
	if decodePending(t, getResp).ID != park.ID {
		t.Fatal("get returned wrong request")
	}

	missing := getAs(t, ts.URL+"/v1/clusters/demo/approvals/nope", "tok-a")
	missing.Body.Close()
	if missing.StatusCode != http.StatusNotFound {
		t.Fatalf("unknown id status = %d, want 404", missing.StatusCode)
	}
}
