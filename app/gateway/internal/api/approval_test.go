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
