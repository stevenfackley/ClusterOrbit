package api

import (
	"errors"
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
