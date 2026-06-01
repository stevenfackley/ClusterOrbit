# Two-Person Approval Flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an asynchronous two-person approval path to the Go gateway so that configured destructive op-classes (scale/restart/cordon/drain) are parked until a second, distinct operator approves them.

**Architecture:** A permissive-by-default `ApprovalPolicy` (sibling to `ScalePolicy`/`NodePolicy`) names op-classes needing approval. When a gated mutation passes the existing 403 policy gate, it is parked in an in-memory `ApprovalStore` (mirrors the drain-job registry) and the handler returns `202` + a pollable `PendingRequest` instead of executing. A distinct identity POSTs `/approve`, which synchronously executes the captured mutation and finalizes the request. Identity = the truncated shared token already used in audit; two distinct tokens = two people.

**Tech Stack:** Go 1.24, stdlib only (`crypto/rand`, `sync`, `net/http`, `encoding/json`). No new dependencies. Tests use `httptest` + the existing `recordingBackend` double.

**Spec:** `docs/superpowers/specs/2026-05-31-two-person-approval-flow-design.md`

**Conventions for every commit in this plan:** Conventional Commits, **no `Co-Authored-By` / AI attribution** (workspace rule). Run all `go` commands from repo root (`go.mod` is at root). Gateway code lives under `app/gateway/`.

---

## File Structure

- **Create** `app/gateway/internal/api/approval.go` — `ApprovalPolicy`, `PendingRequest`, op/phase constants, store errors, `ApprovalStore` + methods (`Park`, `Get`, `List`, `Approve`, `Reject`, `Complete`).
- **Create** `app/gateway/internal/api/approval_test.go` — store unit tests + HTTP integration tests.
- **Modify** `app/gateway/internal/api/handlers.go` — add `Server.ApprovalPolicy`/`Server.Approvals` fields; `AuditEntry.ApprovalID`; extract `requestIdentity`; add `executePending`, `auditApproval`, `approvalErrStatus`, `writeApprovalError`; park-gate inside the four mutation handlers; route the approval endpoints.
- **Modify** `app/gateway/cmd/clusterorbit-gateway/main.go` — `buildApprovalPolicy()`, wire fields, single-token warning, startup banner.
- **Modify** `CLAUDE.md` (repo root, the ClusterOrbit one) — document the two new env vars.

---

## Task 1: Approval types + ApprovalPolicy

**Files:**
- Create: `app/gateway/internal/api/approval.go`
- Test: `app/gateway/internal/api/approval_test.go`

- [ ] **Step 1: Write the failing test**

Create `app/gateway/internal/api/approval_test.go`:

```go
package api

import (
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./app/gateway/internal/api/ -run 'TestApprovalPolicyRequires|TestPark' -v`
Expected: FAIL — `undefined: NewApprovalStore`, `undefined: OpDrain`, etc.

- [ ] **Step 3: Write minimal implementation**

Create `app/gateway/internal/api/approval.go`:

```go
package api

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"sort"
	"sync"
	"time"
)

// Approval op-class identifiers. These are the values an ApprovalPolicy gates
// and the Op field of a PendingRequest. They cross the wire to clients.
const (
	OpScale   = "scale"
	OpRestart = "restart"
	OpCordon  = "cordon"
	OpDrain   = "drain"
)

// Approval phase values. A request starts Pending and ends in exactly one
// terminal state. "approved" is a transient internal phase — execution is
// synchronous, so the park/poll path never observes it. These strings cross
// the wire; don't rename without updating clients.
const (
	ApprovalPhasePending   = "pending"
	ApprovalPhaseApproved  = "approved"
	ApprovalPhaseRejected  = "rejected"
	ApprovalPhaseExpired   = "expired"
	ApprovalPhaseSucceeded = "succeeded"
	ApprovalPhaseFailed    = "failed"
)

// Approval store errors. Handlers map these to HTTP status codes.
var (
	ErrApprovalNotFound = errors.New("approval request not found")
	ErrSelfApprove      = errors.New("requester cannot approve own request")
	ErrApprovalTerminal = errors.New("approval request already resolved")
)

// ApprovalPolicy names the op-classes that must be parked for a second-person
// approval. Zero value (nil pointer or empty RequiredOps) requires approval for
// nothing — consistent with ScalePolicy/NodePolicy permissive defaults.
type ApprovalPolicy struct {
	RequiredOps map[string]bool
}

// Requires reports whether op must be parked for approval. A nil policy or an
// op not in the set returns false (execute inline).
func (p *ApprovalPolicy) Requires(op string) bool {
	if p == nil || len(p.RequiredOps) == 0 {
		return false
	}
	return p.RequiredOps[op]
}

// PendingRequest is a parked mutation awaiting a second-person approval. The
// deferred mutation is captured as typed fields (not a closure) so the record
// stays inspectable and JSON-serializable, consistent with DrainJob.
type PendingRequest struct {
	ID        string `json:"id"`
	Op        string `json:"op"`
	ClusterID string `json:"clusterId"`
	TargetID  string `json:"targetId"`
	Replicas  *int   `json:"replicas,omitempty"`
	Phase     string `json:"phase"`
	Requester string `json:"requester"`
	Approver  string `json:"approver,omitempty"`
	Reason    string `json:"reason,omitempty"`
	ResultID  string `json:"resultId,omitempty"`
	CreatedAt int64  `json:"createdAt"`
	UpdatedAt int64  `json:"updatedAt"`
	ExpiresAt int64  `json:"expiresAt"`
}

// ApprovalStore is an in-memory registry of pending approval requests. Like the
// drain-job registry it is mutex-guarded and non-durable: a gateway restart
// drops all pending requests (acceptable — they are short-lived and TTL'd).
type ApprovalStore struct {
	mu    sync.Mutex
	reqs  map[string]*PendingRequest
	ttl   time.Duration
	now   func() time.Time
	newID func() string
}

// NewApprovalStore builds a store whose parked requests expire after ttl.
func NewApprovalStore(ttl time.Duration) *ApprovalStore {
	return &ApprovalStore{
		reqs:  make(map[string]*PendingRequest),
		ttl:   ttl,
		now:   time.Now,
		newID: randomApprovalID,
	}
}

func randomApprovalID() string {
	var b [12]byte
	_, _ = rand.Read(b[:])
	return "apr-" + hex.EncodeToString(b[:])
}

// Park records a new pending request and returns a deep copy.
func (s *ApprovalStore) Park(op, clusterID, targetID string, replicas *int, requester string) PendingRequest {
	now := s.now().UnixMilli()
	req := &PendingRequest{
		ID:        s.newID(),
		Op:        op,
		ClusterID: clusterID,
		TargetID:  targetID,
		Replicas:  replicas,
		Phase:     ApprovalPhasePending,
		Requester: requester,
		CreatedAt: now,
		UpdatedAt: now,
		ExpiresAt: s.now().Add(s.ttl).UnixMilli(),
	}
	s.mu.Lock()
	s.reqs[req.ID] = req
	s.mu.Unlock()
	return copyRequest(req)
}

// Get returns a copy of a request by ID, lazily expiring it first.
func (s *ApprovalStore) Get(id string) (PendingRequest, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, ok := s.reqs[id]
	if !ok {
		return PendingRequest{}, false
	}
	s.expireLocked(r)
	return copyRequest(r), true
}

// List returns copies of all requests for clusterID (empty == all), sorted by
// CreatedAt then ID for deterministic output. Expires each lazily.
func (s *ApprovalStore) List(clusterID string) []PendingRequest {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []PendingRequest{}
	for _, r := range s.reqs {
		s.expireLocked(r)
		if clusterID == "" || r.ClusterID == clusterID {
			out = append(out, copyRequest(r))
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].CreatedAt != out[j].CreatedAt {
			return out[i].CreatedAt < out[j].CreatedAt
		}
		return out[i].ID < out[j].ID
	})
	return out
}

// expireLocked flips a still-pending request to expired once its TTL elapses.
// Caller must hold s.mu.
func (s *ApprovalStore) expireLocked(r *PendingRequest) {
	if r.Phase == ApprovalPhasePending && s.now().UnixMilli() >= r.ExpiresAt {
		r.Phase = ApprovalPhaseExpired
		r.UpdatedAt = s.now().UnixMilli()
	}
}

func copyRequest(r *PendingRequest) PendingRequest {
	out := *r
	if r.Replicas != nil {
		v := *r.Replicas
		out.Replicas = &v
	}
	return out
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./app/gateway/internal/api/ -run 'TestApprovalPolicyRequires|TestPark' -v`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add app/gateway/internal/api/approval.go app/gateway/internal/api/approval_test.go
git commit -m "feat(gateway): add ApprovalPolicy + ApprovalStore park/get/list"
```

---

## Task 2: TTL expiry

**Files:**
- Test: `app/gateway/internal/api/approval_test.go` (append)
- (implementation already present from Task 1; this task proves it)

- [ ] **Step 1: Write the failing test**

Append to `approval_test.go`:

```go
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
```

- [ ] **Step 2: Run test to verify it fails (or passes)**

Run: `go test ./app/gateway/internal/api/ -run TestPendingRequestExpiresOnRead -v`
Expected: PASS — `expireLocked` from Task 1 already implements this. (If it fails, the bug is in `expireLocked`; fix there.)

- [ ] **Step 3: Commit (test-only)**

```bash
git add app/gateway/internal/api/approval_test.go
git commit -m "test(gateway): cover approval TTL expiry on read"
```

---

## Task 3: Approve / Reject / Complete transitions

**Files:**
- Modify: `app/gateway/internal/api/approval.go` (add methods)
- Test: `app/gateway/internal/api/approval_test.go` (append)

- [ ] **Step 1: Write the failing test**

Append to `approval_test.go`:

```go
import_marker_for_errors := 0 // placeholder removed below
```

(Do not add the line above — it is a marker. Ensure `"errors"` is imported in the test file's import block; add it now.)

Append the tests:

```go
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./app/gateway/internal/api/ -run 'TestApprove|TestReject|TestComplete' -v`
Expected: FAIL — `st.Approve undefined`, etc.

- [ ] **Step 3: Write minimal implementation**

Append to `approval.go`:

```go
// Approve transitions a pending request to approved, recording the approver.
// The approver must differ from the requester. The handler executes the
// captured mutation and then calls Complete. Returns a copy of the approved
// request.
func (s *ApprovalStore) Approve(id, approver string) (PendingRequest, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, ok := s.reqs[id]
	if !ok {
		return PendingRequest{}, ErrApprovalNotFound
	}
	s.expireLocked(r)
	if r.Phase != ApprovalPhasePending {
		return PendingRequest{}, ErrApprovalTerminal
	}
	if approver == r.Requester {
		return PendingRequest{}, ErrSelfApprove
	}
	r.Approver = approver
	r.Phase = ApprovalPhaseApproved
	r.UpdatedAt = s.now().UnixMilli()
	return copyRequest(r), nil
}

// Reject resolves a pending request as rejected. Any identity may reject,
// including the requester cancelling their own request. reason is optional.
func (s *ApprovalStore) Reject(id, reason string) (PendingRequest, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, ok := s.reqs[id]
	if !ok {
		return PendingRequest{}, ErrApprovalNotFound
	}
	s.expireLocked(r)
	if r.Phase != ApprovalPhasePending {
		return PendingRequest{}, ErrApprovalTerminal
	}
	r.Phase = ApprovalPhaseRejected
	r.Reason = reason
	r.UpdatedAt = s.now().UnixMilli()
	return copyRequest(r), nil
}

// Complete moves an approved request to a terminal phase after execution.
// errMsg == "" → succeeded (resultID carried for async ops like drain); a
// non-empty errMsg → failed with the message in Reason. Returns a copy.
func (s *ApprovalStore) Complete(id, resultID, errMsg string) (PendingRequest, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, ok := s.reqs[id]
	if !ok {
		return PendingRequest{}, ErrApprovalNotFound
	}
	if errMsg != "" {
		r.Phase = ApprovalPhaseFailed
		r.Reason = errMsg
	} else {
		r.Phase = ApprovalPhaseSucceeded
		r.ResultID = resultID
	}
	r.UpdatedAt = s.now().UnixMilli()
	return copyRequest(r), nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./app/gateway/internal/api/ -run 'TestApprove|TestReject|TestComplete' -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/gateway/internal/api/approval.go app/gateway/internal/api/approval_test.go
git commit -m "feat(gateway): add approval approve/reject/complete transitions"
```

---

## Task 4: Server wiring — fields, identity helper, executePending, audit

**Files:**
- Modify: `app/gateway/internal/api/handlers.go`

- [ ] **Step 1: Add the `context` import**

In `handlers.go` import block (currently `encoding/json`, `errors`, `log`, `net/http`, `runtime/debug`, `strconv`, `strings`, `time`), add `"context"` as the first import.

- [ ] **Step 2: Add Server fields**

In the `Server` struct (after `NodePolicy *NodePolicy`), add:

```go
	// ApprovalPolicy, if set, parks mutations whose op-class requires a
	// second-person approval instead of executing them inline. When non-nil,
	// Approvals MUST also be non-nil (main wires the two together).
	ApprovalPolicy *ApprovalPolicy
	// Approvals is the pending-request registry for the approval flow.
	Approvals *ApprovalStore
```

- [ ] **Step 3: Add `ApprovalID` to AuditEntry**

In the `AuditEntry` struct, after the `Error string` field, add:

```go
	ApprovalID string `json:"approvalId,omitempty"`
```

- [ ] **Step 4: Extract `requestIdentity` and reuse it in `audit`**

Add this function near `truncateToken`:

```go
// requestIdentity returns the caller identity used in audit records and as the
// requester/approver marker on pending approvals: the truncated shared token
// when auth is on, else the client IP.
func requestIdentity(r *http.Request) string {
	if got := r.Header.Get(AuthHeader); got != "" {
		return truncateToken(got)
	}
	return clientIP(r)
}
```

Then replace the identity computation inside `audit` (the lines
`identity := clientIP(r)` / `if got := r.Header.Get(AuthHeader); got != "" { identity = truncateToken(got) }`)
with a single call:

```go
	identity := requestIdentity(r)
```

- [ ] **Step 5: Add `executePending`, `auditApproval`, and the approval error mappers**

Add to `handlers.go`:

```go
// executePending runs the backend mutation captured by an approved request and
// returns the async result id (drain only) and an error message ("" on success).
func (s *Server) executePending(ctx context.Context, req PendingRequest) (resultID, errMsg string) {
	var err error
	switch req.Op {
	case OpScale:
		replicas := 0
		if req.Replicas != nil {
			replicas = *req.Replicas
		}
		err = s.Backend.ScaleWorkload(ctx, req.ClusterID, req.TargetID, replicas)
	case OpRestart:
		err = s.Backend.RestartWorkload(ctx, req.ClusterID, req.TargetID)
	case OpCordon:
		err = s.Backend.CordonNode(ctx, req.ClusterID, req.TargetID, true)
	case OpDrain:
		var job DrainJob
		job, err = s.Backend.StartDrain(ctx, req.ClusterID, req.TargetID)
		if err == nil {
			resultID = job.ID
		}
	default:
		err = ErrBadRequest
	}
	if err != nil {
		return "", err.Error()
	}
	return resultID, ""
}

// auditApproval records an approval-flow event (park, approve, reject, or
// execute result). ApprovalID threads one request park → approve → execute.
func (s *Server) auditApproval(r *http.Request, req PendingRequest, status int, errMsg string) {
	if s.AuditSink == nil {
		return
	}
	s.AuditSink(AuditEntry{
		Timestamp:  timeNow().UTC().Format("2006-01-02T15:04:05Z07:00"),
		Identity:   requestIdentity(r),
		Method:     r.Method,
		Path:       r.URL.Path,
		ClusterID:  req.ClusterID,
		WorkloadID: req.TargetID,
		Replicas:   req.Replicas,
		Status:     status,
		Error:      errMsg,
		ApprovalID: req.ID,
	})
}

// approvalErrStatus maps store errors to HTTP status codes.
func approvalErrStatus(err error) int {
	switch {
	case errors.Is(err, ErrApprovalNotFound):
		return http.StatusNotFound
	case errors.Is(err, ErrSelfApprove), errors.Is(err, ErrApprovalTerminal):
		return http.StatusConflict
	default:
		return http.StatusInternalServerError
	}
}

func writeApprovalError(w http.ResponseWriter, err error) {
	writeError(w, approvalErrStatus(err), err.Error())
}
```

- [ ] **Step 6: Verify it compiles (no new behavior yet)**

Run: `go build ./app/gateway/... && go test ./app/gateway/internal/api/ -run TestScaleWorkloadSuccessAndAudit -v`
Expected: builds clean; existing audit test still PASS (identity refactor is behavior-preserving).

- [ ] **Step 7: Commit**

```bash
git add app/gateway/internal/api/handlers.go
git commit -m "feat(gateway): add approval server fields, identity helper, executePending"
```

---

## Task 5: Park-gate the four mutation handlers

**Files:**
- Modify: `app/gateway/internal/api/handlers.go`
- Test: `app/gateway/internal/api/approval_test.go` (append HTTP tests)

- [ ] **Step 1: Write the failing test**

Append to `approval_test.go` (ensure imports include `"bytes"`, `"encoding/json"`, `"io"`, `"net/http"`, `"net/http/httptest"`):

```go
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./app/gateway/internal/api/ -run 'TestScaleParks|TestScaleExecutesInline|TestDrainParks' -v`
Expected: FAIL — scale returns 200 and calls backend (no park gate yet).

- [ ] **Step 3: Write minimal implementation**

In `handleScale`, immediately **after** the `s.ScalePolicy.Evaluate(...)` 403 block and **before** `err := s.Backend.ScaleWorkload(...)`, insert:

```go
	if s.ApprovalPolicy.Requires(OpScale) {
		pr := s.Approvals.Park(OpScale, clusterID, workloadID, body.Replicas, requestIdentity(r))
		s.auditApproval(r, pr, http.StatusAccepted, "")
		writeJSON(w, http.StatusAccepted, pr)
		return
	}
```

In `handleRestart`, after the `s.ScalePolicy.EvaluateNamespace(...)` 403 block and before `err := s.Backend.RestartWorkload(...)`:

```go
	if s.ApprovalPolicy.Requires(OpRestart) {
		pr := s.Approvals.Park(OpRestart, clusterID, workloadID, nil, requestIdentity(r))
		s.auditApproval(r, pr, http.StatusAccepted, "")
		writeJSON(w, http.StatusAccepted, pr)
		return
	}
```

In `handleCordon`, after the `s.NodePolicy.EvaluateCordon(...)` 403 block and before `err := s.Backend.CordonNode(...)`:

```go
	if unschedulable && s.ApprovalPolicy.Requires(OpCordon) {
		pr := s.Approvals.Park(OpCordon, clusterID, nodeID, nil, requestIdentity(r))
		s.auditApproval(r, pr, http.StatusAccepted, "")
		writeJSON(w, http.StatusAccepted, pr)
		return
	}
```

In `handleStartDrain`, after the `s.NodePolicy.EvaluateDrain(...)` 403 block and before `job, err := s.Backend.StartDrain(...)`:

```go
	if s.ApprovalPolicy.Requires(OpDrain) {
		pr := s.Approvals.Park(OpDrain, clusterID, nodeID, nil, requestIdentity(r))
		s.auditApproval(r, pr, http.StatusAccepted, "")
		writeJSON(w, http.StatusAccepted, pr)
		return
	}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./app/gateway/internal/api/ -run 'TestScaleParks|TestScaleExecutesInline|TestDrainParks' -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/gateway/internal/api/handlers.go app/gateway/internal/api/approval_test.go
git commit -m "feat(gateway): park gated mutations for two-person approval"
```

---

## Task 6: Approval HTTP endpoints (list / get / approve / reject)

**Files:**
- Modify: `app/gateway/internal/api/handlers.go`
- Test: `app/gateway/internal/api/approval_test.go` (append)

- [ ] **Step 1: Write the failing test**

Append to `approval_test.go`:

```go
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./app/gateway/internal/api/ -run 'TestApproveExecutes|TestSelfApprove|TestReject|TestDrainApproval|TestListAndGet' -v`
Expected: FAIL — approve/reject/list routes return 404 (not routed yet).

- [ ] **Step 3: Write minimal implementation — routing**

In `handleClusterScoped`, add the get-one prefix check **after** the existing drain-status block and **before** the `switch subpath`:

```go
	// GET .../approvals/{rid} — single pending request.
	if rid := strings.TrimPrefix(subpath, "approvals/"); rid != subpath {
		s.handleGetApproval(w, r, clusterID, rid)
		return
	}
```

In that same `switch subpath`, add a case (alongside `"snapshot"`/`"events"`):

```go
	case "approvals":
		s.handleListApprovals(w, r, clusterID)
```

In `handleMutation`, add a case to the `switch` (alongside `workloads/` and `nodes/`):

```go
	case strings.HasPrefix(subpath, "approvals/"):
		s.handleApprovalAction(w, r, clusterID, strings.TrimPrefix(subpath, "approvals/"))
```

- [ ] **Step 4: Write minimal implementation — handlers**

Add to `handlers.go`:

```go
// handleListApprovals serves GET /v1/clusters/{id}/approvals.
func (s *Server) handleListApprovals(w http.ResponseWriter, _ *http.Request, clusterID string) {
	if s.Approvals == nil {
		writeJSON(w, http.StatusOK, []PendingRequest{})
		return
	}
	writeJSON(w, http.StatusOK, s.Approvals.List(clusterID))
}

// handleGetApproval serves GET /v1/clusters/{id}/approvals/{rid}. Read-only,
// not audited (consistent with snapshot/events GETs).
func (s *Server) handleGetApproval(w http.ResponseWriter, _ *http.Request, clusterID, rid string) {
	if rid == "" || s.Approvals == nil {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	pr, ok := s.Approvals.Get(rid)
	if !ok || pr.ClusterID != clusterID {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	writeJSON(w, http.StatusOK, pr)
}

// handleApprovalAction dispatches POST .../approvals/{rid}/{approve|reject}.
func (s *Server) handleApprovalAction(w http.ResponseWriter, r *http.Request, clusterID, rest string) {
	switch {
	case strings.HasSuffix(rest, "/approve"):
		s.handleApprove(w, r, clusterID, strings.TrimSuffix(rest, "/approve"))
	case strings.HasSuffix(rest, "/reject"):
		s.handleReject(w, r, clusterID, strings.TrimSuffix(rest, "/reject"))
	default:
		writeError(w, http.StatusNotFound, "not found")
	}
}

// handleApprove serves POST .../approvals/{rid}/approve. Validates cluster
// ownership, enforces distinct-identity, executes the captured mutation, and
// finalizes the request. Every outcome is audited.
func (s *Server) handleApprove(w http.ResponseWriter, r *http.Request, clusterID, rid string) {
	if rid == "" || s.Approvals == nil {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	// Validate cluster ownership before mutating phase.
	if pr, ok := s.Approvals.Get(rid); !ok || pr.ClusterID != clusterID {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	approved, err := s.Approvals.Approve(rid, requestIdentity(r))
	if err != nil {
		status := approvalErrStatus(err)
		s.auditApproval(r, PendingRequest{ID: rid, ClusterID: clusterID}, status, err.Error())
		writeApprovalError(w, err)
		return
	}
	resultID, execMsg := s.executePending(r.Context(), approved)
	final, _ := s.Approvals.Complete(rid, resultID, execMsg)
	status := http.StatusOK
	if execMsg != "" {
		status = http.StatusBadGateway
	}
	s.auditApproval(r, final, status, execMsg)
	writeJSON(w, http.StatusOK, final)
}

// handleReject serves POST .../approvals/{rid}/reject. Any authenticated
// identity may reject (including the requester cancelling).
func (s *Server) handleReject(w http.ResponseWriter, r *http.Request, clusterID, rid string) {
	if rid == "" || s.Approvals == nil {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	if pr, ok := s.Approvals.Get(rid); !ok || pr.ClusterID != clusterID {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	final, err := s.Approvals.Reject(rid, "rejected by "+requestIdentity(r))
	if err != nil {
		s.auditApproval(r, PendingRequest{ID: rid, ClusterID: clusterID}, approvalErrStatus(err), err.Error())
		writeApprovalError(w, err)
		return
	}
	s.auditApproval(r, final, http.StatusOK, "")
	writeJSON(w, http.StatusOK, final)
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `go test ./app/gateway/internal/api/ -run 'TestApproveExecutes|TestSelfApprove|TestReject|TestDrainApproval|TestListAndGet' -v`
Expected: PASS.

- [ ] **Step 6: Run the full api package suite (regression check)**

Run: `go test ./app/gateway/internal/api/ -v`
Expected: PASS — all prior handler/policy tests still green.

- [ ] **Step 7: Commit**

```bash
git add app/gateway/internal/api/handlers.go app/gateway/internal/api/approval_test.go
git commit -m "feat(gateway): add approval list/get/approve/reject endpoints"
```

---

## Task 7: main.go wiring + env docs

**Files:**
- Modify: `app/gateway/cmd/clusterorbit-gateway/main.go`
- Modify: `CLAUDE.md` (repo root)

- [ ] **Step 1: Add `buildApprovalPolicy`**

Add to `main.go` near `buildNodePolicy` (it reuses `splitCSV`):

```go
// buildApprovalPolicy assembles an ApprovalPolicy + store from env. Returns
// (nil, nil, "off") when no op requires approval so handlers take the no-policy
// fast path.
//
//	CLUSTERORBIT_GATEWAY_POLICY_REQUIRE_APPROVAL  comma list: scale,restart,cordon,drain
//	CLUSTERORBIT_GATEWAY_POLICY_APPROVAL_TTL       Go duration, default 15m
func buildApprovalPolicy() (*api.ApprovalPolicy, *api.ApprovalStore, string) {
	ops := splitCSV(os.Getenv("CLUSTERORBIT_GATEWAY_POLICY_REQUIRE_APPROVAL"))
	if len(ops) == 0 {
		return nil, nil, "off"
	}
	required := make(map[string]bool, len(ops))
	for _, op := range ops {
		required[op] = true
	}
	ttl := 15 * time.Minute
	if raw := strings.TrimSpace(os.Getenv("CLUSTERORBIT_GATEWAY_POLICY_APPROVAL_TTL")); raw != "" {
		if d, err := time.ParseDuration(raw); err == nil && d > 0 {
			ttl = d
		}
	}
	return &api.ApprovalPolicy{RequiredOps: required}, api.NewApprovalStore(ttl), fmt.Sprintf("ops=%d ttl=%s", len(ops), ttl)
}
```

- [ ] **Step 2: Wire it into the server + warn on single token**

In `run()`, after the line `nodePolicy, nodePolicyLabel := buildNodePolicy()` add:

```go
	approvalPolicy, approvals, approvalLabel := buildApprovalPolicy()
	if approvalPolicy != nil && len(tokens) < 2 {
		log.Printf("gateway: WARNING approval policy is set but %d token(s) configured; two-person approval needs >=2 distinct tokens", len(tokens))
	}
```

Then extend the `&api.Server{...}` literal with:

```go
		ApprovalPolicy: approvalPolicy,
		Approvals:      approvals,
```

- [ ] **Step 3: Add `approval` to the startup banner**

Change the banner `Printf` format string to append ` approval=%s` and add `approvalLabel` as the final argument:

```go
	fmt.Printf("%s listening on %s (auth=%s backend=%s tls=%s rate=%s audit=%s policy=%s nodePolicy=%s approval=%s)\n",
		startupBanner, addr, authLabel(tokens), backendLabel, tlsLabel, rateLabel(limiter), auditLabel, policyLabel, nodePolicyLabel, approvalLabel)
```

- [ ] **Step 4: Build & vet**

Run: `go build ./app/gateway/... && go vet ./app/gateway/...`
Expected: clean (no output).

- [ ] **Step 5: Document the env vars in CLAUDE.md**

In `CLAUDE.md` (repo root), in the gateway section, find the line listing policy gates that ends with `_POLICY_DISABLE_DRAIN` (cordon/drain). Append to that same paragraph:

```
Async approval: `_POLICY_REQUIRE_APPROVAL` (comma list of `scale,restart,cordon,drain` op-classes that must be parked for a second-person approval), `_POLICY_APPROVAL_TTL` (Go duration, default `15m`). Approval needs ≥2 distinct tokens (`_TOKENS`) to be meaningful; pending requests are in-memory and dropped on restart.
```

- [ ] **Step 6: Commit**

```bash
git add app/gateway/cmd/clusterorbit-gateway/main.go CLAUDE.md
git commit -m "feat(gateway): wire approval policy env + startup banner"
```

---

## Task 8: Full verification + handover note

**Files:**
- Modify: `docs/engineering/claude-handover.md`

- [ ] **Step 1: gofmt check (CI requires clean)**

Run: `gofmt -l app/gateway`
Expected: no output. If any file is listed, run `gofmt -w <file>` and re-check.

- [ ] **Step 2: Full gateway test + vet + mod tidy (mirrors CI)**

Run: `go test ./app/gateway/... -cover && go vet ./app/gateway/... && go mod tidy`
Expected: all packages PASS; vet clean; `go mod tidy` produces no diff (`git status` clean for go.mod/go.sum).

- [ ] **Step 3: Update the handover doc**

In `docs/engineering/claude-handover.md`, under "Recommended Next Tasks", replace item 1 (the "Two-person approval flow" bullet) with a done-note and renumber the remaining items, e.g.:

```
1. **Two-person approval flow — DONE (gateway).** `ApprovalPolicy` parks
   configured op-classes (`scale`/`restart`/`cordon`/`drain`); a distinct
   identity approves via `POST .../approvals/{id}/approve`, which executes the
   captured mutation. In-memory, TTL'd, audited. Env:
   `_POLICY_REQUIRE_APPROVAL`, `_POLICY_APPROVAL_TTL`. **Mobile UI is the
   follow-up** — list/approve/reject pending requests from the app.
```

- [ ] **Step 4: Commit**

```bash
git add docs/engineering/claude-handover.md
git commit -m "docs(gateway): mark two-person approval flow done, note mobile follow-up"
```

- [ ] **Step 5: Final sanity — list new endpoints**

Confirm the gateway now serves (manually eyeball `handlers.go` routing):
- `POST .../workloads/{wid}/scale|restart` → `202` when gated
- `POST .../nodes/{nid}/cordon|drain` → `202` when gated
- `GET .../approvals`, `GET .../approvals/{rid}`
- `POST .../approvals/{rid}/approve|reject`

---

## Self-Review

**Spec coverage:**
- ApprovalPolicy permissive default → Task 1. ✔
- ApprovalStore in-memory + TTL → Tasks 1, 2. ✔
- Park returns 202 + PendingRequest, no backend call → Task 5. ✔
- Distinct-identity 409 on self-approve, self-reject allowed → Tasks 3, 6. ✔
- Approve executes + Complete; drain returns ResultID → Tasks 3, 4, 6. ✔
- Handler ordering (403 gate before approval gate) → Task 5 (insertion point is after each policy block). ✔
- List/get/approve/reject endpoints + routing → Task 6. ✔
- AuditEntry.ApprovalID threading park→approve→execute → Tasks 4, 5, 6. ✔
- Env vars + single-token warning + banner → Task 7. ✔
- Known limitation (restart drops requests) documented → Task 7 CLAUDE.md. ✔
- Cordon gates only `unschedulable` (uncordon exempt) → Task 5 (`if unschedulable && ...`). ✔

**Placeholder scan:** No TBD/TODO. The `import_marker_for_errors` line in Task 3 is explicitly flagged as a non-code marker with instructions to add `"errors"` to the test imports instead.

**Type consistency:** `PendingRequest`, `ApprovalStore`, `Park/Get/List/Approve/Reject/Complete`, phase constants (`ApprovalPhase*`), op constants (`Op*`), `requestIdentity`, `executePending`, `auditApproval`, `approvalErrStatus`, `writeApprovalError`, `AuditEntry.ApprovalID`, `Server.ApprovalPolicy`/`Server.Approvals` are named identically across all tasks. Store methods return `PendingRequest` (value copies) consistently; handlers consume copies.
