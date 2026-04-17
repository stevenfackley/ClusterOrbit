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

// Server wires a ClusterBackend and a required auth token into an http.Handler.
type Server struct {
	Backend ClusterBackend
	// Token is the shared secret clients must present in the AuthHeader.
	// An empty token disables auth and should only be used in tests.
	Token string
}

// Handler returns the root http.Handler for the gateway API.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc(pathRoot, s.authMiddleware(s.handleRoot))
	mux.HandleFunc(pathRoot+"/", s.authMiddleware(s.handleClusterScoped))
	return mux
}

func (s *Server) authMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if s.Token != "" {
			got := r.Header.Get(AuthHeader)
			if got == "" || got != s.Token {
				writeError(w, http.StatusUnauthorized, "missing or invalid token")
				return
			}
		}
		next(w, r)
	}
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
