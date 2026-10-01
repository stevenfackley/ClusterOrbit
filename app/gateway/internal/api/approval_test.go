package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
	"time"
)

func TestApprovalStoreRequires(t *testing.T) {
	var nilStore *ApprovalStore
	if nilStore.Requires(OpDrain) {
		t.Fatal("nil store must require nothing")
	}
	empty := NewApprovalStore(time.Minute)
	if empty.Requires(OpScale) {
		t.Fatal("store without ops must require nothing")
	}
	st := NewApprovalStore(time.Minute, OpDrain)
	if !st.Requires(OpDrain) {
		t.Fatal("drain should require approval")
	}
	if st.Requires(OpScale) {
		t.Fatal("scale not configured, should not require approval")
	}
	if st.Requires(OpCordon) {
		t.Fatal("gating drain must not gate cordon")
	}
	if !NewApprovalStore(time.Minute, OpCordon).Requires(OpDrain) {
		t.Fatal("drain cordons first, so gating cordon must gate drain")
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

// requestIDs returns the sorted IDs of reqs.
func requestIDs(reqs []PendingRequest) []string {
	ids := make([]string, len(reqs))
	for i, r := range reqs {
		ids[i] = r.ID
	}
	slices.Sort(ids)
	return ids
}

func TestSweepEvictsResolvedRequestsAfterRetention(t *testing.T) {
	st := NewApprovalStore(10 * time.Minute) // retention is the 1h floor
	clock := time.Unix(1_700_000_000, 0)
	st.now = func() time.Time { return clock }

	rejected := st.Park(OpScale, "demo", "deployment:ns/a", intPtr(1), "tok-a")
	if _, err := st.Reject(rejected.ID, "no"); err != nil {
		t.Fatalf("reject: %v", err)
	}
	inFlight := st.Park(OpDrain, "demo", "worker-1", nil, "tok-a")
	if _, err := st.Approve(inFlight.ID, "tok-b"); err != nil {
		t.Fatalf("approve: %v", err)
	}
	unanswered := st.Park(OpRestart, "demo", "deployment:ns/b", nil, "tok-a")

	// Inside retention nothing goes. This List also flips the overdue
	// request to expired, which starts its own retention clock.
	clock = clock.Add(59 * time.Minute)
	if got := requestIDs(st.List("")); len(got) != 3 {
		t.Fatalf("at +59m: %v, want all 3", got)
	}

	clock = clock.Add(2 * time.Minute)
	got := requestIDs(st.List(""))
	if want := requestIDs([]PendingRequest{inFlight, unanswered}); !slices.Equal(got, want) {
		t.Fatalf("at +61m: %v, want %v (rejected request swept)", got, want)
	}

	// Parking sweeps too, so a store nobody lists still drains. "approved"
	// is never swept: its mutation is in flight.
	clock = clock.Add(time.Hour)
	st.Park(OpScale, "demo", "deployment:ns/c", intPtr(2), "tok-a")
	st.mu.Lock()
	_, approvedKept := st.reqs[inFlight.ID]
	_, expiredKept := st.reqs[unanswered.ID]
	st.mu.Unlock()
	if !approvedKept || expiredKept {
		t.Fatalf("after Park at +2h01m: approved kept = %v, expired kept = %v; want true, false", approvedKept, expiredKept)
	}
}

func TestSweepRetentionIsAtLeastTTL(t *testing.T) {
	st := NewApprovalStore(2 * time.Hour)
	clock := time.Unix(1_700_000_000, 0)
	st.now = func() time.Time { return clock }

	req := st.Park(OpScale, "demo", "deployment:ns/a", intPtr(1), "tok-a")
	if _, err := st.Reject(req.ID, "no"); err != nil {
		t.Fatalf("reject: %v", err)
	}
	clock = clock.Add(90 * time.Minute)
	if len(st.List("")) != 1 {
		t.Fatal("swept after 90m, want retention = ttl (2h)")
	}
	clock = clock.Add(31 * time.Minute)
	if len(st.List("")) != 0 {
		t.Fatal("still listed after 2h01m")
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

// Identities were once the first 6 token chars, so tokens sharing a prefix
// collided and neither could approve the other's request.
func TestTokensSharingAPrefixCanApproveEachOther(t *testing.T) {
	rb := &recordingBackend{ClusterBackend: NewSampleBackend()}
	s := newApprovalServer(rb, OpScale)
	s.Tokens = []string{"prod-token-alice", "prod-token-bob"}
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	park := decodePending(t, postAs(t, ts.URL+"/v1/clusters/demo/workloads/deployment:platform/api/scale", "prod-token-alice", `{"replicas":5}`))
	done := decodePending(t, postAs(t, ts.URL+"/v1/clusters/demo/approvals/"+park.ID+"/approve", "prod-token-bob", ""))
	if done.Phase != ApprovalPhaseSucceeded || rb.scaleCalls != 1 {
		t.Fatalf("done = %+v scaleCalls = %d, want succeeded once", done, rb.scaleCalls)
	}
	if done.Requester == done.Approver {
		t.Fatalf("requester and approver share identity %q", done.Requester)
	}
	for _, id := range []string{done.Requester, done.Approver} {
		if !strings.HasPrefix(id, "tok:") || strings.Contains(id, "prod") {
			t.Fatalf("identity %q must be a token fingerprint", id)
		}
	}
}

// With auth off the token header is never checked, so it can't be an identity
// and nothing else can tell two people apart: approval must be refused.
func TestApproveRequiresAuth(t *testing.T) {
	rb := &recordingBackend{ClusterBackend: NewSampleBackend()}
	s := newApprovalServer(rb, OpScale)
	s.Tokens = nil
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	park := decodePending(t, postAs(t, ts.URL+"/v1/clusters/demo/workloads/deployment:platform/api/scale", "alice", `{"replicas":5}`))
	if park.Requester != "127.0.0.1" {
		t.Fatalf("requester = %q, want the client IP", park.Requester)
	}
	resp := postAs(t, ts.URL+"/v1/clusters/demo/approvals/"+park.ID+"/approve", "bob", "")
	resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", resp.StatusCode)
	}
	if rb.scaleCalls != 0 {
		t.Fatalf("approval without auth must not execute, got %d", rb.scaleCalls)
	}
}

// A parked response names the request it created, so a client can tell it
// from an executed mutation (whose 202 body, for drain, is also id+phase).
func TestParkedResponseLocatesApproval(t *testing.T) {
	rb := &recordingBackend{ClusterBackend: NewSampleBackend()}
	s := newApprovalServer(rb, OpDrain)
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	resp := postAs(t, ts.URL+"/v1/clusters/demo/nodes/worker-1/drain", "tok-a", "")
	loc := resp.Header.Get("Location")
	pr := decodePending(t, resp)
	if resp.StatusCode != http.StatusAccepted || pr.Op != OpDrain {
		t.Fatalf("status = %d pending = %+v, want 202 with op drain", resp.StatusCode, pr)
	}
	if want := "/v1/clusters/demo/approvals/" + pr.ID; loc != want {
		t.Fatalf("Location = %q, want %q", loc, want)
	}
	if got := decodePending(t, getAs(t, ts.URL+loc, "tok-b")); got.ID != pr.ID {
		t.Fatalf("GET Location returned %+v, want request %s", got, pr.ID)
	}
}

// Gating only cordon must still park a drain, which cordons the node and then
// evicts its pods.
func TestCordonApprovalGatesDrain(t *testing.T) {
	rb := &recordingBackend{ClusterBackend: NewSampleBackend()}
	s := newApprovalServer(rb, OpCordon)
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	resp := postAs(t, ts.URL+"/v1/clusters/demo/nodes/worker-1/drain", "tok-a", "")
	pr := decodePending(t, resp)
	if resp.StatusCode != http.StatusAccepted || pr.Op != OpDrain {
		t.Fatalf("status = %d pending = %+v, want drain parked with 202", resp.StatusCode, pr)
	}
	if rb.startDrainCalls != 0 || rb.cordonCalls != 0 {
		t.Fatalf("drain ran inline: startDrainCalls = %d cordonCalls = %d", rb.startDrainCalls, rb.cordonCalls)
	}
}

// An approved mutation that fails is audited with the status the inline path
// would return, keeping the raw error server-side; the record every caller
// can read carries only the client-safe message.
func TestApproveBackendFailure(t *testing.T) {
	raw := errors.New(`kube api /apis/apps/v1/namespaces/platform/deployments/api/scale returned 403: User "system:serviceaccount:ops:gateway" cannot patch`)
	for _, tc := range []struct {
		name       string
		err        error
		wantStatus int
		wantReason string
	}{
		{"not found", ErrNotFound, http.StatusNotFound, "not found"},
		{"bad request", ErrBadRequest, http.StatusBadRequest, ErrBadRequest.Error()},
		{"unsupported", ErrUnsupported, http.StatusNotImplemented, ErrUnsupported.Error()},
		{"raw kube error", raw, http.StatusBadGateway, "backend error"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			rb := &recordingBackend{ClusterBackend: NewSampleBackend(), returnErr: tc.err}
			var entries []AuditEntry
			s := newApprovalServer(rb, OpScale)
			s.AuditSink = func(e AuditEntry) { entries = append(entries, e) }
			ts := httptest.NewServer(s.Handler())
			defer ts.Close()

			park := decodePending(t, postAs(t, ts.URL+"/v1/clusters/demo/workloads/deployment:platform/api/scale", "tok-a", `{"replicas":5}`))
			resp := postAs(t, ts.URL+"/v1/clusters/demo/approvals/"+park.ID+"/approve", "tok-b", "")
			done := decodePending(t, resp)
			if resp.StatusCode != http.StatusOK || done.Phase != ApprovalPhaseFailed {
				t.Fatalf("status = %d phase = %q, want 200 and failed", resp.StatusCode, done.Phase)
			}
			if done.Reason != tc.wantReason {
				t.Fatalf("reason = %q, want %q", done.Reason, tc.wantReason)
			}
			last := entries[len(entries)-1]
			if last.ApprovalID != park.ID || last.Status != tc.wantStatus || last.Error != tc.err.Error() {
				t.Fatalf("audit = %+v, want status %d with the raw error", last, tc.wantStatus)
			}
		})
	}
}

// vanishingBackend drops every approval record while a scale runs, so the
// approve handler's Complete finds nothing to finalize.
type vanishingBackend struct {
	*recordingBackend
	store *ApprovalStore
}

func (b vanishingBackend) ScaleWorkload(ctx context.Context, clusterID, workloadID string, replicas int) error {
	b.store.mu.Lock()
	clear(b.store.reqs)
	b.store.mu.Unlock()
	return b.recordingBackend.ScaleWorkload(ctx, clusterID, workloadID, replicas)
}

// A failed Complete used to be ignored, answering 200 with an empty record.
func TestApproveCompleteFailureIs500(t *testing.T) {
	rb := &recordingBackend{ClusterBackend: NewSampleBackend()}
	s := newApprovalServer(rb, OpScale)
	s.Backend = vanishingBackend{rb, s.Approvals}
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	park := decodePending(t, postAs(t, ts.URL+"/v1/clusters/demo/workloads/deployment:platform/api/scale", "tok-a", `{"replicas":5}`))
	resp := postAs(t, ts.URL+"/v1/clusters/demo/approvals/"+park.ID+"/approve", "tok-b", "")
	resp.Body.Close()
	if resp.StatusCode != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500", resp.StatusCode)
	}
}

// A scale record without replicas must fail, not scale the workload to 0.
func TestApprovedScaleWithoutReplicasFails(t *testing.T) {
	rb := &recordingBackend{ClusterBackend: NewSampleBackend()}
	s := newApprovalServer(rb, OpScale)
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	park := s.Approvals.Park(OpScale, "demo", "deployment:platform/api", nil, "tok:someone")
	done := decodePending(t, postAs(t, ts.URL+"/v1/clusters/demo/approvals/"+park.ID+"/approve", "tok-b", ""))
	if done.Phase != ApprovalPhaseFailed || done.Reason != ErrBadRequest.Error() {
		t.Fatalf("done = %+v, want failed with %q", done, ErrBadRequest)
	}
	if rb.scaleCalls != 0 {
		t.Fatalf("scaleCalls = %d, want 0", rb.scaleCalls)
	}
}
