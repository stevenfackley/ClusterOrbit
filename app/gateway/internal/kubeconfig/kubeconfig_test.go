package kubeconfig

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/pem"
	"math/big"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// caProdBase64 is base64("CA-PROD"). Precomputed so the fixture is a const.
const caProdBase64 = "Q0EtUFJPRA=="

const fixture = `
apiVersion: v1
kind: Config
current-context: prod-admin
clusters:
  - name: prod-cluster
    cluster:
      server: https://prod.example.internal:6443
      certificate-authority-data: ` + caProdBase64 + `
  - name: dev-cluster
    cluster:
      server: https://dev.example.internal:6443
      insecure-skip-tls-verify: true
contexts:
  - name: prod-admin
    context:
      cluster: prod-cluster
      user: prod-user
      namespace: kube-system
  - name: dev
    context:
      cluster: dev-cluster
      user: dev-user
users:
  - name: prod-user
    user:
      token: prod-token
  - name: dev-user
    user:
      token: ""
`

func init() {
	// Guard against the hand-computed constant drifting from reality.
	if got := base64.StdEncoding.EncodeToString([]byte("CA-PROD")); got != caProdBase64 {
		panic("caProdBase64 drifted: update constant to " + got)
	}
}

func TestParseAndResolveCurrentContext(t *testing.T) {
	doc, err := ParseDocument([]byte(fixture))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if doc.CurrentContext != "prod-admin" {
		t.Fatalf("current-context = %q, want prod-admin", doc.CurrentContext)
	}
	if len(doc.Contexts) != 2 || len(doc.Clusters) != 2 || len(doc.Users) != 2 {
		t.Fatalf("parsed counts wrong: %d ctx / %d cluster / %d user",
			len(doc.Contexts), len(doc.Clusters), len(doc.Users))
	}

	resolved, err := Resolve(doc, "")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if resolved.ContextName != "prod-admin" {
		t.Fatalf("context = %q, want prod-admin", resolved.ContextName)
	}
	if resolved.Server != "https://prod.example.internal:6443" {
		t.Fatalf("server = %q", resolved.Server)
	}
	if resolved.Namespace != "kube-system" {
		t.Fatalf("namespace = %q", resolved.Namespace)
	}
	if resolved.BearerToken != "prod-token" {
		t.Fatalf("bearer token = %q", resolved.BearerToken)
	}
	if string(resolved.CAData) != "CA-PROD" {
		t.Fatalf("CA data = %q", resolved.CAData)
	}
	if resolved.InsecureSkipTLS {
		t.Fatalf("insecure-skip-tls-verify should be false")
	}
	if resolved.APIServerHost() != "prod.example.internal" {
		t.Fatalf("api server host = %q", resolved.APIServerHost())
	}
	if resolved.EnvironmentLabel != "Production" {
		t.Fatalf("env label = %q", resolved.EnvironmentLabel)
	}
}

func TestResolveSpecificContext(t *testing.T) {
	doc, err := ParseDocument([]byte(fixture))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	resolved, err := Resolve(doc, "dev")
	if err != nil {
		t.Fatalf("resolve dev: %v", err)
	}
	if !resolved.InsecureSkipTLS {
		t.Fatalf("dev cluster should have insecure-skip-tls-verify true")
	}
	if resolved.BearerToken != "" {
		t.Fatalf("dev user token should be empty, got %q", resolved.BearerToken)
	}
	if resolved.EnvironmentLabel != "Development" {
		t.Fatalf("env label = %q", resolved.EnvironmentLabel)
	}
}

func TestResolveUnknownContext(t *testing.T) {
	doc, err := ParseDocument([]byte(fixture))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if _, err := Resolve(doc, "nope"); err == nil {
		t.Fatalf("expected error for unknown context")
	}
}

func TestResolveTokenFile(t *testing.T) {
	tmp := t.TempDir()
	tokenPath := filepath.Join(tmp, "token")
	if err := os.WriteFile(tokenPath, []byte("  file-token  \n"), 0o600); err != nil {
		t.Fatalf("write token: %v", err)
	}

	yaml := "apiVersion: v1\ncurrent-context: ctx\n" +
		"clusters:\n  - name: c\n    cluster:\n      server: https://example\n" +
		"contexts:\n  - name: ctx\n    context:\n      cluster: c\n      user: u\n" +
		"users:\n  - name: u\n    user:\n      tokenFile: " + tokenPath + "\n"

	doc, err := ParseDocument([]byte(yaml))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	resolved, err := Resolve(doc, "")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if resolved.BearerToken != "file-token" {
		t.Fatalf("token = %q, want file-token (trimmed)", resolved.BearerToken)
	}
}

func TestLoadFile(t *testing.T) {
	tmp := t.TempDir()
	path := filepath.Join(tmp, "kubeconfig.yaml")
	if err := os.WriteFile(path, []byte(fixture), 0o600); err != nil {
		t.Fatalf("write kubeconfig: %v", err)
	}
	doc, err := LoadFile(path)
	if err != nil {
		t.Fatalf("load file: %v", err)
	}
	if doc.CurrentContext != "prod-admin" {
		t.Fatalf("current-context = %q", doc.CurrentContext)
	}
}

func TestResolvePathPrefersOverride(t *testing.T) {
	env := map[string]string{
		EnvVarKubeconfig: "/tmp/override",
		"KUBECONFIG":     "/tmp/standard",
		"HOME":           "/home/bob",
	}
	got := ResolvePath(func(k string) string { return env[k] })
	if got != "/tmp/override" {
		t.Fatalf("path = %q", got)
	}
}

func TestResolvePathFallsBackToKubeconfigThenHome(t *testing.T) {
	env := map[string]string{
		"KUBECONFIG": "/tmp/standard",
		"HOME":       "/home/bob",
	}
	if got := ResolvePath(func(k string) string { return env[k] }); got != "/tmp/standard" {
		t.Fatalf("expected KUBECONFIG, got %q", got)
	}

	homeOnly := map[string]string{"HOME": "/home/bob"}
	want := filepath.Join("/home/bob", ".kube", "config")
	if got := ResolvePath(func(k string) string { return homeOnly[k] }); got != want {
		t.Fatalf("path = %q, want %q", got, want)
	}
}

// selfSignedPEM returns a throwaway self-signed certificate and its key.
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

func userKubeconfig(userYAML string) string {
	return "apiVersion: v1\ncurrent-context: ctx\n" +
		"clusters:\n  - name: c\n    cluster:\n      server: https://example\n" +
		"contexts:\n  - name: ctx\n    context:\n      cluster: c\n      user: u\n" +
		"users:\n  - name: u\n    user:\n" + userYAML
}

func TestResolveClientCertData(t *testing.T) {
	certPEM, keyPEM := selfSignedPEM(t)
	yaml := userKubeconfig(
		"      client-certificate-data: " + base64.StdEncoding.EncodeToString(certPEM) + "\n" +
			"      client-key-data: " + base64.StdEncoding.EncodeToString(keyPEM) + "\n")
	doc, err := ParseDocument([]byte(yaml))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	resolved, err := Resolve(doc, "")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if !bytes.Equal(resolved.ClientCertData, certPEM) || !bytes.Equal(resolved.ClientKeyData, keyPEM) {
		t.Fatalf("client cert/key not carried through")
	}
}

func TestResolveRelativePathsAgainstKubeconfigDir(t *testing.T) {
	certPEM, keyPEM := selfSignedPEM(t)
	dir := t.TempDir()
	sub := filepath.Join(dir, "creds")
	if err := os.Mkdir(sub, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	files := map[string][]byte{
		"ca.crt":     []byte("CA-FILE"),
		"client.crt": certPEM,
		"client.key": keyPEM,
		"token":      []byte("rel-token\n"),
	}
	for name, data := range files {
		if err := os.WriteFile(filepath.Join(sub, name), data, 0o600); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}

	yaml := "apiVersion: v1\ncurrent-context: ctx\n" +
		"clusters:\n  - name: c\n    cluster:\n      server: https://example\n      certificate-authority: creds/ca.crt\n" +
		"contexts:\n  - name: ctx\n    context:\n      cluster: c\n      user: u\n" +
		"users:\n  - name: u\n    user:\n      client-certificate: creds/client.crt\n" +
		"      client-key: creds/client.key\n      tokenFile: creds/token\n"
	path := filepath.Join(dir, "config")
	if err := os.WriteFile(path, []byte(yaml), 0o600); err != nil {
		t.Fatalf("write kubeconfig: %v", err)
	}

	doc, err := LoadFile(path)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	resolved, err := Resolve(doc, "")
	if err != nil {
		t.Fatalf("resolve (cwd is not the kubeconfig dir): %v", err)
	}
	if string(resolved.CAData) != "CA-FILE" || resolved.BearerToken != "rel-token" {
		t.Fatalf("CA = %q, token = %q", resolved.CAData, resolved.BearerToken)
	}
	if !bytes.Equal(resolved.ClientCertData, certPEM) || !bytes.Equal(resolved.ClientKeyData, keyPEM) {
		t.Fatalf("client cert/key files not read relative to kubeconfig dir")
	}
}

func TestResolveRejectsUnauthenticatableUsers(t *testing.T) {
	certPEM, _ := selfSignedPEM(t)
	tests := []struct {
		name string
		yaml string
	}{
		{"missing user", "apiVersion: v1\ncurrent-context: ctx\n" +
			"clusters:\n  - name: c\n    cluster:\n      server: https://example\n" +
			"contexts:\n  - name: ctx\n    context:\n      cluster: c\n      user: ghost\n"},
		{"exec only", userKubeconfig("      exec:\n        command: aws\n")},
		{"auth-provider only", userKubeconfig("      auth-provider:\n        name: gcp\n")},
		{"cert without key", userKubeconfig(
			"      client-certificate-data: " + base64.StdEncoding.EncodeToString(certPEM) + "\n")},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			doc, err := ParseDocument([]byte(tc.yaml))
			if err != nil {
				t.Fatalf("parse: %v", err)
			}
			if _, err := Resolve(doc, ""); err == nil {
				t.Fatalf("expected error")
			}
			if resolved, errs := ResolveAll(doc); len(resolved) != 0 || len(errs) != 1 {
				t.Fatalf("ResolveAll = %v, %v; want it skipped with one error", resolved, errs)
			}
		})
	}
}

func TestResolveAllSkipsEmptyContextName(t *testing.T) {
	yaml := "apiVersion: v1\ncurrent-context: ctx\n" +
		"clusters:\n  - name: c\n    cluster:\n      server: https://example\n" +
		"contexts:\n  - name: ctx\n    context:\n      cluster: c\n      user: u\n" +
		"  - context:\n      cluster: c\n      user: u\n" +
		"users:\n  - name: u\n    user:\n      token: t\n"
	doc, err := ParseDocument([]byte(yaml))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	resolved, errs := ResolveAll(doc)
	if len(resolved) != 1 || resolved[0].ContextName != "ctx" {
		t.Fatalf("resolved = %v, want only ctx", resolved)
	}
	if len(errs) != 1 {
		t.Fatalf("errs = %v, want one skip error", errs)
	}
}
