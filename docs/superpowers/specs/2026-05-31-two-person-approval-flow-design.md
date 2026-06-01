# Two-Person Approval Flow (Gateway) — Design

Date: 2026-05-31
Status: Approved, pre-implementation
Scope: Go gateway only (`app/gateway/`). Mobile wiring is a follow-up.

## Problem

The gateway has synchronous policy gates (`ScalePolicy`, `NodePolicy`) that
allow or deny a mutation inline and audit every attempt. Missing is an
*asynchronous* path: parking a destructive mutation until a **second, distinct
operator** approves it. This is the keystone of the product's "guarded admin"
thesis — the most destructive op shipped (node drain) should be approvable by a
human other than the requester.

## Approach (chosen: A — approval as a wrapper around the async-job pattern)

Reuse two existing patterns:

1. **Permissive-by-default policy gate** — zero value allows everything; opt in
   via env. Mirrors `ScalePolicy`/`NodePolicy`.
2. **Async job, 202 + poll** — a mutation that can't complete inline returns
   `202` + a pollable handle (today: `DrainJob`). A pending approval is the same
   shape with a different state machine.

Rejected alternatives:

- **B (approval-grant token / two-phase resubmit):** three round-trips, client
  must replay the original request, reinvents OAuth. More client complexity.
- **C (synchronous block-and-wait):** holds an HTTP connection open for minutes,
  fights rate limiter/timeouts, breaks when a mobile app backgrounds.

## Components

One new file `internal/api/approval.go` (+ `approval_test.go`).

### `ApprovalPolicy`

Sibling to `ScalePolicy`/`NodePolicy`. Zero value = no op requires approval.

```go
type ApprovalPolicy struct {
    // RequiredOps names the op-classes that need a second-person approval.
    // Keys: "scale", "restart", "cordon", "drain". nil/empty == none.
    RequiredOps map[string]bool
}

// Requires reports whether op must be parked for approval. nil policy == false.
func (p *ApprovalPolicy) Requires(op string) bool
```

Hung off `Server.ApprovalPolicy *ApprovalPolicy`. A nil policy skips the gate.

### `ApprovalStore`

In-memory, mutex-guarded registry of `PendingRequest`, mirroring the drain job
registry. Owns ID minting, lazy TTL expiry, and approve/reject/execute
transitions. Injectable `now func() time.Time` for deterministic tests. Hung off
`Server.Approvals *ApprovalStore`.

```go
type ApprovalStore struct {
    mu   sync.Mutex
    reqs map[string]*PendingRequest
    ttl  time.Duration
    now  func() time.Time
}
```

### `PendingRequest`

```go
type PendingRequest struct {
    ID        string `json:"id"`
    Op        string `json:"op"`        // scale|restart|cordon|drain
    ClusterID string `json:"clusterId"`
    TargetID  string `json:"targetId"`  // workloadID or nodeID
    Replicas  *int   `json:"replicas,omitempty"` // scale only
    Phase     string `json:"phase"`
    Requester string `json:"requester"` // truncated token identity
    Approver  string `json:"approver,omitempty"`
    Reason    string `json:"reason,omitempty"`   // reject reason / exec error
    ResultID  string `json:"resultId,omitempty"` // drain job id when Op==drain
    CreatedAt int64  `json:"createdAt"`
    UpdatedAt int64  `json:"updatedAt"`
    ExpiresAt int64  `json:"expiresAt"`
}
```

The deferred mutation is captured as **typed fields, not a closure** — keeps the
record inspectable, loggable, and consistent with `DrainJob`. An
`execute(ctx, backend)` method switches on `Op` and calls the matching backend
method.

## State machine

```text
pending ──approve(distinct id)──> approved ─> executing ─> succeeded
   │                                                  └──> failed
   ├──reject──> rejected
   └──TTL──> expired
```

- `approved`/`executing` are transient; execution runs synchronously inside the
  approve handler.
- Scale/restart/cordon are inline backend calls: `succeeded` = done,
  `failed` = backend error (error string in `Reason`).
- **Drain wrinkle:** drain is itself async. Approving a `drain` calls
  `StartDrain`; the `PendingRequest` goes `succeeded` meaning "drain job
  launched", and `ResultID` carries the new `DrainJob` ID to poll next.

## HTTP surface

| Method & path | Purpose | Codes |
|---|---|---|
| `POST .../workloads/{wid}/scale` (and restart/cordon/drain) | when op is gated, parks instead of executing | `202` + PendingRequest |
| `GET /v1/clusters/{id}/approvals` | list pending for this cluster | `200` |
| `GET /v1/clusters/{id}/approvals/{rid}` | poll one | `200` / `404` |
| `POST /v1/clusters/{id}/approvals/{rid}/approve` | second-person approve → execute | `200` / `404` / `409` |
| `POST /v1/clusters/{id}/approvals/{rid}/reject` | cancel/deny | `200` / `404` |

- The `202` (park) body and the poll body are the same `PendingRequest` shape —
  same symmetry drain already has.
- Approve/reject are POST mutations → audited.
- Routing: `approvals` slots into `handleClusterScoped` (GET) and
  `handleMutation` (POST) next to the existing `workloads/` / `nodes/` prefixes.

### Handler ordering (per gated mutation)

```text
auth + rate-limit (middleware)
  → ScalePolicy / NodePolicy 403 gate   (hard ceiling, unchanged)
  → ApprovalPolicy gate: if Requires(op) → park PendingRequest, return 202
  → backend execute (only when approval not required)
```

Approval never bypasses the hard policy ceiling: a drain of a protected node is
still a flat `403`, never a parked request.

## Two-person rule & identity

- **Distinct-identity enforcement** lives in the store:
  `Approve(id, approverIdentity)` errors when `approverIdentity == req.Requester`.
  Handler maps that to **409 Conflict** ("requester cannot approve own request").
- **Self-reject is allowed** — you can cancel your own pending request.
- Approving an **already-terminal** request → **409**.
- Identity = the same value `audit()` computes today (truncated token, or client
  IP when auth is off).
- Two-person approval is only meaningful with `_TOKENS` (≥2 tokens). If auth is
  off or a single token is configured, distinct identities are impossible. This
  is **documented, not hard-failed**: on boot, log a warning if `ApprovalPolicy`
  is non-empty but fewer than 2 tokens are configured. Local demos may not care.

## Config

- `CLUSTERORBIT_GATEWAY_POLICY_REQUIRE_APPROVAL` — comma list of op-classes
  (e.g. `drain,scale`). Empty/unset = no approval required.
- `CLUSTERORBIT_GATEWAY_POLICY_APPROVAL_TTL` — Go duration, default `15m`.
- Wired in `cmd/clusterorbit-gateway/main.go` next to the existing policy env
  parsing.

## Audit

- Park, approve, reject, and execute-result each emit an `AuditEntry`.
- Add optional `ApprovalID string json:"approvalId,omitempty"` to `AuditEntry`
  so the log threads one request park → approve → execute.

## Persistence

In-memory, same as drain jobs (the gateway has zero persistence today). A
gateway restart drops pending requests — acceptable: they're short-lived and
TTL'd. Documented as a known limitation, not a defect.

## TTL / expiry

Lazy sweep on any store read (no background goroutine — matches the no-timer
ethos, keeps tests deterministic via injectable `now`). An expired request is
flipped to `expired` on read and returned so a poller observes the terminal
state. Approving an expired request → 409.

## Error handling summary

| Case | Result |
|---|---|
| Unknown `rid` | 404 |
| Self-approve | 409 |
| Approve already-terminal | 409 |
| Approve expired | 409 (flipped to `expired` first) |
| Backend error during execute | phase `failed`, error in `Reason`, audited |
| Gated op but `ApprovalPolicy` nil/empty | passthrough, executes inline |

## Testing (`approval_test.go`, table-driven)

Uses the existing `recordingBackend` double for call-count assertions.

- Park-on-gated-op returns `202` and does **not** call the backend.
- Non-gated op still executes inline (backend called once).
- Self-approve → `409`, backend not called.
- Distinct-identity approve → executes, backend called exactly once.
- Reject → backend never called, phase `rejected`.
- Expiry flips phase to `expired` and blocks approve (`409`).
- Drain approval → calls `StartDrain`, `ResultID` populated, phase `succeeded`.
- `ApprovalPolicy` zero value → full passthrough.

## Net surface area

- 1 new file (`approval.go`) + 1 test file.
- 2 new fields on existing structs: `AuditEntry.ApprovalID`,
  `PendingRequest.ResultID`.
- Routing additions in `handlers.go`; env wiring in `main.go`.
- **No** backend-interface change, **no** persistence layer, **no** mobile work.

## Out of scope (explicit)

- Mobile UI for listing/approving requests (separate follow-up commit).
- Durable/persisted pending requests across restarts.
- Notifications/push to the second approver.
- Approval of arbitrary/raw manifest applies (only the four known op-classes).
