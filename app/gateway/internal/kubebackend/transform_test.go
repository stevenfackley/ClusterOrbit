package kubebackend

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/stevenfackley/clusterorbit/app/gateway/internal/api"
)

// assertNoNullArrays fails if any array-typed field in the decoded JSON tree
// is null. Optional scalar pointers (label, clusterIp, name) may legitimately
// be null, so only the known array field names are checked.
func assertNoNullArrays(t *testing.T, path string, v any) {
	t.Helper()
	switch x := v.(type) {
	case map[string]any:
		for k, val := range x {
			if val == nil && isArrayField(k) {
				t.Errorf("%s.%s marshaled as null, want []", path, k)
			}
			assertNoNullArrays(t, path+"."+k, val)
		}
	case []any:
		for _, val := range x {
			assertNoNullArrays(t, path+"[]", val)
		}
	}
}

func isArrayField(name string) bool {
	switch name {
	case "nodes", "workloads", "services", "alerts", "links", "ports",
		"nodeIds", "images", "targetWorkloadIds":
		return true
	}
	return false
}

func TestTransformSnapshotNeverMarshalsNullArrays(t *testing.T) {
	services := map[string]any{"items": []any{
		map[string]any{
			"metadata": map[string]any{"namespace": "default", "name": "kubernetes"},
			"spec":     map[string]any{"clusterIP": "10.0.0.1"},
		},
	}}
	snap := transformSnapshot(
		api.ClusterProfile{ID: "c"},
		time.Unix(0, 0),
		map[string]any{}, map[string]any{}, services,
		map[string]any{}, map[string]any{}, map[string]any{}, map[string]any{}, map[string]any{},
	)
	raw, err := json.Marshal(snap)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	assertNoNullArrays(t, "", decoded)
}

func podItem(namespace, name, owner string, labels map[string]any) map[string]any {
	return map[string]any{
		"metadata": map[string]any{
			"namespace": namespace,
			"name":      name,
			"labels":    labels,
			"ownerReferences": []any{
				map[string]any{"kind": "DaemonSet", "name": owner},
			},
		},
		"spec":   map[string]any{"nodeName": "n1"},
		"status": map[string]any{"phase": "Running"},
	}
}

func snapshotFor(pods, services, daemonSets, jobs []any) api.ClusterSnapshot {
	list := func(items []any) map[string]any { return map[string]any{"items": items} }
	return transformSnapshot(
		api.ClusterProfile{ID: "c"},
		time.Unix(0, 0),
		map[string]any{}, list(pods), list(services),
		map[string]any{}, list(daemonSets), map[string]any{}, list(jobs), map[string]any{},
	)
}

func serviceItem(namespace, name string, selector map[string]any) map[string]any {
	spec := map[string]any{}
	if selector != nil {
		spec["selector"] = selector
	}
	return map[string]any{
		"metadata": map[string]any{"namespace": namespace, "name": name},
		"spec":     spec,
	}
}

func daemonSetItem(namespace, name string) map[string]any {
	return map[string]any{
		"metadata": map[string]any{"namespace": namespace, "name": name},
		"status":   map[string]any{"desiredNumberScheduled": 1, "numberReady": 1},
	}
}

func serviceAlertCount(snap api.ClusterSnapshot) int {
	n := 0
	for _, a := range snap.Alerts {
		if strings.HasPrefix(a.ID, "service-") {
			n++
		}
	}
	return n
}

func TestServiceTargetsAndHealth(t *testing.T) {
	labels := map[string]any{"app": "web"}
	pods := []any{
		podItem("a", "web-a", "web", labels),
		podItem("b", "web-b", "web", labels),
	}
	daemonSets := []any{daemonSetItem("a", "web"), daemonSetItem("b", "web")}

	tests := []struct {
		name        string
		service     map[string]any
		wantTargets []string
		wantHealth  string
		wantAlerts  int
	}{
		{
			name:        "selector is scoped to the service namespace",
			service:     serviceItem("a", "web", map[string]any{"app": "web"}),
			wantTargets: []string{"daemonSet:a/web"},
			wantHealth:  healthHealthy,
		},
		{
			name:        "selector matching nothing warns",
			service:     serviceItem("a", "web", map[string]any{"app": "other"}),
			wantTargets: []string{},
			wantHealth:  healthWarning,
			wantAlerts:  1,
		},
		{
			name:        "selector matching only another namespace warns",
			service:     serviceItem("c", "web", map[string]any{"app": "web"}),
			wantTargets: []string{},
			wantHealth:  healthWarning,
			wantAlerts:  1,
		},
		{
			name:        "selectorless service is healthy with no alert",
			service:     serviceItem("default", "kubernetes", nil),
			wantTargets: []string{},
			wantHealth:  healthHealthy,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			snap := snapshotFor(pods, []any{tc.service}, daemonSets, nil)
			if len(snap.Services) != 1 {
				t.Fatalf("services = %d, want 1", len(snap.Services))
			}
			svc := snap.Services[0]
			if !reflect.DeepEqual(svc.TargetWorkloadIDs, tc.wantTargets) {
				t.Errorf("targets = %v, want %v", svc.TargetWorkloadIDs, tc.wantTargets)
			}
			if svc.Health != tc.wantHealth {
				t.Errorf("health = %q, want %q", svc.Health, tc.wantHealth)
			}
			if got := serviceAlertCount(snap); got != tc.wantAlerts {
				t.Errorf("service alerts = %d, want %d", got, tc.wantAlerts)
			}
		})
	}
}

func TestJobHealthAndAlerts(t *testing.T) {
	job := func(status map[string]any) map[string]any {
		return map[string]any{
			"metadata": map[string]any{"namespace": "default", "name": "j"},
			"spec":     map[string]any{"completions": 1},
			"status":   status,
		}
	}
	tests := []struct {
		name       string
		status     map[string]any
		wantHealth string
		wantAlert  bool
	}{
		{"running", map[string]any{"active": 1}, healthHealthy, false},
		{"running after a retry", map[string]any{"active": 1, "failed": 1}, healthHealthy, false},
		{"succeeded", map[string]any{"succeeded": 1}, healthHealthy, false},
		{"succeeded after retries", map[string]any{"succeeded": 1, "failed": 2}, healthHealthy, false},
		{"failed pods, nothing active", map[string]any{"failed": 3}, healthWarning, true},
		{
			"failed condition",
			map[string]any{"conditions": []any{map[string]any{"type": "Failed", "status": "True"}}},
			healthWarning, true,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			snap := snapshotFor(nil, nil, nil, []any{job(tc.status)})
			if len(snap.Workloads) != 1 {
				t.Fatalf("workloads = %d, want 1", len(snap.Workloads))
			}
			if got := snap.Workloads[0].Health; got != tc.wantHealth {
				t.Errorf("health = %q, want %q", got, tc.wantHealth)
			}
			if got := len(snap.Alerts) > 0; got != tc.wantAlert {
				t.Errorf("alerts = %v, want alert=%v", snap.Alerts, tc.wantAlert)
			}
		})
	}
}
