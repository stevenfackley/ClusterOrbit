package kubebackend

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"

	"github.com/stevenfackley/clusterorbit/app/gateway/internal/kubeconfig"
)

func TestRestClientSendsBearerToken(t *testing.T) {
	var gotAuth, gotAccept, gotPath, gotQuery string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		gotAccept = r.Header.Get("Accept")
		gotPath = r.URL.Path
		gotQuery = r.URL.RawQuery
		_ = json.NewEncoder(w).Encode(map[string]any{"items": []any{}})
	}))
	defer ts.Close()

	client, err := NewRestClient(&kubeconfig.ResolvedCluster{
		Server:      ts.URL,
		BearerToken: "abc123",
	})
	if err != nil {
		t.Fatalf("new client: %v", err)
	}
	body, err := client.GetJSON(context.Background(), "/api/v1/nodes", url.Values{
		"limit": []string{"5"},
	})
	if err != nil {
		t.Fatalf("GetJSON: %v", err)
	}
	if _, ok := body["items"]; !ok {
		t.Fatalf("expected items key, got %#v", body)
	}
	if gotAuth != "Bearer abc123" {
		t.Fatalf("Authorization = %q", gotAuth)
	}
	if gotAccept != "application/json" {
		t.Fatalf("Accept = %q", gotAccept)
	}
	if gotPath != "/api/v1/nodes" {
		t.Fatalf("path = %q", gotPath)
	}
	if gotQuery != "limit=5" {
		t.Fatalf("query = %q", gotQuery)
	}
}

func TestRestClientErrorOnNon2xx(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "forbidden", http.StatusForbidden)
	}))
	defer ts.Close()

	client, err := NewRestClient(&kubeconfig.ResolvedCluster{Server: ts.URL})
	if err != nil {
		t.Fatalf("new client: %v", err)
	}
	if _, err := client.GetJSON(context.Background(), "/api/v1/pods", nil); err == nil {
		t.Fatalf("expected error for 403")
	}
}

func TestRestClientRejectsBadServer(t *testing.T) {
	if _, err := NewRestClient(&kubeconfig.ResolvedCluster{Server: "not a url"}); err == nil {
		t.Fatalf("expected error for missing scheme/host")
	}
}
