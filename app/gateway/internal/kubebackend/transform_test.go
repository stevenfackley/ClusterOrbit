package kubebackend

import (
	"encoding/json"
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
