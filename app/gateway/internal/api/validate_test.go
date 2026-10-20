package api

import (
	"bytes"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestParseWorkloadID(t *testing.T) {
	kind, ns, name, err := ParseWorkloadID("statefulSet:kube-system/etcd.v3")
	if err != nil || kind != "statefulSet" || ns != "kube-system" || name != "etcd.v3" {
		t.Fatalf("ParseWorkloadID = %q %q %q %v", kind, ns, name, err)
	}

	for _, id := range []string{
		"",
		"bogus",
		"deployment:platform",
		"deployment:/api",
		"deployment:platform/",
		"pod:platform/api",
		"Deployment:platform/api",
		"deployment:../api",
		"deployment:platform/..",
		"deployment:platform/a..b",
		"deployment:allowed/../../victim/x",
		"deployment:platform/api/status",
		"deployment:platform/api%2Fstatus",
		"deployment:Platform/api",
		"deployment:platform/-api",
		"deployment:platform.x/api",
		"deployment:" + strings.Repeat("a", 64) + "/api",
	} {
		if _, _, _, err := ParseWorkloadID(id); !errors.Is(err, ErrBadRequest) {
			t.Errorf("ParseWorkloadID(%q) err = %v, want ErrBadRequest", id, err)
		}
	}
}

func TestValidateNodeID(t *testing.T) {
	for _, id := range []string{"worker-1", "ip-10-0-1-23.ec2.internal", "cp-1.gateway-demo"} {
		if err := ValidateNodeID(id); err != nil {
			t.Errorf("ValidateNodeID(%q) = %v, want nil", id, err)
		}
	}
	for _, id := range []string{
		"", "..", ".", "worker-1/proxy", "worker-1/../control-plane", "worker-1%2Fproxy",
		"Worker-1", "worker-1.", ".worker-1", "worker..1", strings.Repeat("a", 254),
	} {
		if err := ValidateNodeID(id); !errors.Is(err, ErrBadRequest) {
			t.Errorf("ValidateNodeID(%q) = %v, want ErrBadRequest", id, err)
		}
	}
}

func TestValidateEventQuery(t *testing.T) {
	cases := []struct {
		kind, name, ns string
		ok             bool
	}{
		{"node", "worker-1", "", true},
		{"workload", "api", "platform", true},
		{"Deployment", "api", "platform", true},
		{"", "api", "", true},
		{"widget", "api", "", false},
		{"Pod,reason=Killing", "api", "", false},
		{"pod", "", "", false},
		{"pod", "api,involvedObject.namespace=x", "", false},
		{"service", "dash", "kube-system/services/http:dash:80/proxy/admin", false},
		{"pod", "api", "..", false},
	}
	for _, tc := range cases {
		err := ValidateEventQuery(tc.kind, tc.name, tc.ns)
		if tc.ok && err != nil {
			t.Errorf("ValidateEventQuery(%q, %q, %q) = %v, want nil", tc.kind, tc.name, tc.ns, err)
		}
		if !tc.ok && !errors.Is(err, ErrBadRequest) {
			t.Errorf("ValidateEventQuery(%q, %q, %q) = %v, want ErrBadRequest", tc.kind, tc.name, tc.ns, err)
		}
	}
}

// Target IDs are validated before the policy gates: "allowed/../../victim"
// must not pass a namespace allowlist on its first segment, and
// "worker-1/../control-plane" must not slip past a protected-node denylist.
func TestMutationsRejectUnsafeTargetIDs(t *testing.T) {
	cases := []struct{ name, path, body string }{
		{"scale dot-dot escape", "/workloads/deployment:allowed%2F..%2F..%2Fvictim%2Fx/scale", `{"replicas":1}`},
		{"scale status subresource", "/workloads/deployment:allowed/api/status/scale", `{"replicas":1}`},
		{"scale encoded slash in name", "/workloads/deployment:allowed/api%252Fstatus/scale", `{"replicas":1}`},
		{"restart dot-dot namespace", "/workloads/deployment:../api/restart", ""},
		{"cordon dot-dot escape", "/nodes/worker-1%2F..%2Fcontrol-plane/cordon", ""},
		{"uncordon node proxy", "/nodes/worker-1/proxy/pods/uncordon", ""},
		{"drain dot-dot escape", "/nodes/worker-1%2F..%2Fcontrol-plane/drain", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rb := &recordingBackend{ClusterBackend: NewSampleBackend()}
			var entries []AuditEntry
			s := &Server{
				Backend:     rb,
				ScalePolicy: &ScalePolicy{AllowedNamespaces: []string{"allowed"}},
				NodePolicy:  &NodePolicy{ProtectedNodes: []string{"control-plane"}},
				AuditSink:   func(e AuditEntry) { entries = append(entries, e) },
			}
			ts := httptest.NewServer(s.Handler())
			defer ts.Close()

			resp, err := http.Post(ts.URL+"/v1/clusters/demo"+tc.path, "application/json", bytes.NewBufferString(tc.body))
			if err != nil {
				t.Fatalf("post: %v", err)
			}
			resp.Body.Close()
			if resp.StatusCode != http.StatusBadRequest {
				t.Fatalf("status = %d, want 400", resp.StatusCode)
			}
			if rb.scaleCalls+rb.restartCalls+rb.cordonCalls+rb.startDrainCalls != 0 {
				t.Fatalf("backend must not be called: %+v", rb)
			}
			if len(entries) != 1 || entries[0].Status != http.StatusBadRequest || entries[0].Error == "" {
				t.Fatalf("audit entries = %+v", entries)
			}
		})
	}
}

func TestReadsRejectUnsafeNames(t *testing.T) {
	rb := &recordingBackend{ClusterBackend: NewSampleBackend()}
	ts := httptest.NewServer((&Server{Backend: rb}).Handler())
	defer ts.Close()

	for _, path := range []string{
		"/nodes/worker-1%2Fproxy/drain/job-1",
		"/events?kind=Pod,reason%3DKilling&objectName=api",
		"/events?kind=pod&objectName=api,involvedObject.namespace%3Dx",
		"/events?kind=service&objectName=dash&namespace=kube-system%2Fservices%2Fhttp:dash:80%2Fproxy%2Fadmin",
	} {
		resp, err := http.Get(ts.URL + "/v1/clusters/demo" + path)
		if err != nil {
			t.Fatalf("get %s: %v", path, err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusBadRequest {
			t.Errorf("GET %s status = %d, want 400", path, resp.StatusCode)
		}
	}
	if rb.drainStatusCalls != 0 {
		t.Fatalf("DrainStatus must not be called, got %d", rb.drainStatusCalls)
	}
}
