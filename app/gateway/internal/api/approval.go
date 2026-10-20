package api

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"sort"
	"sync"
	"time"
)

// Approval op-class identifiers. These are the values an ApprovalStore gates
// and the Op field of a PendingRequest. They cross the wire to clients.
const (
	OpScale   = "scale"
	OpRestart = "restart"
	OpCordon  = "cordon"
	OpDrain   = "drain"
)

// Approval phase values. A request starts Pending and ends in exactly one
// terminal state. "approved" is transient but observable: GET /approvals
// returns it while the approved mutation is still executing, so clients must
// treat it as non-terminal. These strings cross the wire; don't rename
// without updating clients.
const (
	ApprovalPhasePending   = "pending"
	ApprovalPhaseApproved  = "approved"
	ApprovalPhaseRejected  = "rejected"
	ApprovalPhaseExpired   = "expired"
	ApprovalPhaseSucceeded = "succeeded"
	ApprovalPhaseFailed    = "failed"
)

// Approval store errors. Handlers map these to HTTP status codes.
var (
	ErrApprovalNotFound = errors.New("approval request not found")
	ErrSelfApprove      = errors.New("requester cannot approve own request")
	ErrApprovalTerminal = errors.New("approval request already resolved")
)

// PendingRequest is a parked mutation awaiting a second-person approval. The
// deferred mutation is captured as typed fields (not a closure) so the record
// stays inspectable and JSON-serializable, consistent with DrainJob.
type PendingRequest struct {
	ID        string `json:"id"`
	Op        string `json:"op"`
	ClusterID string `json:"clusterId"`
	TargetID  string `json:"targetId"`
	Replicas  *int   `json:"replicas,omitempty"`
	Phase     string `json:"phase"`
	Requester string `json:"requester"`
	Approver  string `json:"approver,omitempty"`
	Reason    string `json:"reason,omitempty"`
	ResultID  string `json:"resultId,omitempty"`
	CreatedAt int64  `json:"createdAt"`
	UpdatedAt int64  `json:"updatedAt"`
	ExpiresAt int64  `json:"expiresAt"`
}

// ApprovalStore holds the op-classes that must be parked for a second-person
// approval and the in-memory registry of parked requests. Like the drain-job
// registry it is mutex-guarded and non-durable: a gateway restart drops all
// pending requests (acceptable — they are short-lived and TTL'd). Resolved
// requests stay listable for a retention window, then are dropped. A nil
// store requires approval for nothing, consistent with the
// ScalePolicy/NodePolicy permissive defaults.
type ApprovalStore struct {
	mu   sync.Mutex
	reqs map[string]*PendingRequest
	// ops is fixed at construction and only read afterwards, so Requires
	// needs no lock.
	ops map[string]bool
	ttl time.Duration
	// retention is how long a request stays in the store after it reaches
	// a terminal phase (see sweepLocked).
	retention time.Duration
	now       func() time.Time
	newID     func() string
}

// minApprovalRetention is the floor on how long resolved requests stay
// listable, so a short TTL doesn't hide outcomes before anyone looks.
const minApprovalRetention = time.Hour

// NewApprovalStore builds a store that parks the given op-classes (OpScale,
// OpRestart, OpCordon, OpDrain) and expires parked requests after ttl.
// Resolved requests are kept for max(ttl, 1h).
func NewApprovalStore(ttl time.Duration, ops ...string) *ApprovalStore {
	required := make(map[string]bool, len(ops))
	for _, op := range ops {
		required[op] = true
	}
	return &ApprovalStore{
		reqs:      make(map[string]*PendingRequest),
		ops:       required,
		ttl:       ttl,
		retention: max(ttl, minApprovalRetention),
		now:       time.Now,
		newID:     randomApprovalID,
	}
}

// Requires reports whether op must be parked for approval. A nil store or an
// op not in the set returns false (execute inline). Gating cordon also gates
// drain: a drain cordons the node before evicting, so it must never be less
// guarded than cordon (the superset rule NodePolicy.EvaluateDrain follows).
func (s *ApprovalStore) Requires(op string) bool {
	if s == nil {
		return false
	}
	if op == OpDrain && s.ops[OpCordon] {
		return true
	}
	return s.ops[op]
}

func randomApprovalID() string {
	var b [12]byte
	_, _ = rand.Read(b[:])
	return "apr-" + hex.EncodeToString(b[:])
}

// Park records a new pending request and returns a deep copy. It sweeps old
// resolved requests first, so parking alone keeps the store bounded.
func (s *ApprovalStore) Park(op, clusterID, targetID string, replicas *int, requester string) PendingRequest {
	now := s.now().UnixMilli()
	req := &PendingRequest{
		ID:        s.newID(),
		Op:        op,
		ClusterID: clusterID,
		TargetID:  targetID,
		Replicas:  replicas,
		Phase:     ApprovalPhasePending,
		Requester: requester,
		CreatedAt: now,
		UpdatedAt: now,
		ExpiresAt: s.now().Add(s.ttl).UnixMilli(),
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sweepLocked(s.now())
	s.reqs[req.ID] = req
	return copyRequest(req)
}

// Get returns a copy of a request by ID, lazily expiring it first.
func (s *ApprovalStore) Get(id string) (PendingRequest, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, ok := s.reqs[id]
	if !ok {
		return PendingRequest{}, false
	}
	s.expireLocked(r)
	return copyRequest(r), true
}

// List returns copies of all requests for clusterID (empty == all), sorted by
// CreatedAt then ID for deterministic output. The sweep expires each lazily
// and drops old resolved ones first.
func (s *ApprovalStore) List(clusterID string) []PendingRequest {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sweepLocked(s.now())
	out := []PendingRequest{}
	for _, r := range s.reqs {
		if clusterID == "" || r.ClusterID == clusterID {
			out = append(out, copyRequest(r))
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].CreatedAt != out[j].CreatedAt {
			return out[i].CreatedAt < out[j].CreatedAt
		}
		return out[i].ID < out[j].ID
	})
	return out
}

// sweepLocked expires overdue pending requests, then deletes requests that
// reached a terminal phase (rejected, expired, succeeded, failed) more than
// s.retention before now. "approved" is never swept: its mutation is still
// running and the handler's Complete must find it. Caller must hold s.mu.
func (s *ApprovalStore) sweepLocked(now time.Time) {
	cutoff := now.Add(-s.retention).UnixMilli()
	for id, r := range s.reqs {
		s.expireLocked(r)
		switch r.Phase {
		case ApprovalPhaseRejected, ApprovalPhaseExpired, ApprovalPhaseSucceeded, ApprovalPhaseFailed:
			if r.UpdatedAt < cutoff {
				delete(s.reqs, id)
			}
		}
	}
}

// expireLocked flips a still-pending request to expired once its TTL elapses.
// Caller must hold s.mu.
func (s *ApprovalStore) expireLocked(r *PendingRequest) {
	if r.Phase == ApprovalPhasePending && s.now().UnixMilli() >= r.ExpiresAt {
		r.Phase = ApprovalPhaseExpired
		r.UpdatedAt = s.now().UnixMilli()
	}
}

func copyRequest(r *PendingRequest) PendingRequest {
	out := *r
	if r.Replicas != nil {
		v := *r.Replicas
		out.Replicas = &v
	}
	return out
}

// Approve transitions a pending request to approved, recording the approver.
// The approver must differ from the requester. The handler executes the
// captured mutation and then calls Complete. Returns a copy of the approved
// request.
func (s *ApprovalStore) Approve(id, approver string) (PendingRequest, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, ok := s.reqs[id]
	if !ok {
		return PendingRequest{}, ErrApprovalNotFound
	}
	s.expireLocked(r)
	if r.Phase != ApprovalPhasePending {
		return PendingRequest{}, ErrApprovalTerminal
	}
	if approver == r.Requester {
		return PendingRequest{}, ErrSelfApprove
	}
	r.Approver = approver
	r.Phase = ApprovalPhaseApproved
	r.UpdatedAt = s.now().UnixMilli()
	return copyRequest(r), nil
}

// Reject resolves a pending request as rejected. Any identity may reject,
// including the requester cancelling their own request. reason is optional.
func (s *ApprovalStore) Reject(id, reason string) (PendingRequest, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, ok := s.reqs[id]
	if !ok {
		return PendingRequest{}, ErrApprovalNotFound
	}
	s.expireLocked(r)
	if r.Phase != ApprovalPhasePending {
		return PendingRequest{}, ErrApprovalTerminal
	}
	r.Phase = ApprovalPhaseRejected
	r.Reason = reason
	r.UpdatedAt = s.now().UnixMilli()
	return copyRequest(r), nil
}

// Complete moves an approved request to a terminal phase after execution.
// errMsg == "" → succeeded (resultID carried for async ops like drain); a
// non-empty errMsg → failed with the message in Reason. Returns a copy.
func (s *ApprovalStore) Complete(id, resultID, errMsg string) (PendingRequest, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, ok := s.reqs[id]
	if !ok {
		return PendingRequest{}, ErrApprovalNotFound
	}
	if errMsg != "" {
		r.Phase = ApprovalPhaseFailed
		r.Reason = errMsg
	} else {
		r.Phase = ApprovalPhaseSucceeded
		r.ResultID = resultID
	}
	r.UpdatedAt = s.now().UnixMilli()
	return copyRequest(r), nil
}
