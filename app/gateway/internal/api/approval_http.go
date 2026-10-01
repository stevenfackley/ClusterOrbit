package api

import (
	"context"
	"errors"
	"log"
	"net/http"
	"net/url"
	"strings"
)

// writeParked parks op on targetID for a second-person approval and answers
// 202 with the PendingRequest. The Location header names the request to poll,
// which is how a client tells a parked mutation from one that ran.
func (s *Server) writeParked(w http.ResponseWriter, r *http.Request, op, clusterID, targetID string, replicas *int) {
	pr := s.Approvals.Park(op, clusterID, targetID, replicas, s.identity(r))
	s.audit(r, AuditEntry{ClusterID: pr.ClusterID, WorkloadID: pr.TargetID, Replicas: pr.Replicas, ApprovalID: pr.ID, Status: http.StatusAccepted})
	w.Header().Set("Location", pathRoot+"/"+url.PathEscape(pr.ClusterID)+"/approvals/"+url.PathEscape(pr.ID))
	writeJSON(w, http.StatusAccepted, pr)
}

// executePending runs the backend mutation captured by an approved request.
// resultID is the drain job ID for OpDrain and "" for every other op.
func (s *Server) executePending(ctx context.Context, req PendingRequest) (resultID string, err error) {
	switch req.Op {
	case OpScale:
		// handleScale never parks a scale without replicas. Defaulting a
		// missing count to 0 would take the workload down, so refuse it.
		if req.Replicas == nil {
			return "", ErrBadRequest
		}
		return "", s.Backend.ScaleWorkload(ctx, req.ClusterID, req.TargetID, *req.Replicas)
	case OpRestart:
		return "", s.Backend.RestartWorkload(ctx, req.ClusterID, req.TargetID)
	case OpCordon:
		return "", s.Backend.CordonNode(ctx, req.ClusterID, req.TargetID, true)
	case OpDrain:
		job, err := s.Backend.StartDrain(ctx, req.ClusterID, req.TargetID)
		if err != nil {
			return "", err
		}
		return job.ID, nil
	default:
		return "", ErrBadRequest
	}
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
		s.audit(r, AuditEntry{ClusterID: clusterID, ApprovalID: rid, Status: http.StatusForbidden, Error: "approval requires token auth"})
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
		s.audit(r, AuditEntry{ClusterID: clusterID, ApprovalID: rid, Status: approvalErrStatus(err), Error: err.Error()})
		writeApprovalError(w, err)
		return
	}

	// The approve action itself succeeded, so the response is 200 whatever
	// the mutation did; the record's phase carries the outcome. A failure is
	// audited with the status the inline path would have returned and the
	// raw error. The record, which every caller can read, gets only the
	// client-safe message.
	resultID, execErr := s.executePending(r.Context(), approved)
	entry := AuditEntry{ClusterID: approved.ClusterID, WorkloadID: approved.TargetID, Replicas: approved.Replicas, ApprovalID: rid, Status: http.StatusOK}
	reason := ""
	if execErr != nil {
		entry.Status, entry.Error = backendErrStatus(execErr), execErr.Error()
		reason = publicErrMessage(execErr)
	}
	s.audit(r, entry)
	final, err := s.Approvals.Complete(rid, resultID, reason)
	if err != nil {
		log.Printf("gateway: complete approval %s: %v", rid, err)
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}
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
		s.audit(r, AuditEntry{ClusterID: clusterID, ApprovalID: rid, Status: approvalErrStatus(err), Error: err.Error()})
		writeApprovalError(w, err)
		return
	}
	s.audit(r, AuditEntry{ClusterID: final.ClusterID, WorkloadID: final.TargetID, Replicas: final.Replicas, ApprovalID: final.ID, Status: http.StatusOK})
	writeJSON(w, http.StatusOK, final)
}
