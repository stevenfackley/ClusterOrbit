package kubebackend

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"math/big"
	"net/http"
	"net/http/httptest"
	"net/url"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stevenfackley/clusterorbit/app/gateway/internal/api"
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

func TestRestClientKeepsServerPathPrefix(t *testing.T) {
	var gotPaths []string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPaths = append(gotPaths, r.Method+" "+r.URL.Path)
		_, _ = w.Write([]byte(`{}`))
	}))
	defer ts.Close()

	// Trailing slash on the prefix must not produce a double slash.
	for _, prefix := range []string{"/k8s/clusters/c-1", "/k8s/clusters/c-1/"} {
		gotPaths = nil
		client, err := NewRestClient(&kubeconfig.ResolvedCluster{Server: ts.URL + prefix})
		if err != nil {
			t.Fatalf("new client: %v", err)
		}
		ctx := context.Background()
		if _, err := client.GetJSON(ctx, "/api/v1/nodes", nil); err != nil {
			t.Fatalf("GetJSON: %v", err)
		}
		if _, err := client.Patch(ctx, "/api/v1/nodes/n1", "application/merge-patch+json", []byte(`{}`)); err != nil {
			t.Fatalf("Patch: %v", err)
		}
		if _, _, err := client.Post(ctx, "/api/v1/namespaces/a/pods/p/eviction", "application/json", []byte(`{}`)); err != nil {
			t.Fatalf("Post: %v", err)
		}
		want := []string{
			"GET /k8s/clusters/c-1/api/v1/nodes",
			"PATCH /k8s/clusters/c-1/api/v1/nodes/n1",
			"POST /k8s/clusters/c-1/api/v1/namespaces/a/pods/p/eviction",
		}
		if !reflect.DeepEqual(gotPaths, want) {
			t.Fatalf("prefix %q: paths = %v, want %v", prefix, gotPaths, want)
		}
	}
}

func TestRestClientReturnsShortStatusError(t *testing.T) {
	long := strings.Repeat("x", 1000)
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnprocessableEntity)
		_, _ = w.Write([]byte(`{"kind":"Status","apiVersion":"v1","status":"Failure","reason":"Invalid","message":"` + long + `","details":{"secret":"hidden"}}`))
	}))
	defer ts.Close()

	client, err := NewRestClient(&kubeconfig.ResolvedCluster{Server: ts.URL})
	if err != nil {
		t.Fatalf("new client: %v", err)
	}
	_, err = client.Patch(context.Background(), "/x", "application/merge-patch+json", []byte(`{}`))
	var se *StatusError
	if !errors.As(err, &se) {
		t.Fatalf("expected *StatusError, got %T: %v", err, err)
	}
	if se.Code != http.StatusUnprocessableEntity || se.Reason != "Invalid" {
		t.Fatalf("StatusError = %+v", se)
	}
	if len(se.Message) > maxStatusMessage+len("…") {
		t.Fatalf("message not truncated: %d bytes", len(se.Message))
	}
	if msg := err.Error(); strings.Contains(msg, "hidden") || strings.Contains(msg, "apiVersion") {
		t.Fatalf("error leaks raw body: %q", msg)
	}
}

func TestKubeBackendMutationsMapStatusErrors(t *testing.T) {
	tests := []struct {
		status int
		want   error
	}{
		{http.StatusNotFound, api.ErrNotFound},
		{http.StatusBadRequest, api.ErrBadRequest},
		{http.StatusUnprocessableEntity, api.ErrBadRequest},
	}
	for _, tc := range tests {
		ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(tc.status)
			_, _ = w.Write([]byte(`{"kind":"Status","reason":"Nope","message":"nope"}`))
		}))
		b, err := NewKubeBackend(&kubeconfig.ResolvedCluster{Server: ts.URL, ContextName: "test"})
		if err != nil {
			t.Fatalf("new backend: %v", err)
		}
		ctx := context.Background()
		calls := map[string]error{
			"scale":   b.ScaleWorkload(ctx, "test", "deployment:a/web", 2),
			"restart": b.RestartWorkload(ctx, "test", "deployment:a/web"),
			"cordon":  b.CordonNode(ctx, "test", "n1", true),
		}
		for name, err := range calls {
			if !errors.Is(err, tc.want) {
				t.Errorf("%s with %d: err = %v, want %v", name, tc.status, err, tc.want)
			}
			var se *StatusError
			if !errors.As(err, &se) || se.Code != tc.status {
				t.Errorf("%s with %d: StatusError not preserved: %v", name, tc.status, err)
			}
		}
		ts.Close()
	}

	// Other statuses stay unmapped so handlers answer 502.
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "denied", http.StatusForbidden)
	}))
	defer ts.Close()
	b, err := NewKubeBackend(&kubeconfig.ResolvedCluster{Server: ts.URL, ContextName: "test"})
	if err != nil {
		t.Fatalf("new backend: %v", err)
	}
	err = b.CordonNode(context.Background(), "test", "n1", true)
	if err == nil || errors.Is(err, api.ErrNotFound) || errors.Is(err, api.ErrBadRequest) {
		t.Fatalf("403 should stay unmapped, got %v", err)
	}
}

func TestKubeBackendDrainErrorOmitsRawStatusJSON(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPatch:
			_, _ = w.Write([]byte(`{"kind":"Node"}`))
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/pods":
			_ = json.NewEncoder(w).Encode(drainPods())
		case strings.HasSuffix(r.URL.Path, "/eviction"):
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = w.Write([]byte(`{"kind":"Status","apiVersion":"v1","reason":"InternalError","message":"etcd down","details":{"uid":"abc"}}`))
		default:
			http.Error(w, "not routed", http.StatusNotFound)
		}
	}))
	defer ts.Close()

	b := newDrainBackend(t, ts.URL)
	if _, err := b.StartDrain(context.Background(), "test", "worker-1"); err != nil {
		t.Fatalf("StartDrain: %v", err)
	}
	final := waitDrain(t, b, "worker-1", "job-1")
	if final.Phase != api.DrainPhaseFailed {
		t.Fatalf("phase = %q, want failed", final.Phase)
	}
	if !strings.Contains(final.Error, "etcd down") || strings.Contains(final.Error, "apiVersion") || strings.Contains(final.Error, "abc") {
		t.Fatalf("Error should be the short StatusError form, got %q", final.Error)
	}
}

func TestKubeBackendLoadSnapshotRequestsCachedLists(t *testing.T) {
	var mu sync.Mutex
	var queries []string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		queries = append(queries, r.URL.RawQuery)
		mu.Unlock()
		_, _ = w.Write([]byte(`{"items":[]}`))
	}))
	defer ts.Close()

	b, err := NewKubeBackend(&kubeconfig.ResolvedCluster{Server: ts.URL, ContextName: "test"})
	if err != nil {
		t.Fatalf("new backend: %v", err)
	}
	if _, err := b.LoadSnapshot(context.Background(), "test"); err != nil {
		t.Fatalf("LoadSnapshot: %v", err)
	}
	if len(queries) != 8 {
		t.Fatalf("expected 8 LISTs, got %d", len(queries))
	}
	for _, q := range queries {
		if q != "resourceVersion=0" {
			t.Fatalf("query = %q, want resourceVersion=0", q)
		}
	}
}

// selfSignedPEM returns a throwaway self-signed client certificate and key.
func selfSignedPEM(t *testing.T) (certPEM, keyPEM []byte) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "test-client"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatalf("create cert: %v", err)
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatalf("marshal key: %v", err)
	}
	certPEM = pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM = pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})
	return certPEM, keyPEM
}

func TestRestClientPresentsClientCertificate(t *testing.T) {
	certPEM, keyPEM := selfSignedPEM(t)

	var gotCN string
	ts := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if len(r.TLS.PeerCertificates) > 0 {
			gotCN = r.TLS.PeerCertificates[0].Subject.CommonName
		}
		_, _ = w.Write([]byte(`{}`))
	}))
	ts.TLS = &tls.Config{ClientAuth: tls.RequireAnyClientCert}
	ts.StartTLS()
	defer ts.Close()

	client, err := NewRestClient(&kubeconfig.ResolvedCluster{
		Server:          ts.URL,
		InsecureSkipTLS: true,
		ClientCertData:  certPEM,
		ClientKeyData:   keyPEM,
	})
	if err != nil {
		t.Fatalf("new client: %v", err)
	}
	if _, err := client.GetJSON(context.Background(), "/api/v1/nodes", nil); err != nil {
		t.Fatalf("GetJSON: %v", err)
	}
	if gotCN != "test-client" {
		t.Fatalf("server saw client CN %q, want test-client", gotCN)
	}
}

func TestRestClientRejectsBadClientCertificate(t *testing.T) {
	_, err := NewRestClient(&kubeconfig.ResolvedCluster{
		Server:         "https://example.com",
		ClientCertData: []byte("not a cert"),
		ClientKeyData:  []byte("not a key"),
	})
	if err == nil {
		t.Fatalf("expected error for unusable client certificate")
	}
}
