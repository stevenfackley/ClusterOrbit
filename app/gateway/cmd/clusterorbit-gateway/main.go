package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/stevenfackley/clusterorbit/app/gateway/internal/api"
	"github.com/stevenfackley/clusterorbit/app/gateway/internal/kubebackend"
	"github.com/stevenfackley/clusterorbit/app/gateway/internal/kubeconfig"
)

const scaffoldMessage = "ClusterOrbit gateway scaffold"

// message is retained for the pre-existing smoke test; the real binary now
// starts an HTTP server. See internal/api for request handling.
func message() string {
	return scaffoldMessage
}

func main() {
	addr := envOrDefault("CLUSTERORBIT_GATEWAY_ADDR", ":8080")
	mode := envOrDefault("CLUSTERORBIT_GATEWAY_MODE", "sample")

	backend, backendLabel := buildBackend(mode)
	tokens := collectTokens()
	limiter := buildLimiter()

	auditSink, auditLabel, auditCloser := buildAuditSink()
	if auditCloser != nil {
		defer auditCloser()
	}

	server := &api.Server{
		Backend:   backend,
		Tokens:    tokens,
		Limiter:   limiter,
		AuditSink: auditSink,
	}

	tlsCfg, tlsLabel, err := buildTLS()
	if err != nil {
		log.Fatalf("gateway: TLS setup: %v", err)
	}

	httpServer := &http.Server{
		Addr:              addr,
		Handler:           server.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       120 * time.Second,
		TLSConfig:         tlsCfg,
	}

	fmt.Printf("%s listening on %s (auth=%s backend=%s tls=%s rate=%s audit=%s)\n",
		scaffoldMessage, addr, authLabel(tokens), backendLabel, tlsLabel, rateLabel(limiter), auditLabel)

	// Serve in a goroutine; main goroutine waits for SIGTERM/SIGINT then
	// triggers a graceful shutdown so in-flight requests and the audit
	// writer get to finish.
	serveErr := make(chan error, 1)
	go func() {
		if tlsCfg != nil {
			// ListenAndServeTLS with empty cert/key uses the config's certificates.
			serveErr <- httpServer.ListenAndServeTLS("", "")
			return
		}
		serveErr <- httpServer.ListenAndServe()
	}()

	sigCtx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	select {
	case err := <-serveErr:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
	case <-sigCtx.Done():
		log.Printf("gateway: signal received, shutting down")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		if err := httpServer.Shutdown(shutdownCtx); err != nil {
			log.Printf("gateway: graceful shutdown failed: %v", err)
		}
	}
}

// buildBackend resolves the backend the gateway should serve.
//
// Mode "kube" reads the kubeconfig referenced by CLUSTERORBIT_GATEWAY_KUBECONFIG
// / KUBECONFIG. If CLUSTERORBIT_GATEWAY_KUBE_CONTEXT is set, it pins to that
// single context. Otherwise every context in the document that resolves
// successfully becomes a cluster in a MultiClusterBackend, so one gateway
// serves many clusters. Any resolution failure falls back to sample data.
func buildBackend(mode string) (api.ClusterBackend, string) {
	if mode != "kube" {
		return api.NewSampleBackend(), "sample"
	}

	path := kubeconfig.ResolvePath(os.Getenv)
	if path == "" {
		log.Printf("gateway: mode=kube but no kubeconfig path resolvable; falling back to sample data")
		return api.NewSampleBackend(), "sample (kube fallback: no kubeconfig path)"
	}
	doc, err := kubeconfig.LoadFile(path)
	if err != nil {
		log.Printf("gateway: load kubeconfig %q: %v; falling back to sample data", path, err)
		return api.NewSampleBackend(), "sample (kube fallback: load failed)"
	}

	if ctxName := strings.TrimSpace(os.Getenv(kubeconfig.EnvVarContext)); ctxName != "" {
		cluster, err := kubeconfig.Resolve(doc, ctxName)
		if err != nil {
			log.Printf("gateway: resolve kubeconfig context %q: %v; falling back to sample data", ctxName, err)
			return api.NewSampleBackend(), "sample (kube fallback: resolve failed)"
		}
		backend, err := kubebackend.NewKubeBackend(cluster)
		if err != nil {
			log.Printf("gateway: build kube backend: %v; falling back to sample data", err)
			return api.NewSampleBackend(), "sample (kube fallback: client init failed)"
		}
		return backend, fmt.Sprintf("kube (%s @ %s)", cluster.ContextName, cluster.APIServerHost())
	}

	clusters, resolveErrs := kubeconfig.ResolveAll(doc)
	for _, e := range resolveErrs {
		log.Printf("gateway: skipping kubeconfig context: %v", e)
	}
	if len(clusters) == 0 {
		log.Printf("gateway: no resolvable kubeconfig contexts; falling back to sample data")
		return api.NewSampleBackend(), "sample (kube fallback: no contexts)"
	}
	mb, initErrs := kubebackend.NewMultiClusterBackend(clusters)
	for _, e := range initErrs {
		log.Printf("gateway: skipping kube backend init: %v", e)
	}
	if mb.Len() == 0 {
		log.Printf("gateway: all kube backends failed init; falling back to sample data")
		return api.NewSampleBackend(), "sample (kube fallback: all inits failed)"
	}
	return mb, fmt.Sprintf("kube-multi (%d clusters)", mb.Len())
}

// collectTokens reads both CLUSTERORBIT_GATEWAY_TOKEN (single) and
// CLUSTERORBIT_GATEWAY_TOKENS (comma-separated) and merges them. The list form
// is how token rotation works: add the new token, roll clients, remove the
// old one. No tokens → auth disabled.
func collectTokens() []string {
	var out []string
	if v := strings.TrimSpace(os.Getenv("CLUSTERORBIT_GATEWAY_TOKEN")); v != "" {
		out = append(out, v)
	}
	if v := os.Getenv("CLUSTERORBIT_GATEWAY_TOKENS"); v != "" {
		for _, t := range strings.Split(v, ",") {
			t = strings.TrimSpace(t)
			if t != "" {
				out = append(out, t)
			}
		}
	}
	return out
}

func buildLimiter() *api.RateLimiter {
	rps, _ := strconv.ParseFloat(os.Getenv("CLUSTERORBIT_GATEWAY_RATE_LIMIT_RPS"), 64)
	burst, _ := strconv.ParseFloat(os.Getenv("CLUSTERORBIT_GATEWAY_RATE_LIMIT_BURST"), 64)
	return api.NewRateLimiter(rps, burst)
}

// buildTLS returns a *tls.Config if cert+key are provided. If CLIENT_CA is
// also set, require and verify client certs (mTLS). Returns (nil, "off", nil)
// when plain HTTP is intended.
func buildTLS() (*tls.Config, string, error) {
	certFile := os.Getenv("CLUSTERORBIT_GATEWAY_TLS_CERT")
	keyFile := os.Getenv("CLUSTERORBIT_GATEWAY_TLS_KEY")
	if certFile == "" && keyFile == "" {
		return nil, "off", nil
	}
	if certFile == "" || keyFile == "" {
		return nil, "", fmt.Errorf("both CLUSTERORBIT_GATEWAY_TLS_CERT and _KEY must be set")
	}
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return nil, "", fmt.Errorf("load server keypair: %w", err)
	}
	cfg := &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS12,
	}
	label := "tls"

	if clientCA := os.Getenv("CLUSTERORBIT_GATEWAY_CLIENT_CA"); clientCA != "" {
		caBytes, err := os.ReadFile(clientCA)
		if err != nil {
			return nil, "", fmt.Errorf("read client CA: %w", err)
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(caBytes) {
			return nil, "", fmt.Errorf("client CA %q did not parse as PEM", clientCA)
		}
		cfg.ClientAuth = tls.RequireAndVerifyClientCert
		cfg.ClientCAs = pool
		label = "mtls"
	}
	return cfg, label, nil
}

// buildAuditSink returns an AuditSink plus a human-readable label and an
// optional closer. CLUSTERORBIT_GATEWAY_AUDIT_LOG=path appends JSON lines to
// that file; unset → stdout; value "off" disables audit entirely.
func buildAuditSink() (func(api.AuditEntry), string, func()) {
	dest := strings.TrimSpace(os.Getenv("CLUSTERORBIT_GATEWAY_AUDIT_LOG"))
	if dest == "off" {
		return nil, "off", nil
	}
	if dest == "" {
		return jsonSink(os.Stdout), "stdout", nil
	}
	f, err := os.OpenFile(dest, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		log.Printf("gateway: open audit log %q: %v; falling back to stdout", dest, err)
		return jsonSink(os.Stdout), "stdout (file open failed)", nil
	}
	return jsonSink(f), "file:" + dest, func() { _ = f.Close() }
}

// jsonSink serialises entries as JSON Lines. A single mutex serialises the
// writes so concurrent mutations don't interleave their log rows.
func jsonSink(w interface {
	Write(p []byte) (n int, err error)
}) func(api.AuditEntry) {
	var mu sync.Mutex
	enc := json.NewEncoder(w)
	return func(e api.AuditEntry) {
		mu.Lock()
		defer mu.Unlock()
		_ = enc.Encode(e)
	}
}

func authLabel(tokens []string) string {
	switch len(tokens) {
	case 0:
		return "none"
	case 1:
		return "single-token"
	default:
		return fmt.Sprintf("%d-tokens", len(tokens))
	}
}

func rateLabel(rl *api.RateLimiter) string {
	if rl == nil {
		return "off"
	}
	return "on"
}

func envOrDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
