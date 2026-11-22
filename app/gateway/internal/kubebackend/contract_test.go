package kubebackend

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/stevenfackley/clusterorbit/app/gateway/internal/kubeconfig"
)

// The snapshot contract. Direct mode (the app's kubernetes_snapshot_loader.dart)
// and the gateway (transform.go) must reduce the same Kubernetes lists to the
// same snapshot. Both read testdata/contract/snapshot-lists.json at the repo
// root, keyed by API path, and compare what they build with
// testdata/contract/snapshot.json; the app's snapshot_contract_test.dart is
// the other half. profile and generatedAt depend on the connection and the
// clock, not on the lists, so neither file holds them.
//
// After changing a rule on both sides, regenerate the expected file with
//
//	go test ./app/gateway/internal/kubebackend -run TestSnapshotContract -update-contract
//
// and check that the app's half still passes.
var updateContract = flag.Bool("update-contract", false,
	"rewrite testdata/contract/snapshot.json from the gateway's output")

var contractDir = filepath.Join("..", "..", "..", "..", "testdata", "contract")

func TestSnapshotContract(t *testing.T) {
	var lists map[string]json.RawMessage
	readContractJSON(t, "snapshot-lists.json", &lists)

	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, ok := lists[strings.TrimPrefix(r.URL.Path, "/")]
		if !ok {
			http.Error(w, "not in the contract: "+r.URL.Path, http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(body)
	}))
	defer ts.Close()

	backend, err := NewKubeBackend(&kubeconfig.ResolvedCluster{Server: ts.URL, ContextName: "contract"})
	if err != nil {
		t.Fatalf("new backend: %v", err)
	}
	backend.now = func() time.Time { return time.UnixMilli(0) }
	snap, err := backend.LoadSnapshot(context.Background(), "contract")
	if err != nil {
		t.Fatalf("LoadSnapshot: %v", err)
	}

	raw, err := json.Marshal(snap)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var got map[string]any
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	delete(got, "profile")
	delete(got, "generatedAt")

	if *updateContract {
		writeContractSnapshot(t, got)
		return
	}

	var want map[string]any
	readContractJSON(t, "snapshot.json", &want)
	for _, key := range contractSnapshotKeys {
		if !reflect.DeepEqual(got[key], want[key]) {
			gotJSON, _ := json.MarshalIndent(got[key], "", "  ")
			wantJSON, _ := json.MarshalIndent(want[key], "", "  ")
			t.Errorf("%s differs from testdata/contract/snapshot.json\ngot:  %s\nwant: %s", key, gotJSON, wantJSON)
		}
	}
	if len(got) != len(want) {
		t.Errorf("snapshot keys = %d, contract has %d", len(got), len(want))
	}
}

// contractSnapshotKeys are the snapshot fields the contract fixes, in the
// order snapshot.json lists them.
var contractSnapshotKeys = []string{"nodes", "workloads", "services", "alerts", "links"}

func readContractJSON(t *testing.T, name string, v any) {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(contractDir, name))
	if err != nil {
		t.Fatalf("read %s: %v", name, err)
	}
	if err := json.Unmarshal(data, v); err != nil {
		t.Fatalf("parse %s: %v", name, err)
	}
}

// writeContractSnapshot writes snap with one entity per line, so a changed
// rule shows up in review as the entities it changed.
func writeContractSnapshot(t *testing.T, snap map[string]any) {
	t.Helper()
	var out bytes.Buffer
	out.WriteString("{\n")
	for i, key := range contractSnapshotKeys {
		items, _ := snap[key].([]any)
		out.WriteString(`  "` + key + `": [`)
		for j, item := range items {
			line, err := json.Marshal(item)
			if err != nil {
				t.Fatalf("marshal %s: %v", key, err)
			}
			out.WriteString("\n    ")
			out.Write(line)
			if j < len(items)-1 {
				out.WriteString(",")
			}
		}
		if len(items) > 0 {
			out.WriteString("\n  ")
		}
		out.WriteString("]")
		if i < len(contractSnapshotKeys)-1 {
			out.WriteString(",")
		}
		out.WriteString("\n")
	}
	out.WriteString("}\n")
	if err := os.WriteFile(filepath.Join(contractDir, "snapshot.json"), out.Bytes(), 0o644); err != nil {
		t.Fatalf("write snapshot.json: %v", err)
	}
}
