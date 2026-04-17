package kubeconfig

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"testing"
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
