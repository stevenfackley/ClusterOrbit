package api

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"runtime/debug"
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
	// ScalePolicy, if set, gates POST /workloads/{id}/scale before the
	// backend is called. Violations return 403 and are audited.
	ScalePolicy *ScalePolicy
	// NodePolicy, if set, gates node mutations (cordon, drain) before the
	// backend is called. Violations return 403 and are audited. nil skips the
	// check. Uncordon is never gated (recovery action).
	NodePolicy *NodePolicy
	// ApprovalPolicy, if set, parks mutations whose op-class requires a
	// second-person approval instead of executing them inline. When non-nil,
	// Approvals MUST also be non-nil (main wires the two together).
	ApprovalPolicy *ApprovalPolicy
	// Approvals is the pending-request registry for the approval flow.
	Approvals *ApprovalStore
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
	ApprovalID string `json:"approvalId,omitempty"`
}

// Handler returns the root http.Handler for the gateway API.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc(pathRoot, s.authMiddleware(s.handleRoot))
	mux.HandleFunc(pathRoot+"/", s.authMiddleware(s.handleClusterScoped))
	return recoverMiddleware(mux)
}

// recoverMiddleware turns a panic in any downstream handler into a 500
// instead of crashing the process. Stack trace is logged server-side; the
// client gets an opaque error.
func recoverMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if rv := recover(); rv != nil {
				log.Printf("gateway: panic serving %s %s: %v\n%s", r.Method, r.URL.Path, rv, debug.Stack())
				// If the handler already started writing we can't send a
				// clean 500 — let the server close the connection.
				writeError(w, http.StatusInternalServerError, "internal error")
			}
		}()
		next.ServeHTTP(w, r)
	})
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

	// GET .../nodes/{nodeID}/drain/{jobID} — drain job status poll. Node names
	// can't contain "/", so splitting on "/drain/" cleanly separates the node
	// from the job ID.
	if rest := strings.TrimPrefix(subpath, "nodes/"); rest != subpath {
		if idx := strings.Index(rest, "/drain/"); idx >= 0 {
			nodeID := rest[:idx]
			jobID := rest[idx+len("/drain/"):]
			s.handleDrainStatus(w, r, clusterID, nodeID, jobID)
			return
		}
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

// handleMutation routes POST /v1/clusters/{id}/{resource}/{target}/{action}.
// Resource IDs (workload "{kind}:{namespace}/{name}", node name) can contain a
// literal "/", so we peel the resource prefix and the trailing action verb
// rather than splitting the whole subpath by slash. Every attempt is audited
// downstream.
func (s *Server) handleMutation(w http.ResponseWriter, r *http.Request, clusterID, subpath string) {
	switch {
	case strings.HasPrefix(subpath, "workloads/"):
		s.handleWorkloadMutation(w, r, clusterID, strings.TrimPrefix(subpath, "workloads/"))
	case strings.HasPrefix(subpath, "nodes/"):
		s.handleNodeMutation(w, r, clusterID, strings.TrimPrefix(subpath, "nodes/"))
	default:
		writeError(w, http.StatusNotFound, "not found")
	}
}

// handleWorkloadMutation dispatches the action verb for /workloads/{wid}/{verb}.
func (s *Server) handleWorkloadMutation(w http.ResponseWriter, r *http.Request, clusterID, rest string) {
	switch {
	case strings.HasSuffix(rest, "/scale"):
		s.handleScale(w, r, clusterID, strings.TrimSuffix(rest, "/scale"))
	case strings.HasSuffix(rest, "/restart"):
		s.handleRestart(w, r, clusterID, strings.TrimSuffix(rest, "/restart"))
	default:
		writeError(w, http.StatusNotFound, "not found")
	}
}

// handleNodeMutation dispatches /nodes/{nodeID}/{cordon|uncordon|drain}. Node
// ops are not namespaced, so ScalePolicy does not apply; NodePolicy gates them
// instead (checked inside the individual handlers).
func (s *Server) handleNodeMutation(w http.ResponseWriter, r *http.Request, clusterID, rest string) {
	switch {
	case strings.HasSuffix(rest, "/cordon"):
		s.handleCordon(w, r, clusterID, strings.TrimSuffix(rest, "/cordon"), true)
	case strings.HasSuffix(rest, "/uncordon"):
		s.handleCordon(w, r, clusterID, strings.TrimSuffix(rest, "/uncordon"), false)
	case strings.HasSuffix(rest, "/drain"):
		s.handleStartDrain(w, r, clusterID, strings.TrimSuffix(rest, "/drain"))
	default:
		writeError(w, http.StatusNotFound, "not found")
	}
}

// handleStartDrain serves POST .../nodes/{nodeID}/drain. No body — drain has no
// parameters. Returns 202 Accepted with the job handle (including its ID) so
// the client can poll GET .../drain/{jobID}. Gated by NodePolicy.EvaluateDrain
// (node lists + the DisableDrain kill switch).
func (s *Server) handleStartDrain(w http.ResponseWriter, r *http.Request, clusterID, nodeID string) {
	if nodeID == "" {
		writeError(w, http.StatusNotFound, "not found")
		return
	}

	if reason := s.NodePolicy.EvaluateDrain(nodeID); reason != "" {
		s.audit(r, clusterID, nodeID, nil, http.StatusForbidden, "policy: "+reason)
		writeError(w, http.StatusForbidden, "policy violation: "+reason)
		return
	}

	if s.ApprovalPolicy.Requires(OpDrain) {
		pr := s.Approvals.Park(OpDrain, clusterID, nodeID, nil, requestIdentity(r))
		s.auditApproval(r, pr, http.StatusAccepted, "")
		writeJSON(w, http.StatusAccepted, pr)
		return
	}

	job, err := s.Backend.StartDrain(r.Context(), clusterID, nodeID)
	status := http.StatusAccepted
	msg := ""
	if err != nil {
		status, msg = scaleStatus(err)
	}
	s.audit(r, clusterID, nodeID, nil, status, msg)
	if err != nil {
		writeBackendError(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, job)
}

// handleDrainStatus serves GET .../nodes/{nodeID}/drain/{jobID}. Read-only, so
// it is not audited (consistent with snapshot/events GETs).
func (s *Server) handleDrainStatus(w http.ResponseWriter, r *http.Request, clusterID, nodeID, jobID string) {
	if nodeID == "" || jobID == "" {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	job, err := s.Backend.DrainStatus(r.Context(), clusterID, nodeID, jobID)
	if err != nil {
		writeBackendError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, job)
}

// handleCordon serves POST .../nodes/{nodeID}/cordon and /uncordon. No request
// body — toggling schedulability has no parameters. The node ID is carried in
// the audit WorkloadID slot (the mutation target); the Path field disambiguates
// node ops from workload ops for anyone parsing the audit log.
func (s *Server) handleCordon(w http.ResponseWriter, r *http.Request, clusterID, nodeID string, unschedulable bool) {
	if nodeID == "" {
		writeError(w, http.StatusNotFound, "not found")
		return
	}

	if reason := s.NodePolicy.EvaluateCordon(nodeID, unschedulable); reason != "" {
		s.audit(r, clusterID, nodeID, nil, http.StatusForbidden, "policy: "+reason)
		writeError(w, http.StatusForbidden, "policy violation: "+reason)
		return
	}

	if unschedulable && s.ApprovalPolicy.Requires(OpCordon) {
		pr := s.Approvals.Park(OpCordon, clusterID, nodeID, nil, requestIdentity(r))
		s.auditApproval(r, pr, http.StatusAccepted, "")
		writeJSON(w, http.StatusAccepted, pr)
		return
	}

	err := s.Backend.CordonNode(r.Context(), clusterID, nodeID, unschedulable)
	status, msg := scaleStatus(err)
	s.audit(r, clusterID, nodeID, nil, status, msg)
	if err != nil {
		writeBackendError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"clusterId":   clusterID,
		"nodeId":      nodeID,
		"schedulable": !unschedulable,
	})
}

// handleScale serves POST .../workloads/{wid}/scale with a {"replicas": N} body.
func (s *Server) handleScale(w http.ResponseWriter, r *http.Request, clusterID, workloadID string) {
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

	if reason := s.ScalePolicy.Evaluate(workloadID, *body.Replicas); reason != "" {
		s.audit(r, clusterID, workloadID, body.Replicas, http.StatusForbidden, "policy: "+reason)
		writeError(w, http.StatusForbidden, "policy violation: "+reason)
		return
	}

	if s.ApprovalPolicy.Requires(OpScale) {
		pr := s.Approvals.Park(OpScale, clusterID, workloadID, body.Replicas, requestIdentity(r))
		s.auditApproval(r, pr, http.StatusAccepted, "")
		writeJSON(w, http.StatusAccepted, pr)
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

// handleRestart serves POST .../workloads/{wid}/restart. No request body —
// a rolling restart has no parameters. The namespace allowlist still applies
// (via EvaluateNamespace), but the replica ceiling does not, so we don't run
// the full ScalePolicy.Evaluate here.
func (s *Server) handleRestart(w http.ResponseWriter, r *http.Request, clusterID, workloadID string) {
	if workloadID == "" {
		writeError(w, http.StatusNotFound, "not found")
		return
	}

	if reason := s.ScalePolicy.EvaluateNamespace(workloadID); reason != "" {
		s.audit(r, clusterID, workloadID, nil, http.StatusForbidden, "policy: "+reason)
		writeError(w, http.StatusForbidden, "policy violation: "+reason)
		return
	}

	if s.ApprovalPolicy.Requires(OpRestart) {
		pr := s.Approvals.Park(OpRestart, clusterID, workloadID, nil, requestIdentity(r))
		s.auditApproval(r, pr, http.StatusAccepted, "")
		writeJSON(w, http.StatusAccepted, pr)
		return
	}

	err := s.Backend.RestartWorkload(r.Context(), clusterID, workloadID)
	status, msg := scaleStatus(err)
	s.audit(r, clusterID, workloadID, nil, status, msg)
	if err != nil {
		writeBackendError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"clusterId":  clusterID,
		"workloadId": workloadID,
		"restarted":  true,
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
	identity := requestIdentity(r)
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

// requestIdentity returns the caller identity used in audit records and as the
// requester/approver marker on pending approvals: the truncated shared token
// when auth is on, else the client IP.
func requestIdentity(r *http.Request) string {
	if got := r.Header.Get(AuthHeader); got != "" {
		return truncateToken(got)
	}
	return clientIP(r)
}

// executePending runs the backend mutation captured by an approved request and
// returns the async result id (drain only) and an error message ("" on success).
func (s *Server) executePending(ctx context.Context, req PendingRequest) (resultID, errMsg string) {
	var err error
	switch req.Op {
	case OpScale:
		replicas := 0
		if req.Replicas != nil {
			replicas = *req.Replicas
		}
		err = s.Backend.ScaleWorkload(ctx, req.ClusterID, req.TargetID, replicas)
	case OpRestart:
		err = s.Backend.RestartWorkload(ctx, req.ClusterID, req.TargetID)
	case OpCordon:
		err = s.Backend.CordonNode(ctx, req.ClusterID, req.TargetID, true)
	case OpDrain:
		var job DrainJob
		job, err = s.Backend.StartDrain(ctx, req.ClusterID, req.TargetID)
		if err == nil {
			resultID = job.ID
		}
	default:
		err = ErrBadRequest
	}
	if err != nil {
		return "", err.Error()
	}
	return resultID, ""
}

// auditApproval records an approval-flow event (park, approve, reject, or
// execute result). ApprovalID threads one request park → approve → execute.
func (s *Server) auditApproval(r *http.Request, req PendingRequest, status int, errMsg string) {
	if s.AuditSink == nil {
		return
	}
	s.AuditSink(AuditEntry{
		Timestamp:  timeNow().UTC().Format("2006-01-02T15:04:05Z07:00"),
		Identity:   requestIdentity(r),
		Method:     r.Method,
		Path:       r.URL.Path,
		ClusterID:  req.ClusterID,
		WorkloadID: req.TargetID,
		Replicas:   req.Replicas,
		Status:     status,
		Error:      errMsg,
		ApprovalID: req.ID,
	})
}

// approvalErrStatus maps store errors to HTTP status codes.
func approvalErrStatus(err error) int {
	switch {
	case errors.Is(err, ErrApprovalNotFound):
		return http.StatusNotFound
	case errors.Is(err, ErrSelfApprove), errors.Is(err, ErrApprovalTerminal):
		return http.StatusConflict
	default:
		return http.StatusInternalServerError
	}
}

func writeApprovalError(w http.ResponseWriter, err error) {
	writeError(w, approvalErrStatus(err), err.Error())
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
