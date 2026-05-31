package api

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestScalePolicyEvaluate(t *testing.T) {
	cases := []struct {
		name     string
		policy   *ScalePolicy
		workload string
		replicas int
		want     string // empty == allowed
	}{
		{"nil policy allows", nil, "deployment:platform/api", 99, ""},
		{"zero value allows", &ScalePolicy{}, "deployment:platform/api", 99, ""},
		{
			"max replicas exceeded",
			&ScalePolicy{MaxReplicas: 10},
			"deployment:platform/api",
			11,
			"replicas 11 exceeds max 10",
		},
		{
			"max replicas at limit ok",
			&ScalePolicy{MaxReplicas: 10},
			"deployment:platform/api",
			10,
			"",
		},
		{
			"namespace allowlist hit",
			&ScalePolicy{AllowedNamespaces: []string{"platform", "infra"}},
			"deployment:platform/api",
			5,
			"",
		},
		{
			"namespace not allowed",
			&ScalePolicy{AllowedNamespaces: []string{"platform"}},
			"deployment:payments/ledger",
			5,
			`namespace "payments" not in allowlist`,
		},
		{
			"malformed workload id fails closed",
			&ScalePolicy{AllowedNamespaces: []string{"platform"}},
			"bogus",
			1,
			"workload id missing namespace",
		},
		{
			"max checked before namespace",
			&ScalePolicy{MaxReplicas: 2, AllowedNamespaces: []string{"platform"}},
			"deployment:platform/api",
			3,
			"replicas 3 exceeds max 2",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := tc.policy.Evaluate(tc.workload, tc.replicas)
			if got != tc.want {
				t.Fatalf("Evaluate = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestNodePolicyEvaluateCordon(t *testing.T) {
	cases := []struct {
		name          string
		policy        *NodePolicy
		nodeID        string
		unschedulable bool
		want          string // empty == allowed
	}{
		{"nil policy allows", nil, "worker-1", true, ""},
		{"zero value allows", &NodePolicy{}, "worker-1", true, ""},
		{
			"uncordon exempt from allowlist",
			&NodePolicy{AllowedNodes: []string{"worker-1"}},
			"worker-9", false, "",
		},
		{
			"uncordon exempt from protected",
			&NodePolicy{ProtectedNodes: []string{"control-plane"}},
			"control-plane", false, "",
		},
		{
			"cordon node in allowlist",
			&NodePolicy{AllowedNodes: []string{"worker-1", "worker-2"}},
			"worker-1", true, "",
		},
		{
			"cordon node not in allowlist",
			&NodePolicy{AllowedNodes: []string{"worker-1"}},
			"worker-9", true,
			`node "worker-9" not in allowlist`,
		},
		{
			"cordon protected node",
			&NodePolicy{ProtectedNodes: []string{"control-plane"}},
			"control-plane", true,
			`node "control-plane" is protected`,
		},
		{
			"protected beats allowlist",
			&NodePolicy{AllowedNodes: []string{"control-plane"}, ProtectedNodes: []string{"control-plane"}},
			"control-plane", true,
			`node "control-plane" is protected`,
		},
		{
			"empty node id fails closed",
			&NodePolicy{AllowedNodes: []string{"worker-1"}},
			"", true,
			"node id is empty",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := tc.policy.EvaluateCordon(tc.nodeID, tc.unschedulable)
			if got != tc.want {
				t.Fatalf("EvaluateCordon = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestNodePolicyEvaluateDrain(t *testing.T) {
	cases := []struct {
		name   string
		policy *NodePolicy
		nodeID string
		want   string // empty == allowed
	}{
		{"nil policy allows", nil, "worker-1", ""},
		{"zero value allows", &NodePolicy{}, "worker-1", ""},
		{
			"drain disabled kill switch",
			&NodePolicy{DisableDrain: true},
			"worker-1",
			"node drain is disabled by policy",
		},
		{
			"kill switch beats allowlist hit",
			&NodePolicy{DisableDrain: true, AllowedNodes: []string{"worker-1"}},
			"worker-1",
			"node drain is disabled by policy",
		},
		{
			"drain node in allowlist",
			&NodePolicy{AllowedNodes: []string{"worker-1"}},
			"worker-1", "",
		},
		{
			"drain node not in allowlist",
			&NodePolicy{AllowedNodes: []string{"worker-1"}},
			"worker-9",
			`node "worker-9" not in allowlist`,
		},
		{
			"drain protected node",
			&NodePolicy{ProtectedNodes: []string{"control-plane"}},
			"control-plane",
			`node "control-plane" is protected`,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := tc.policy.EvaluateDrain(tc.nodeID)
			if got != tc.want {
				t.Fatalf("EvaluateDrain = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestCordonNodePolicyForbidden(t *testing.T) {
	var entries []AuditEntry
	rb := &recordingBackend{ClusterBackend: NewSampleBackend()}
	s := &Server{
		Backend:    rb,
		NodePolicy: &NodePolicy{ProtectedNodes: []string{"control-plane"}},
		AuditSink:  func(e AuditEntry) { entries = append(entries, e) },
	}
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	resp, err := http.Post(ts.URL+"/v1/clusters/demo/nodes/control-plane/cordon", "application/json", nil)
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		raw, _ := io.ReadAll(resp.Body)
		t.Fatalf("status = %d body = %s, want 403", resp.StatusCode, raw)
	}
	if rb.cordonCalls != 0 {
		t.Fatalf("backend cordon should not be called, got %d calls", rb.cordonCalls)
	}
	if len(entries) != 1 || entries[0].Status != http.StatusForbidden || entries[0].Error == "" {
		t.Fatalf("audit entry should record policy reason: %+v", entries)
	}
}

func TestUncordonNodePolicyAllowsProtected(t *testing.T) {
	rb := &recordingBackend{ClusterBackend: NewSampleBackend()}
	s := &Server{
		Backend:    rb,
		NodePolicy: &NodePolicy{ProtectedNodes: []string{"control-plane"}},
	}
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	resp, err := http.Post(ts.URL+"/v1/clusters/demo/nodes/control-plane/uncordon", "application/json", nil)
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200 (uncordon must bypass protection)", resp.StatusCode)
	}
	if rb.cordonCalls != 1 {
		t.Fatalf("backend cordon (uncordon) should be called once, got %d", rb.cordonCalls)
	}
}

func TestStartDrainPolicyForbidden(t *testing.T) {
	var entries []AuditEntry
	rb := &recordingBackend{
		ClusterBackend: NewSampleBackend(),
		drainJob:       DrainJob{ID: "job-1", NodeID: "control-plane", Phase: DrainPhasePending},
	}
	s := &Server{
		Backend:    rb,
		NodePolicy: &NodePolicy{ProtectedNodes: []string{"control-plane"}},
		AuditSink:  func(e AuditEntry) { entries = append(entries, e) },
	}
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	resp, err := http.Post(ts.URL+"/v1/clusters/demo/nodes/control-plane/drain", "application/json", nil)
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		raw, _ := io.ReadAll(resp.Body)
		t.Fatalf("status = %d body = %s, want 403", resp.StatusCode, raw)
	}
	if rb.startDrainCalls != 0 {
		t.Fatalf("backend StartDrain should not be called, got %d calls", rb.startDrainCalls)
	}
	if len(entries) != 1 || entries[0].Status != http.StatusForbidden || entries[0].Error == "" {
		t.Fatalf("audit entry should record policy reason: %+v", entries)
	}
}

func TestStartDrainPolicyAllowed(t *testing.T) {
	rb := &recordingBackend{
		ClusterBackend: NewSampleBackend(),
		drainJob:       DrainJob{ID: "job-1", NodeID: "worker-1", Phase: DrainPhasePending},
	}
	s := &Server{
		Backend:    rb,
		NodePolicy: &NodePolicy{AllowedNodes: []string{"worker-1"}},
	}
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	resp, err := http.Post(ts.URL+"/v1/clusters/demo/nodes/worker-1/drain", "application/json", nil)
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusAccepted {
		t.Fatalf("status = %d, want 202", resp.StatusCode)
	}
	if rb.startDrainCalls != 1 {
		t.Fatalf("backend StartDrain should be called once, got %d", rb.startDrainCalls)
	}
}

func TestScaleWorkloadPolicyForbidden(t *testing.T) {
	var entries []AuditEntry
	rb := &recordingBackend{ClusterBackend: NewSampleBackend()}
	s := &Server{
		Backend:     rb,
		ScalePolicy: &ScalePolicy{MaxReplicas: 3},
		AuditSink: func(e AuditEntry) {
			entries = append(entries, e)
		},
	}
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	resp, err := http.Post(ts.URL+"/v1/clusters/demo/workloads/deployment:platform/api/scale",
		"application/json", bytes.NewBufferString(`{"replicas":10}`))
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		raw, _ := io.ReadAll(resp.Body)
		t.Fatalf("status = %d body = %s, want 403", resp.StatusCode, raw)
	}
	if rb.scaleCalls != 0 {
		t.Fatalf("backend scale should not be called, got %d calls", rb.scaleCalls)
	}
	if len(entries) != 1 || entries[0].Status != http.StatusForbidden {
		t.Fatalf("audit entries = %+v", entries)
	}
	if entries[0].Error == "" {
		t.Fatalf("audit entry should record policy reason, got empty")
	}
}

func TestScaleWorkloadPolicyNamespaceBlocks(t *testing.T) {
	rb := &recordingBackend{ClusterBackend: NewSampleBackend()}
	s := &Server{
		Backend:     rb,
		ScalePolicy: &ScalePolicy{AllowedNamespaces: []string{"platform"}},
	}
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	resp, err := http.Post(ts.URL+"/v1/clusters/demo/workloads/deployment:payments/ledger/scale",
		"application/json", bytes.NewBufferString(`{"replicas":2}`))
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", resp.StatusCode)
	}
	if rb.scaleCalls != 0 {
		t.Fatalf("backend scale should not be called on namespace violation")
	}
}

func TestScaleWorkloadPolicyAllowed(t *testing.T) {
	rb := &recordingBackend{ClusterBackend: NewSampleBackend()}
	s := &Server{
		Backend:     rb,
		ScalePolicy: &ScalePolicy{MaxReplicas: 10, AllowedNamespaces: []string{"platform"}},
	}
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	resp, err := http.Post(ts.URL+"/v1/clusters/demo/workloads/deployment:platform/api/scale",
		"application/json", bytes.NewBufferString(`{"replicas":5}`))
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	if rb.scaleCalls != 1 || rb.gotReplicas != 5 {
		t.Fatalf("backend scale not called as expected: %+v", rb)
	}
}
