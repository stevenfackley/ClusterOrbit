package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
)

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
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

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

// writeBackendError translates a ClusterBackend error into an HTTP status.
// ErrNotFound → 404, anything else → 502 (upstream failure).
func writeBackendError(w http.ResponseWriter, err error) {
	if errors.Is(err, ErrNotFound) {
		writeError(w, http.StatusNotFound, "cluster not found")
		return
	}
	writeError(w, http.StatusBadGateway, "backend error: "+err.Error())
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}
