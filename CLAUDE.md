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

Scaffold only — `main.go` prints a placeholder string. No real implementation.

## Current limitations (as of last session)

- Topology is a view, not a retained-scene engine — no filtering, LOD, force-based layout, or pan/zoom persistence
- `GatewayClusterConnection` returns sample data only
- No mutation flows (read-only)
- `README.md` is stale; treat code and tests as authoritative

## Key docs

- `docs/engineering/claude-handover.md` — session handover, known issues, recommended next tasks
- `docs/architecture/mobile-architecture.md` — layer responsibilities, state strategy
- `docs/architecture/system-overview.md` — direct vs gateway mode
- `PROJECT_PLAN.md` — full implementation roadmap

## CI workflows (`.github/workflows/`)

- **ci.yml** — mobile (format → analyze → test --coverage) + gateway (mod tidy → gofmt → vet → test -cover)
- **docs-check.yml** — markdownlint on all `*.md`
- **release-draft.yml** — placeholder for tag-triggered releases
