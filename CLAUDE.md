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
- **Gateway** — optional Go backend brokers auth, audit, policy, two-person approvals. A missing/unparseable gateway URL is an error (no sample fallback)

In the app, the active connection comes from saved connections (onboarding / Settings → `ClusterOrbitRootGate`); only sample and gateway connections can be created from the UI. The `.env` path (`CLUSTERORBIT_CONNECTION_MODE`, `ClusterConnectionFactory.fromEnvironment`) only applies when `OrbitShell` gets no connection. Kubeconfig resolution order: `CLUSTERORBIT_KUBECONFIG` → `KUBECONFIG` env var → default home path.

### Mobile app layers (`app/mobile/lib/`)

| Path | Responsibility |
|------|---------------|
| `core/cluster_domain/cluster_models.dart` | UI-facing domain model: `ClusterProfile`, `ClusterSnapshot`, `ClusterNode`, `ClusterWorkload`, `ClusterService`, `ClusterAlert`, `TopologyLink`, `DrainJob`. JSON is persisted in the cache; `fromJson` tolerates null/missing lists. **Changing shapes here breaks topology screen and tests.** |
| `core/connectivity/cluster_connection.dart` | `ClusterConnection` interface, `ClusterOperation` + `supportedOperations` (UI gates actions on it), `PendingApproval` / `ApprovalPendingException` |
| `core/connectivity/cluster_connection_factory.dart` | `fromEnvironment` factory + `DirectClusterConnection` + `SampleClusterConnection`; re-exports the gateway connection |
| `core/connectivity/gateway_cluster_connection.dart` | Gateway HTTP client; typed `GatewayException` (`statusCode`, `serverMessage`, `userMessage`); a parked `202` (body has `op`) → `ApprovalPendingException` |
| `core/connectivity/kube_transport.dart` | K8s HTTP transport: URL builder keeps the server's path prefix and escapes segments, TLS context, timeouts, `KubernetesApiException` |
| `core/connectivity/connection_errors.dart` | `readableError` — every on-screen connection error goes through it |
| `core/connectivity/kubeconfig_repository.dart` | Parses kubeconfig with `package:yaml`: contexts, clusters, users, auth, TLS |
| `core/connectivity/kubernetes_snapshot_loader.dart` | Calls K8s API; fetches nodes/pods/services/deployments/daemonsets/statefulsets/jobs/replicasets; reduces to `ClusterSnapshot`. **Mirrors the gateway's `transform.go`** (selectors, selectorless services, Job rule) — change both together |
| `core/connectivity/sample_cluster_data.dart` | Fallback data + used in tests |
| `core/sync_cache/snapshot_store.dart` | `SnapshotStore` interface + `SqfliteSnapshotStore` (profiles, snapshots, events, saved connections) + `ScopedSnapshotStore` decorator (per-saved-connection id prefix; the root gate wraps the shared store) |
| `core/theme/` | Dark theme, `ClusterOrbitPalette`, `HealthStyle` (the one health-level → color/icon/label mapping) |
| `shared/state/cluster_session_controller.dart` | Owns connection + store: cache-first bootstrap, generation guard against stale responses, `retry()`, `staleError`, best-effort cache writes |
| `shared/widgets/orbit_shell.dart` | Adaptive nav shell; phone=bottom tabs, tablet (≥960)=scrolling side rail + content. Don't push more orchestration here. |
| `features/topology/` | Interactive map split across 11 files: screen (selection by (kind, id), breakpoints from its own constraints), workspace, `OrbMetrics` size-aware lane layout, orbs, painters, sidebar, list view, `entity_detail_panel.dart` (one `_confirm`/`_runMutation` path: approval-pending, capability gating, inline result), `EntityEventsController`, `DrainProgressDialog` |
| `features/connections/` | `AddGatewayScreen` + saved-connection builders (used by onboarding and Settings) |
| `features/{resources,changes,alerts,settings,onboarding}/` | Other nav destinations; no-snapshot loading/error states via `shared/widgets/refreshable.dart` |

### Test isolation

`test/test_helpers.dart` injects deterministic fakes (`TestClusterConnection`, `RecordingClusterConnection`, `NoOpSnapshotStore`, `InMemorySavedConnectionStore`) — widget tests never depend on a real kubeconfig, live cluster or SQLite. Don't remove this isolation. `test/flutter_test_config.dart` makes missed taps fatal; layout tests that depend on text metrics load Roboto (vendored in `test/fonts`) via `test/real_fonts.dart` (the default test font has 1em-wide glyphs).

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

- Topology is a widget `Stack`, not a retained-scene engine; lane layout only (no force-based layout)
- Two-person approval flow exists on the gateway (park → distinct-identity approve → execute), but pending requests are in-memory only (dropped on restart). The app reports a parked mutation ("Awaiting second-operator approval") but has no UI for listing/approving them yet
- Gateway tokens are stored in plaintext in sqflite (Android auto backup disabled); Direct mode has no creation UI; the gateway client can't use a custom CA or client cert
- `README.md` is stale; treat code and tests as authoritative

## Key docs

- `docs/engineering/claude-handover.md` — session handover, known issues, recommended next tasks
- `docs/architecture/mobile-architecture.md` — layer responsibilities, state strategy
- `docs/architecture/system-overview.md` — direct vs gateway mode
- `docs/PROJECT_PLAN.md` — full implementation roadmap

## CI workflows (`.github/workflows/`)

- **ci.yml** — `mobile` (format → analyze → test --coverage), `android` (`flutter build apk --debug`, exercises Gradle/AGP bumps), `gateway` (reusable `stevenfackley/gh-actions` `ci-go.yml@v1`, `go-version: stable`, includes govulncheck)
- **docs-check.yml** — markdownlint on all `*.md`
- **dependabot-auto-merge.yml** — auto-merges Dependabot patch PRs (`pull_request_target`)
- **ios-release.yml** — iOS TestFlight on `v*` tags / manual, self-hosted `clusterorbit-mac` runner
- **macos-release.yml** — macOS TestFlight on `mac-v*` tags / manual, self-hosted `clusterorbit-mac` runner
- **release-draft.yml** — placeholder for tag-triggered releases (echo only, fires on `v*` tags)
