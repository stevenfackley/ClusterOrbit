package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"math"
	"net/http"
	"os"
	"os/signal"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/stevenfackley/clusterorbit/app/gateway/internal/api"
	"github.com/stevenfackley/clusterorbit/app/gateway/internal/kubebackend"
	"github.com/stevenfackley/clusterorbit/app/gateway/internal/kubeconfig"
)

const startupBanner = "ClusterOrbit gateway"

func main() {
	addr := envOrDefault("CLUSTERORBIT_GATEWAY_ADDR", ":8080")
	mode := envOrDefault("CLUSTERORBIT_GATEWAY_MODE", "sample")

	backend, backendLabel := buildBackend(mode)
	tokens := collectTokens(os.Getenv)
	limiter, err := buildLimiter(os.Getenv)
	if err != nil {
		log.Fatalf("gateway: %v", err)
	}
	// Trust X-Forwarded-For only behind a reverse proxy that sets it itself.
	trustProxy, err := envBool(os.Getenv, "CLUSTERORBIT_GATEWAY_TRUST_PROXY")
	if err != nil {
		log.Fatalf("gateway: %v", err)
	}

	policy, policyLabel, err := buildScalePolicy(os.Getenv)
	if err != nil {
		log.Fatalf("gateway: %v", err)
	}
	nodePolicy, nodePolicyLabel, err := buildNodePolicy(os.Getenv)
	if err != nil {
		log.Fatalf("gateway: %v", err)
	}
	approvals, approvalLabel, err := buildApprovalPolicy(os.Getenv, tokens)
	if err != nil {
		log.Fatalf("gateway: %v", err)
	}

	auditSink, auditLabel, auditCloser := buildAuditSink()
	if auditCloser != nil {
		defer auditCloser()
	}

	server := &api.Server{
		Backend:     backend,
		Tokens:      tokens,
		Limiter:     limiter,
		AuditSink:   auditSink,
		ScalePolicy: policy,
		NodePolicy:  nodePolicy,
		Approvals:   approvals,

		TrustForwardedFor: trustProxy,
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

	fmt.Printf("%s listening on %s (auth=%s backend=%s tls=%s rate=%s trustProxy=%s audit=%s policy=%s nodePolicy=%s approval=%s)\n",
		startupBanner, addr, authLabel(tokens), backendLabel, tlsLabel, rateLabel(limiter), trustProxyLabel(trustProxy, tokens),
		auditLabel, policyLabel, nodePolicyLabel, approvalLabel)

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
// CLUSTERORBIT_GATEWAY_TOKENS (comma-separated) and merges them, dropping
// duplicates so the result counts distinct tokens. The list form is how token
// rotation works: add the new token, roll clients, remove the old one. No
// tokens → auth disabled.
func collectTokens(getenv func(string) string) []string {
	var out []string
	candidates := append([]string{strings.TrimSpace(getenv("CLUSTERORBIT_GATEWAY_TOKEN"))},
		splitCSV(getenv("CLUSTERORBIT_GATEWAY_TOKENS"))...)
	for _, t := range candidates {
		if t != "" && !slices.Contains(out, t) {
			out = append(out, t)
		}
	}
	return out
}

// buildScalePolicy assembles a ScalePolicy from env. Returns (nil, "off") when
// nothing is configured so handlers take the no-policy fast path.
//
//	CLUSTERORBIT_GATEWAY_POLICY_MAX_REPLICAS   int, ceiling applied to scale N
//	CLUSTERORBIT_GATEWAY_POLICY_NAMESPACES     comma-separated allowlist
func buildScalePolicy(getenv func(string) string) (*api.ScalePolicy, string, error) {
	max, err := envInt(getenv, "CLUSTERORBIT_GATEWAY_POLICY_MAX_REPLICAS")
	if err != nil {
		return nil, "", err
	}
	namespaces := splitCSV(getenv("CLUSTERORBIT_GATEWAY_POLICY_NAMESPACES"))
	if max == 0 && len(namespaces) == 0 {
		return nil, "off", nil
	}
	var parts []string
	if max > 0 {
		parts = append(parts, fmt.Sprintf("max=%d", max))
	}
	if len(namespaces) > 0 {
		parts = append(parts, fmt.Sprintf("ns=%d", len(namespaces)))
	}
	return &api.ScalePolicy{MaxReplicas: max, AllowedNamespaces: namespaces}, strings.Join(parts, ","), nil
}

// buildNodePolicy assembles a NodePolicy from env. Returns (nil, "off") when
// nothing is configured so node handlers take the no-policy fast path.
//
//	CLUSTERORBIT_GATEWAY_POLICY_NODES            comma-separated node allowlist
//	CLUSTERORBIT_GATEWAY_POLICY_PROTECTED_NODES  comma-separated node denylist
//	CLUSTERORBIT_GATEWAY_POLICY_DISABLE_DRAIN    bool → reject every drain
func buildNodePolicy(getenv func(string) string) (*api.NodePolicy, string, error) {
	allowed := splitCSV(getenv("CLUSTERORBIT_GATEWAY_POLICY_NODES"))
	protected := splitCSV(getenv("CLUSTERORBIT_GATEWAY_POLICY_PROTECTED_NODES"))
	disableDrain, err := envBool(getenv, "CLUSTERORBIT_GATEWAY_POLICY_DISABLE_DRAIN")
	if err != nil {
		return nil, "", err
	}

	if len(allowed) == 0 && len(protected) == 0 && !disableDrain {
		return nil, "off", nil
	}
	var parts []string
	if len(allowed) > 0 {
		parts = append(parts, fmt.Sprintf("allow=%d", len(allowed)))
	}
	if len(protected) > 0 {
		parts = append(parts, fmt.Sprintf("protected=%d", len(protected)))
	}
	if disableDrain {
		parts = append(parts, "drain=off")
	}
	return &api.NodePolicy{
		AllowedNodes:   allowed,
		ProtectedNodes: protected,
		DisableDrain:   disableDrain,
	}, strings.Join(parts, ","), nil
}

// buildApprovalPolicy assembles the approval gate (an ApprovalStore holding the
// gated op-classes) from env. Returns (nil, "off") when no op-classes are gated
// so mutation handlers take the no-approval fast path. Gating any op needs at
// least two distinct tokens: without them no second person can ever approve.
//
//	CLUSTERORBIT_GATEWAY_POLICY_REQUIRE_APPROVAL  comma list of scale,restart,cordon,drain
//	CLUSTERORBIT_GATEWAY_POLICY_APPROVAL_TTL      Go duration, default 15m
func buildApprovalPolicy(getenv func(string) string, tokens []string) (*api.ApprovalStore, string, error) {
	var required []string
	for _, op := range splitCSV(getenv("CLUSTERORBIT_GATEWAY_POLICY_REQUIRE_APPROVAL")) {
		switch op = strings.ToLower(op); op {
		case api.OpScale, api.OpRestart, api.OpCordon, api.OpDrain:
			if !slices.Contains(required, op) {
				required = append(required, op)
			}
		default:
			return nil, "", fmt.Errorf("CLUSTERORBIT_GATEWAY_POLICY_REQUIRE_APPROVAL: unknown op %q (want scale, restart, cordon or drain)", op)
		}
	}
	if len(required) == 0 {
		return nil, "off", nil
	}
	if len(tokens) < 2 {
		return nil, "", fmt.Errorf("CLUSTERORBIT_GATEWAY_POLICY_REQUIRE_APPROVAL needs >=2 distinct tokens (CLUSTERORBIT_GATEWAY_TOKEN/_TOKENS), have %d", len(tokens))
	}
	ttl := 15 * time.Minute
	if raw := strings.TrimSpace(getenv("CLUSTERORBIT_GATEWAY_POLICY_APPROVAL_TTL")); raw != "" {
		d, err := time.ParseDuration(raw)
		if err != nil || d <= 0 {
			return nil, "", fmt.Errorf("CLUSTERORBIT_GATEWAY_POLICY_APPROVAL_TTL=%q: want a positive Go duration", raw)
		}
		ttl = d
	}
	return api.NewApprovalStore(ttl, required...), fmt.Sprintf("ops=%d ttl=%s", len(required), ttl), nil
}

// buildLimiter reads CLUSTERORBIT_GATEWAY_RATE_LIMIT_RPS and _BURST. Both unset
// (or 0) disables rate limiting; setting only one is an error, because the
// limiter needs both and would otherwise be silently off.
func buildLimiter(getenv func(string) string) (*api.RateLimiter, error) {
	rps, err := envFloat(getenv, "CLUSTERORBIT_GATEWAY_RATE_LIMIT_RPS")
	if err != nil {
		return nil, err
	}
	burst, err := envFloat(getenv, "CLUSTERORBIT_GATEWAY_RATE_LIMIT_BURST")
	if err != nil {
		return nil, err
	}
	if (rps > 0) != (burst > 0) {
		return nil, errors.New("CLUSTERORBIT_GATEWAY_RATE_LIMIT_RPS and _BURST must both be set to enable rate limiting")
	}
	return api.NewRateLimiter(rps, burst), nil
}

// splitCSV parses a comma-separated env value into a trimmed, non-empty slice.
func splitCSV(raw string) []string {
	var out []string
	for _, v := range strings.Split(raw, ",") {
		if v = strings.TrimSpace(v); v != "" {
			out = append(out, v)
		}
	}
	return out
}

// envInt parses key as a non-negative integer; unset or blank is 0. A value
// that is set but invalid is an error, never a silently disabled control.
func envInt(getenv func(string) string, key string) (int, error) {
	raw := strings.TrimSpace(getenv(key))
	if raw == "" {
		return 0, nil
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n < 0 {
		return 0, fmt.Errorf("%s=%q: want a non-negative integer", key, raw)
	}
	return n, nil
}

// envFloat parses key as a non-negative finite number; unset or blank is 0.
func envFloat(getenv func(string) string, key string) (float64, error) {
	raw := strings.TrimSpace(getenv(key))
	if raw == "" {
		return 0, nil
	}
	f, err := strconv.ParseFloat(raw, 64)
	if err != nil || f < 0 || math.IsInf(f, 0) || math.IsNaN(f) {
		return 0, fmt.Errorf("%s=%q: want a non-negative number", key, raw)
	}
	return f, nil
}

// envBool parses key with the usual on/off spellings (case-insensitive); unset
// or blank is false. Anything else is an error, so a typo can't silently leave
// a switch like DISABLE_DRAIN off.
func envBool(getenv func(string) string, key string) (bool, error) {
	switch raw := strings.ToLower(strings.TrimSpace(getenv(key))); raw {
	case "1", "true", "yes", "on":
		return true, nil
	case "", "0", "false", "no", "off":
		return false, nil
	default:
		return false, fmt.Errorf("%s=%q: want true or false", key, raw)
	}
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

// trustProxyLabel reports CLUSTERORBIT_GATEWAY_TRUST_PROXY. The forwarded
// client IP only matters with auth off, where it is the caller identity; with
// tokens the identity is the token, so the setting has no effect.
func trustProxyLabel(trust bool, tokens []string) string {
	switch {
	case !trust:
		return "off"
	case len(tokens) > 0:
		return "on (unused with token auth)"
	default:
		return "on"
	}
}

func envOrDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
