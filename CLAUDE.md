# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

### Mobile (Flutter) — run from `app/mobile/`

```bash
cp .env.example .env          # first-time setup
flutter pub get
flutter run
flutter test                  # all tests
flutter test test/foo_test.dart  # single test file
flutter test --coverage       # CI uses this
dart format --output=none --set-exit-if-changed lib test
flutter analyze
```

### Gateway (Go) — run from repo root (`go.mod` is at root)

```bash
go test ./...
go vet ./...
gofmt -l .          # list format violations (CI requires clean)
go mod tidy
```

## Architecture

### Two connection modes

- **Direct** — app reads kubeconfig, hits cluster API directly; credentials stay on device; falls back to sample data if kubeconfig unresolvable
- **Gateway** — optional Go backend brokers auth, audit, policy, approvals (stub only, not real yet)

Mode is set via `CLUSTERORBIT_CONNECTION_MODE` in `app/mobile/.env`. Kubeconfig resolution order: `CLUSTERORBIT_KUBECONFIG` → `KUBECONFIG` env var → default home path.

### Mobile app layers (`app/mobile/lib/`)

| Path | Responsibility |
|------|---------------|
| `core/cluster_domain/cluster_models.dart` | UI-facing domain model: `ClusterProfile`, `ClusterSnapshot`, `ClusterNode`, `ClusterWorkload`, `ClusterService`, `ClusterAlert`, `TopologyLink`. **Changing shapes here breaks topology screen and tests.** |
| `core/connectivity/cluster_connection.dart` | `ClusterConnection` interface |
| `core/connectivity/cluster_connection_factory.dart` | Picks direct vs gateway from env; owns both connection impls |
| `core/connectivity/kubeconfig_repository.dart` | Parses kubeconfig: contexts, clusters, users, auth, TLS |
| `core/connectivity/kubernetes_snapshot_loader.dart` | Calls K8s API; fetches nodes/pods/services/deployments/daemonsets/statefulsets/jobs/replicasets; reduces to `ClusterSnapshot` |
| `core/connectivity/sample_cluster_data.dart` | Fallback data + used in tests |
| `core/sync_cache/snapshot_store.dart` | `SnapshotStore` interface + `SqfliteSnapshotStore` (sqflite-backed two-table cache). |
| `shared/widgets/orbit_shell.dart` | Adaptive nav shell; bootstraps connection + snapshot; phone=bottom tabs, tablet=pane layout. Don't push more orchestration here. |
| `features/topology/topology_screen.dart` | Interactive map: `InteractiveViewer`, compact node/workload/service cards, painted curved links, deterministic lane-based layout. Self-contained — no reusable engine extracted yet. |
| `features/{resources,changes,alerts,settings}/` | Other nav destinations (mostly placeholder screens) |

### Test isolation

`test/test_helpers.dart` injects a deterministic `ClusterConnection` — widget tests never depend on a real kubeconfig or live cluster. Don't remove this isolation.

### Go gateway (`app/gateway/`)

Functional HTTP gateway (`go 1.24`, single `yaml.v3` dep, no `client-go`). Layout:

| Path | Responsibility |
|------|---------------|
| `cmd/clusterorbit-gateway/main.go` | Wiring: env → backend (sample or kube), token set, rate limiter, TLS/mTLS, JSON-Lines audit sink, graceful shutdown on SIGTERM/SIGINT. Env builders take an injectable `getenv` and fail fast: a set-but-invalid policy/limit/TTL value is fatal at boot |
| `internal/api/handlers.go` | Router + handlers: GET `/v1/clusters`, `/{id}/snapshot`, `/{id}/events`; POST `…/workloads/{wid}/scale\|restart`, `…/nodes/{id}/cordon\|uncordon\|drain`, GET `…/nodes/{id}/drain/{job}`. Cluster IDs are cut from the escaped path (EKS ARNs with `%2F` route). Shared-token auth via `X-ClusterOrbit-Token`; every mutation audited |
| `internal/api/validate.go` | Name validation at the boundary: workload IDs `kind:ns/name` (DNS-1123), node names, event queries. Violations → 400 + audit, before any policy gate |
| `internal/api/backend.go` | `ClusterBackend` interface + sentinel errors (`ErrNotFound`/`ErrUnsupported`/`ErrBadRequest`) |
| `internal/api/models.go` | Wire shapes, incl. `DrainJob`. Arrays are always `[]`, never `null` |
| `internal/api/ratelimit.go` | Per-identity token bucket. Identity = `tok:` + 12 hex of SHA-256(token) when auth is on, else client IP. Failed auth is limited per TCP peer |
| `internal/api/policy.go` | `ScalePolicy` (replica ceiling + namespace allowlist, gates scale/restart) and `NodePolicy` (node allowlist + protected denylist + drain kill-switch, gates cordon/drain; uncordon always exempt). Zero value = allow-all; violations → 403 + audit |
| `internal/api/approval.go` | `ApprovalStore` (in-memory, TTL'd registry of `PendingRequest`; holds the gated op set: `NewApprovalStore(ttl, ops...)`, nil store = no approval). Gated mutation parks → `202` + `Location: /v1/clusters/{cid}/approvals/{rid}`; gating cordon also gates drain. Resolved requests are evicted max(TTL, 1h) after their last update |
| `internal/api/approval_http.go` | Approval endpoints. A *distinct* identity approves → executes inline (drain → `ResultID` = job id, reusing the node's in-flight job). Self-approve → 409; approve with auth off → 403. Runs after the hard 403 gate |
| `internal/api/samples.go` | Sample backend — same shapes the mobile app ships with; mutations return 501 |
| `internal/kubebackend/` | Real k8s backend. `RestClient` keeps the server URL's path prefix and returns typed `*StatusError` (apiserver 404 → `ErrNotFound`, 400/422 → `ErrBadRequest`; the truncated Status message is client-visible by design). `transform.go` reduces LISTs to the snapshot and mirrors the Dart loader's rules. Drain refuses nodes with unmanaged pods, evicts 5 at a time, and succeeds only once evicted pods are gone; `StartDrain` is idempotent per node. `MultiClusterBackend` serves every resolvable context and skips duplicate IDs |
| `internal/kubeconfig/` | Kubeconfig loader/resolver (yaml.v3): contexts, clusters, users, TLS, token + client-cert auth. Relative paths resolve against the kubeconfig's directory; exec/auth-provider-only or dangling users are rejected (skipped by `ResolveAll`) |

Key env vars: `CLUSTERORBIT_GATEWAY_ADDR`, `_MODE` (`sample`|`kube`), `_TOKEN` / `_TOKENS`, `_TLS_CERT`/`_TLS_KEY`/`_CLIENT_CA`, `_RATE_LIMIT_RPS`/`_BURST` (set both or neither), `_AUDIT_LOG`, `_KUBECONFIG` / `KUBECONFIG`, `_KUBE_CONTEXT`, `_TRUST_PROXY` (bool, default off; with auth off, take the client IP from the last `X-Forwarded-For` entry). Policy gates: `_POLICY_MAX_REPLICAS`, `_POLICY_NAMESPACES` (scale/restart); `_POLICY_NODES` (node allowlist), `_POLICY_PROTECTED_NODES` (denylist), `_POLICY_DISABLE_DRAIN` (cordon/drain). All policy vars unset = allow-all. Async approval: `_POLICY_REQUIRE_APPROVAL` (comma list of `scale,restart,cordon,drain`, case-insensitive, unknown op = fatal; gated ops park for a second-person approve instead of executing inline), `_POLICY_APPROVAL_TTL` (Go duration, default `15m`). Gating any op with fewer than 2 distinct tokens is fatal at boot; requests are in-memory and dropped on restart.

## Current limitations (as of last session)

- Topology is a view, not a retained-scene engine — no filtering, LOD, force-based layout, or pan/zoom persistence
- Two-person approval flow exists on the gateway (park → distinct-identity approve → execute), but pending requests are in-memory only (dropped on restart) and there is no mobile UI for listing/approving them yet
- `README.md` is stale; treat code and tests as authoritative

## Key docs

- `docs/engineering/claude-handover.md` — session handover, known issues, recommended next tasks
- `docs/architecture/mobile-architecture.md` — layer responsibilities, state strategy
- `docs/architecture/system-overview.md` — direct vs gateway mode
- `docs/PROJECT_PLAN.md` — full implementation roadmap

## CI workflows (`.github/workflows/`)

- **ci.yml** — mobile (format → analyze → test --coverage) + gateway (mod tidy → gofmt → vet → test -cover)
- **docs-check.yml** — markdownlint on all `*.md`
- **release-draft.yml** — placeholder for tag-triggered releases
