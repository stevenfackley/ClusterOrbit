package api

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"sort"
	"sync"
	"time"
)

// Approval op-class identifiers. These are the values an ApprovalPolicy gates
// and the Op field of a PendingRequest. They cross the wire to clients.
const (
	OpScale   = "scale"
	OpRestart = "restart"
	OpCordon  = "cordon"
	OpDrain   = "drain"
)

// Approval phase values. A request starts Pending and ends in exactly one
// terminal state. "approved" is a transient internal phase — execution is
// synchronous, so the park/poll path never observes it. These strings cross
// the wire; don't rename without updating clients.
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

// ApprovalPolicy names the op-classes that must be parked for a second-person
// approval. Zero value (nil pointer or empty RequiredOps) requires approval for
// nothing — consistent with ScalePolicy/NodePolicy permissive defaults.
type ApprovalPolicy struct {
	RequiredOps map[string]bool
}

// Requires reports whether op must be parked for approval. A nil policy or an
// op not in the set returns false (execute inline).
func (p *ApprovalPolicy) Requires(op string) bool {
	if p == nil || len(p.RequiredOps) == 0 {
		return false
	}
	return p.RequiredOps[op]
}

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

// ApprovalStore is an in-memory registry of pending approval requests. Like the
// drain-job registry it is mutex-guarded and non-durable: a gateway restart
// drops all pending requests (acceptable — they are short-lived and TTL'd).
type ApprovalStore struct {
	mu    sync.Mutex
	reqs  map[string]*PendingRequest
	ttl   time.Duration
	now   func() time.Time
	newID func() string
}

// NewApprovalStore builds a store whose parked requests expire after ttl.
func NewApprovalStore(ttl time.Duration) *ApprovalStore {
	return &ApprovalStore{
		reqs:  make(map[string]*PendingRequest),
		ttl:   ttl,
		now:   time.Now,
		newID: randomApprovalID,
	}
}

func randomApprovalID() string {
	var b [12]byte
	_, _ = rand.Read(b[:])
	return "apr-" + hex.EncodeToString(b[:])
}

// Park records a new pending request and returns a deep copy.
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
	s.reqs[req.ID] = req
	s.mu.Unlock()
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
// CreatedAt then ID for deterministic output. Expires each lazily.
func (s *ApprovalStore) List(clusterID string) []PendingRequest {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []PendingRequest{}
	for _, r := range s.reqs {
		s.expireLocked(r)
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
