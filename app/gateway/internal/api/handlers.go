package api

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// maxScaleBodyBytes caps the scale request body. Payload is a trivial JSON
// object `{"replicas": N}`; 1 KiB leaves a generous margin for whitespace.
const maxScaleBodyBytes = 1 << 10

// timeNow is the package's clock source, overridable in tests for deterministic
// audit timestamps.
var timeNow = time.Now

const (
	// AuthHeader is the shared-token header clients must set on every
	// request. It matches the value wired into the mobile app.
	AuthHeader = "X-ClusterOrbit-Token"

	// pathRoot is the API version prefix.
	pathRoot = "/v1/clusters"
)

// Server wires a ClusterBackend into an http.Handler. Tokens (if non-empty)
// gate every request via the AuthHeader; any token in the set is accepted so
// rotation is "add new token → roll clients → drop old token". RateLimiter
// (if non-nil) applies per-token, or per-IP if auth is disabled.
type Server struct {
	Backend ClusterBackend
	// Tokens is the set of shared secrets clients may present in AuthHeader.
	// An empty or nil slice disables auth (tests, local-only demos).
	Tokens []string
	// Token is a convenience field equivalent to Tokens=[]string{Token}.
	// Applied only when Tokens is empty. Kept so single-token callers and
	// existing tests don't need to change.
	Token string
	// Limiter, if set, rate-limits each token (or client IP when auth is
	// disabled). Requests that exceed the limit return 429.
	Limiter *RateLimiter
	// AuditSink, if set, records every mutation request (success or failure).
	// Passed as a func so callers can plug in a file, stdout, or a channel
	// without this package depending on io.
	AuditSink func(AuditEntry)
}

// AuditEntry is one row of the mutation log. Captured fields intentionally
// avoid the token value — only a truncated identity marker is logged.
type AuditEntry struct {
	Timestamp  string `json:"timestamp"`
	Identity   string `json:"identity"`
	Method     string `json:"method"`
	Path       string `json:"path"`
	ClusterID  string `json:"clusterId,omitempty"`
	WorkloadID string `json:"workloadId,omitempty"`
	Replicas   *int   `json:"replicas,omitempty"`
	Status     int    `json:"status"`
	Error      string `json:"error,omitempty"`
}

// Handler returns the root http.Handler for the gateway API.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc(pathRoot, s.authMiddleware(s.handleRoot))
	mux.HandleFunc(pathRoot+"/", s.authMiddleware(s.handleClusterScoped))
	return mux
}

func (s *Server) acceptedTokens() []string {
	if len(s.Tokens) > 0 {
		return s.Tokens
	}
	if s.Token != "" {
		return []string{s.Token}
	}
	return nil
}

func (s *Server) authMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		identity := clientIP(r)
		accepted := s.acceptedTokens()
		if len(accepted) > 0 {
			got := r.Header.Get(AuthHeader)
			if got == "" || !tokenAccepted(got, accepted) {
				writeError(w, http.StatusUnauthorized, "missing or invalid token")
				return
			}
			identity = got
		}
		if !s.Limiter.Allow(identity) {
			writeError(w, http.StatusTooManyRequests, "rate limit exceeded")
			return
		}
		next(w, r)
	}
}

// tokenAccepted does a constant-time-ish comparison against each candidate.
// The set is typically 1–3 entries so a linear scan is fine; the compare is
// not crypto-timing-safe because HTTP header handling isn't either — treat
// the shared token as a password, not a session key.
func tokenAccepted(got string, accepted []string) bool {
	for _, t := range accepted {
		if got == t {
			return true
		}
	}
	return false
}

// clientIP best-effort extracts a caller identity. RemoteAddr is host:port;
// we drop the port. X-Forwarded-For is trusted only when set by an explicit
// reverse proxy in front — see docs/handover for deployment guidance.
func clientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		// First IP in the list is the original client per RFC 7239 convention.
		if i := strings.IndexByte(xff, ','); i >= 0 {
			return strings.TrimSpace(xff[:i])
		}
		return strings.TrimSpace(xff)
	}
	addr := r.RemoteAddr
	if i := strings.LastIndexByte(addr, ':'); i >= 0 {
		return addr[:i]
	}
	return addr
}

// handleRoot serves GET /v1/clusters.
func (s *Server) handleRoot(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	clusters, err := s.Backend.ListClusters(r.Context())
	if err != nil {
		writeBackendError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, clusters)
}

// handleClusterScoped dispatches /v1/clusters/{id}/{subpath}.
func (s *Server) handleClusterScoped(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, pathRoot+"/")
	if rest == "" {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	parts := strings.SplitN(rest, "/", 2)
	clusterID := parts[0]
	subpath := ""
	if len(parts) == 2 {
		subpath = parts[1]
	}

	// Mutations (POST) are routed before the GET guard.
	if r.Method == http.MethodPost {
		s.handleMutation(w, r, clusterID, subpath)
		return
	}
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	switch subpath {
	case "snapshot":
		snapshot, err := s.Backend.LoadSnapshot(r.Context(), clusterID)
		if err != nil {
			writeBackendError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, snapshot)
	case "events":
		q := r.URL.Query()
		kind := q.Get("kind")
		objectName := q.Get("objectName")
		namespace := q.Get("namespace")
		limit := 5
		if v := q.Get("limit"); v != "" {
			if parsed, err := strconv.Atoi(v); err == nil && parsed > 0 {
				limit = parsed
			}
		}
		if kind == "" || objectName == "" {
			writeError(w, http.StatusBadRequest, "kind and objectName are required")
			return
		}
		events, err := s.Backend.LoadEvents(r.Context(), clusterID, kind, objectName, namespace, limit)
		if err != nil {
			writeBackendError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, events)
	default:
		writeError(w, http.StatusNotFound, "not found")
	}
}

// handleMutation dispatches POST /v1/clusters/{id}/workloads/{wid}/scale.
// Every attempt — success, bad input, backend failure — is pushed to the
// audit sink so callers can reconstruct who did what, even when nothing
// changed.
func (s *Server) handleMutation(w http.ResponseWriter, r *http.Request, clusterID, subpath string) {
	// workloadID is "{kind}:{namespace}/{name}", which contains a literal
	// "/" — so we can't split the whole subpath by slash. Peel prefix/suffix.
	const prefix = "workloads/"
	const suffix = "/scale"
	if !strings.HasPrefix(subpath, prefix) || !strings.HasSuffix(subpath, suffix) {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	workloadID := strings.TrimSuffix(strings.TrimPrefix(subpath, prefix), suffix)
	if workloadID == "" {
		writeError(w, http.StatusNotFound, "not found")
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, maxScaleBodyBytes)
	var body struct {
		Replicas *int `json:"replicas"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		s.audit(r, clusterID, workloadID, nil, http.StatusBadRequest, "decode body: "+err.Error())
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if body.Replicas == nil || *body.Replicas < 0 {
		s.audit(r, clusterID, workloadID, body.Replicas, http.StatusBadRequest, "replicas must be >=0")
		writeError(w, http.StatusBadRequest, "replicas must be a non-negative integer")
		return
	}

	err := s.Backend.ScaleWorkload(r.Context(), clusterID, workloadID, *body.Replicas)
	status, msg := scaleStatus(err)
	s.audit(r, clusterID, workloadID, body.Replicas, status, msg)
	if err != nil {
		writeBackendError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"clusterId":  clusterID,
		"workloadId": workloadID,
		"replicas":   *body.Replicas,
	})
}

func scaleStatus(err error) (int, string) {
	switch {
	case err == nil:
		return http.StatusOK, ""
	case errors.Is(err, ErrNotFound):
		return http.StatusNotFound, err.Error()
	case errors.Is(err, ErrUnsupported):
		return http.StatusNotImplemented, err.Error()
	case errors.Is(err, ErrBadRequest):
		return http.StatusBadRequest, err.Error()
	default:
		return http.StatusBadGateway, err.Error()
	}
}

func (s *Server) audit(r *http.Request, clusterID, workloadID string, replicas *int, status int, errMsg string) {
	if s.AuditSink == nil {
		return
	}
	identity := clientIP(r)
	if got := r.Header.Get(AuthHeader); got != "" {
		identity = truncateToken(got)
	}
	s.AuditSink(AuditEntry{
		Timestamp:  timeNow().UTC().Format("2006-01-02T15:04:05Z07:00"),
		Identity:   identity,
		Method:     r.Method,
		Path:       r.URL.Path,
		ClusterID:  clusterID,
		WorkloadID: workloadID,
		Replicas:   replicas,
		Status:     status,
		Error:      errMsg,
	})
}

// truncateToken keeps only the first 6 chars of a shared token so audit
// entries don't leak the secret. 6 chars = ~2^36 collision space, enough to
// disambiguate a small token set.
func truncateToken(t string) string {
	const max = 6
	if len(t) <= max {
		return t
	}
	return t[:max] + "…"
}

// writeBackendError translates a ClusterBackend error into an HTTP status.
// Unknown backend errors log server-side but return a generic message so
// kubernetes internals don't leak to clients.
func writeBackendError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, ErrNotFound):
		writeError(w, http.StatusNotFound, "not found")
	case errors.Is(err, ErrBadRequest):
		writeError(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, ErrUnsupported):
		writeError(w, http.StatusNotImplemented, err.Error())
	default:
		log.Printf("gateway: backend error: %v", err)
		writeError(w, http.StatusBadGateway, "backend error")
	}
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}
