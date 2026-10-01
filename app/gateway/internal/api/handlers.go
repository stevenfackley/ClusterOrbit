package api

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log"
	"net"
	"net/http"
	"net/url"
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
// rotation is "add new token → roll clients → drop old token". Limiter (if
// non-nil) applies per-token, or per-IP if auth is disabled; failed auth
// attempts are limited per source address.
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
	// TrustForwardedFor makes the client IP the last X-Forwarded-For entry
	// instead of the TCP peer address. Set it only behind a reverse proxy
	// that appends or overwrites that header; otherwise any client can choose
	// its own rate-limit bucket and, with auth off, its audit identity.
	TrustForwardedFor bool
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
// avoid the token value — Identity is a token fingerprint (see identity).
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
		if accepted := s.acceptedTokens(); len(accepted) > 0 && !tokenAccepted(r.Header.Get(AuthHeader), accepted) {
			// Throttle failed attempts per TCP peer so tokens can't be
			// guessed at line rate. Never keyed on a header the client sets.
			if !s.Limiter.Allow("unauth:" + remoteHost(r)) {
				writeError(w, http.StatusTooManyRequests, "rate limit exceeded")
				return
			}
			writeError(w, http.StatusUnauthorized, "missing or invalid token")
			return
		}
		if !s.Limiter.Allow(s.identity(r)) {
			writeError(w, http.StatusTooManyRequests, "rate limit exceeded")
			return
		}
		next(w, r)
	}
}

// tokenAccepted reports whether got matches any accepted token. Each compare
// is constant-time and the loop never stops early, so timing reveals neither
// which token matched nor how much of one did (only token lengths leak).
func tokenAccepted(got string, accepted []string) bool {
	if got == "" {
		return false
	}
	match := 0
	for _, t := range accepted {
		match |= subtle.ConstantTimeCompare([]byte(got), []byte(t))
	}
	return match == 1
}

// identity returns the caller identity used as the rate-limit key, in audit
// records, and as the requester/approver on pending approvals. With auth on
// it is "tok:" plus the first 12 hex chars of the SHA-256 of the presented
// token (authMiddleware has already checked it), so distinct tokens never
// share an identity and no token bytes are disclosed. With auth off it is the
// client IP; a client-supplied header is never an identity.
func (s *Server) identity(r *http.Request) string {
	if len(s.acceptedTokens()) == 0 {
		return s.clientIP(r)
	}
	sum := sha256.Sum256([]byte(r.Header.Get(AuthHeader)))
	return "tok:" + hex.EncodeToString(sum[:6])
}

// clientIP is the TCP peer address, or the last X-Forwarded-For entry (the
// address the nearest proxy saw; earlier entries are client-supplied) when
// TrustForwardedFor is set.
func (s *Server) clientIP(r *http.Request) string {
	if s.TrustForwardedFor {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			return strings.TrimSpace(xff[strings.LastIndexByte(xff, ',')+1:])
		}
	}
	return remoteHost(r)
}

// remoteHost is the host part of r.RemoteAddr, the TCP peer.
func remoteHost(r *http.Request) string {
	if host, _, err := net.SplitHostPort(r.RemoteAddr); err == nil {
		return host
	}
	return r.RemoteAddr
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

// handleClusterScoped dispatches /v1/clusters/{id}/{subpath}. The cluster ID
// is cut from the escaped path because it may contain "/" (EKS context names
// are cluster ARNs, arn:aws:eks:…:cluster/prod), which clients send as %2F.
// The two halves are unescaped separately.
func (s *Server) handleClusterScoped(w http.ResponseWriter, r *http.Request) {
	rest, ok := strings.CutPrefix(r.URL.EscapedPath(), pathRoot+"/")
	if !ok || rest == "" {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	rawCluster, rawSubpath, _ := strings.Cut(rest, "/")
	clusterID, err := url.PathUnescape(rawCluster)
	if err != nil {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	subpath, err := url.PathUnescape(rawSubpath)
	if err != nil {
		writeError(w, http.StatusNotFound, "not found")
		return
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
	// can't contain "/" (handleDrainStatus validates it), so splitting on
	// "/drain/" cleanly separates the node from the job ID.
	if rest := strings.TrimPrefix(subpath, "nodes/"); rest != subpath {
		if idx := strings.Index(rest, "/drain/"); idx >= 0 {
			nodeID := rest[:idx]
			jobID := rest[idx+len("/drain/"):]
			s.handleDrainStatus(w, r, clusterID, nodeID, jobID)
			return
		}
	}

	// GET .../approvals/{rid} — single pending request.
	if rid := strings.TrimPrefix(subpath, "approvals/"); rid != subpath {
		s.handleGetApproval(w, r, clusterID, rid)
		return
	}

	switch subpath {
	case "approvals":
		s.handleListApprovals(w, r, clusterID)
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
		if err := ValidateEventQuery(kind, objectName, namespace); err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
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
// Workload IDs ("{kind}:{namespace}/{name}") contain a literal "/", so we peel
// the resource prefix and the trailing action verb rather than splitting the
// whole subpath by slash; each handler then validates the target ID. Every
// attempt is audited downstream.
func (s *Server) handleMutation(w http.ResponseWriter, r *http.Request, clusterID, subpath string) {
	switch {
	case strings.HasPrefix(subpath, "workloads/"):
		s.handleWorkloadMutation(w, r, clusterID, strings.TrimPrefix(subpath, "workloads/"))
	case strings.HasPrefix(subpath, "nodes/"):
		s.handleNodeMutation(w, r, clusterID, strings.TrimPrefix(subpath, "nodes/"))
	case strings.HasPrefix(subpath, "approvals/"):
		s.handleApprovalAction(w, r, clusterID, strings.TrimPrefix(subpath, "approvals/"))
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
	if err := ValidateNodeID(nodeID); err != nil {
		s.audit(r, clusterID, nodeID, nil, http.StatusBadRequest, err.Error())
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	if reason := s.NodePolicy.EvaluateDrain(nodeID); reason != "" {
		s.audit(r, clusterID, nodeID, nil, http.StatusForbidden, "policy: "+reason)
		writeError(w, http.StatusForbidden, "policy violation: "+reason)
		return
	}

	if s.ApprovalPolicy.Requires(OpDrain) {
		pr := s.Approvals.Park(OpDrain, clusterID, nodeID, nil, s.identity(r))
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
	if err := ValidateNodeID(nodeID); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
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
	if err := ValidateNodeID(nodeID); err != nil {
		s.audit(r, clusterID, nodeID, nil, http.StatusBadRequest, err.Error())
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	if reason := s.NodePolicy.EvaluateCordon(nodeID, unschedulable); reason != "" {
		s.audit(r, clusterID, nodeID, nil, http.StatusForbidden, "policy: "+reason)
		writeError(w, http.StatusForbidden, "policy violation: "+reason)
		return
	}

	if unschedulable && s.ApprovalPolicy.Requires(OpCordon) {
		pr := s.Approvals.Park(OpCordon, clusterID, nodeID, nil, s.identity(r))
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
	_, namespace, _, err := ParseWorkloadID(workloadID)
	if err != nil {
		s.audit(r, clusterID, workloadID, nil, http.StatusBadRequest, err.Error())
		writeError(w, http.StatusBadRequest, err.Error())
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

	if reason := s.ScalePolicy.Evaluate(namespace, *body.Replicas); reason != "" {
		s.audit(r, clusterID, workloadID, body.Replicas, http.StatusForbidden, "policy: "+reason)
		writeError(w, http.StatusForbidden, "policy violation: "+reason)
		return
	}

	if s.ApprovalPolicy.Requires(OpScale) {
		pr := s.Approvals.Park(OpScale, clusterID, workloadID, body.Replicas, s.identity(r))
		s.auditApproval(r, pr, http.StatusAccepted, "")
		writeJSON(w, http.StatusAccepted, pr)
		return
	}

	err = s.Backend.ScaleWorkload(r.Context(), clusterID, workloadID, *body.Replicas)
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
	_, namespace, _, err := ParseWorkloadID(workloadID)
	if err != nil {
		s.audit(r, clusterID, workloadID, nil, http.StatusBadRequest, err.Error())
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	if reason := s.ScalePolicy.EvaluateNamespace(namespace); reason != "" {
		s.audit(r, clusterID, workloadID, nil, http.StatusForbidden, "policy: "+reason)
		writeError(w, http.StatusForbidden, "policy violation: "+reason)
		return
	}

	if s.ApprovalPolicy.Requires(OpRestart) {
		pr := s.Approvals.Park(OpRestart, clusterID, workloadID, nil, s.identity(r))
		s.auditApproval(r, pr, http.StatusAccepted, "")
		writeJSON(w, http.StatusAccepted, pr)
		return
	}

	err = s.Backend.RestartWorkload(r.Context(), clusterID, workloadID)
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
	s.AuditSink(AuditEntry{
		Timestamp:  timeNow().UTC().Format("2006-01-02T15:04:05Z07:00"),
		Identity:   s.identity(r),
		Method:     r.Method,
		Path:       r.URL.Path,
		ClusterID:  clusterID,
		WorkloadID: workloadID,
		Replicas:   replicas,
		Status:     status,
		Error:      errMsg,
	})
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
		Identity:   s.identity(r),
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

// handleListApprovals serves GET /v1/clusters/{id}/approvals.
func (s *Server) handleListApprovals(w http.ResponseWriter, _ *http.Request, clusterID string) {
	if s.Approvals == nil {
		writeJSON(w, http.StatusOK, []PendingRequest{})
		return
	}
	writeJSON(w, http.StatusOK, s.Approvals.List(clusterID))
}

// handleGetApproval serves GET /v1/clusters/{id}/approvals/{rid}. Read-only,
// not audited (consistent with snapshot/events GETs).
func (s *Server) handleGetApproval(w http.ResponseWriter, _ *http.Request, clusterID, rid string) {
	if rid == "" || s.Approvals == nil {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	pr, ok := s.Approvals.Get(rid)
	if !ok || pr.ClusterID != clusterID {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	writeJSON(w, http.StatusOK, pr)
}

// handleApprovalAction dispatches POST .../approvals/{rid}/{approve|reject}.
func (s *Server) handleApprovalAction(w http.ResponseWriter, r *http.Request, clusterID, rest string) {
	switch {
	case strings.HasSuffix(rest, "/approve"):
		s.handleApprove(w, r, clusterID, strings.TrimSuffix(rest, "/approve"))
	case strings.HasSuffix(rest, "/reject"):
		s.handleReject(w, r, clusterID, strings.TrimSuffix(rest, "/reject"))
	default:
		writeError(w, http.StatusNotFound, "not found")
	}
}

// handleApprove serves POST .../approvals/{rid}/approve. Validates cluster
// ownership, enforces distinct-identity, executes the captured mutation, and
// finalizes the request. Every outcome is audited.
func (s *Server) handleApprove(w http.ResponseWriter, r *http.Request, clusterID, rid string) {
	if rid == "" || s.Approvals == nil {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	// Without auth no identity is trustworthy enough to tell two people
	// apart, so a second-person approval can't be enforced.
	if len(s.acceptedTokens()) == 0 {
		s.auditApproval(r, PendingRequest{ID: rid, ClusterID: clusterID}, http.StatusForbidden, "approval requires token auth")
		writeError(w, http.StatusForbidden, "approval requires token auth")
		return
	}
	// Validate cluster ownership before mutating phase.
	if pr, ok := s.Approvals.Get(rid); !ok || pr.ClusterID != clusterID {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	approved, err := s.Approvals.Approve(rid, s.identity(r))
	if err != nil {
		status := approvalErrStatus(err)
		s.auditApproval(r, PendingRequest{ID: rid, ClusterID: clusterID}, status, err.Error())
		writeApprovalError(w, err)
		return
	}
	resultID, execMsg := s.executePending(r.Context(), approved)
	final, _ := s.Approvals.Complete(rid, resultID, execMsg)
	status := http.StatusOK
	if execMsg != "" {
		status = http.StatusBadGateway
	}
	s.auditApproval(r, final, status, execMsg)
	writeJSON(w, http.StatusOK, final)
}

// handleReject serves POST .../approvals/{rid}/reject. Any authenticated
// identity may reject (including the requester cancelling).
func (s *Server) handleReject(w http.ResponseWriter, r *http.Request, clusterID, rid string) {
	if rid == "" || s.Approvals == nil {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	if pr, ok := s.Approvals.Get(rid); !ok || pr.ClusterID != clusterID {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	final, err := s.Approvals.Reject(rid, "rejected by "+s.identity(r))
	if err != nil {
		s.auditApproval(r, PendingRequest{ID: rid, ClusterID: clusterID}, approvalErrStatus(err), err.Error())
		writeApprovalError(w, err)
		return
	}
	s.auditApproval(r, final, http.StatusOK, "")
	writeJSON(w, http.StatusOK, final)
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
