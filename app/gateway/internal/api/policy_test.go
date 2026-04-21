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
