# Claude Handover

## Purpose

This document is a working handoff for the next coding agent session on `ClusterOrbit`.
It focuses on the current mobile implementation state, what changed recently, where the important code lives, and what the next high-value tasks are.

## Current Status

The most meaningful progress is in `app/mobile`.

Implemented so far:

- Flutter app shell with phone and tablet navigation.
- Cluster domain model for nodes, workloads, services, alerts, links, and snapshots.
- Connection abstraction with direct and gateway modes.
- `DirectClusterConnection` can:
  - read kubeconfig metadata
  - resolve contexts, clusters, users, auth material, and TLS settings
  - fetch read-only data from the Kubernetes API
  - build a `ClusterSnapshot` from live cluster resources
- `GatewayClusterConnection` still uses sample data and is intentionally a stub.
- Topology screen renders an interactive map-like workspace with `InteractiveViewer`, compact
  node/workload/service cards, painted links, deterministic lane-based layout.
- Entity selection and detail drill-down implemented:
  - Tap any node/workload/service card on the map to select it.
  - Tablet: detail panel in right sidebar (scrollable, max 320px).
  - Phone portrait: detail panel slides up from the bottom.
  - Phone landscape: detail panel appears to the right.
  - Dismiss via × button or tap same entity again.
- Domain models enriched with K8s fields: `ClusterNode` has `cpuCapacity`, `memoryCapacity`,
  `osImage`; `ClusterWorkload` has `images`; `ClusterService` has `clusterIp`.
- **SQLite snapshot cache** — `lib/core/sync_cache/snapshot_store.dart`:
  - `SnapshotStore` abstract interface and `SqfliteSnapshotStore` implementation
  - Two-table schema: `cluster_profiles` + `cluster_snapshots`
  - Cache-first bootstrap: shows cached data instantly, refreshes live in background
  - All 8 domain model classes have `toJson()` / `fromJson()` for serialization
- **Per-entity event stream** — `lib/core/connectivity/kubernetes_event_loader.dart`:
  - `loadEvents` on `ClusterConnection` (Direct / Gateway / Test impls)
  - Namespaced for workloads/services, cluster-scoped for nodes
  - `fieldSelector=involvedObject.name={name}`, newest-first, default limit 5
  - Rendered as a "Recent Events" section in the entity detail panel

## Important Files

### Mobile entry and shell

- `app/mobile/lib/app/clusterorbit_app.dart`
- `app/mobile/lib/shared/widgets/orbit_shell.dart`

`OrbitShell` owns both `ClusterConnection` and `SnapshotStore`. Bootstrap is cache-first:
load cached profiles + snapshot immediately, show UI, then fetch live and replace silently.
Live fetch errors are swallowed if cache was shown; surface error only if no cache.

### Domain model

- `app/mobile/lib/core/cluster_domain/cluster_models.dart`

Defines the contract the UI is built around: `ClusterProfile`, `ClusterNode`, `ClusterWorkload`,
`ClusterService`, `ClusterAlert`, `TopologyLink`, `ClusterSnapshot`. All classes now have
`toJson()`/`fromJson()`. Changing shapes here breaks the topology screen, store, and tests.

### Snapshot cache

- `app/mobile/lib/core/sync_cache/snapshot_store.dart`

`SnapshotStore` interface + `SqfliteSnapshotStore`. The store is the only layer that should
touch SQLite. `OrbitShell` is the only layer that should call the store.

Key implementation details:

- `_dbFuture ??= _openDb()` — memoised async DB init (one connection per store instance)
- `ConflictAlgorithm.replace` — upsert semantics for both tables
- Corrupt JSON rows are silently skipped (logged internally, treated as cache miss)
- `@visibleForTesting dbForTest` — exposes the raw DB handle for corruption tests only

### Connectivity

- `app/mobile/lib/core/connectivity/cluster_connection.dart`
- `app/mobile/lib/core/connectivity/cluster_connection_factory.dart`
- `app/mobile/lib/core/connectivity/kubeconfig_repository.dart`
- `app/mobile/lib/core/connectivity/kubernetes_snapshot_loader.dart`
- `app/mobile/lib/core/connectivity/kubernetes_event_loader.dart`
- `app/mobile/lib/core/connectivity/sample_cluster_data.dart`

### Topology UI

- `app/mobile/lib/features/topology/topology_screen.dart`

Self-contained. Contains the interactive map, entity cards, painted links, lane layout,
`_EntityDetailPanel`, and selection state. No reusable engine package extracted yet.

## Tests

**60 tests, all passing.** Run with:

```bash
cd app/mobile
flutter test
```

Test files:

- `test/cluster_models_serialization_test.dart` — 18 tests: round-trips all 8 classes,
  exhaustive enum coverage (`WorkloadKind`, `ServiceExposure`, `TopologyEntityKind`, etc.)
- `test/snapshot_store_test.dart` — 10 tests: empty load, save/load, upsert, multi-profile,
  empty `saveProfiles` no-op, corrupted payload for profiles and snapshots
- `test/topology_screen_test.dart` — entity selection, detail panel, dismiss, event stream render
- `test/kubernetes_event_loader_test.dart` — 5 tests: namespaced vs cluster-scoped URL, sort and
  truncation, malformed skip, empty response
- `test/orbit_shell_phone_test.dart`, `test/orbit_shell_tablet_test.dart`
- `test/clusterorbit_app_test.dart`, `test/cluster_connection_factory_test.dart`,
  `test/kubernetes_snapshot_loader_test.dart`

`test/test_helpers.dart` provides `NoOpSnapshotStore` (no SQLite I/O in widget tests) and
`TestClusterConnection` (sample data, no kubeconfig needed). All widget tests must pass one
or both of these — never let a test fall through to real SQLite or real kubeconfig.

## Environment

`.env` file (from `.env.example`) controls:

- `CLUSTERORBIT_CONNECTION_MODE` — `direct` or `gateway`
- `CLUSTERORBIT_KUBECONFIG` — override kubeconfig path
- `CLUSTERORBIT_CONTEXT` — kubeconfig context name
- `CLUSTERORBIT_GATEWAY_URL` — only for gateway mode

Direct mode kubeconfig resolution: `CLUSTERORBIT_KUBECONFIG` → `KUBECONFIG` env var → default
home kubeconfig path. Falls back to sample data only if kubeconfig is unresolvable; real API
failures surface as errors.

## Known Limitations and Deliberate Omissions

**`saveProfiles([])` is a no-op, not a clear.** No mechanism to delete all cached profiles.
If needed, add `clearProfiles()` to the interface.

**No "stale cache" UI indicator.** When cached data is shown, `_isLoading` is cleared to
`false`. The app gives no indication that a live refresh is in progress. Deliberate UX choice —
revisit if users need freshness feedback.

**`@visibleForTesting dbForTest`** — exposes raw DB handle. Cleaner alternative: inject a
`DatabaseFactory` via constructor. Current approach works but leaks implementation detail.

**`sqlite3_flutter_libs` in `dev_dependencies`.** Sqflite bundles its own sqlite3 for
Android/iOS, so this is correct for mobile. Move to `dependencies` if desktop is added.

**Gateway mode is fake.** `GatewayClusterConnection` returns sample data. No real auth or
gateway API flow. `GatewayClusterConnection.loadEvents` also returns sample events.

**Topology is a view, not an engine.** No force layout, no LOD, no filter, no viewport
persistence.

## Recommended Next Tasks

1. **Cache TTL / staleness** — `cached_at` column exists but is never read. Add a TTL check
   in `_bootstrap()` to decide whether cached data is worth showing before the live fetch.

2. **Cluster switcher UI polish** — `_cycleCluster` shows cached data immediately but gives
   no indication a live refresh is running. A subtle "Refreshing…" badge in the app bar would
   help.

3. **Resources / Changes / Alerts screens** — still placeholder screens. The domain model is
   now fully serialised; these screens have everything they need.

4. **Event stream polling / refresh** — `_EntityDetailPanel` fetches once on selection. Add a
   pull-to-refresh or periodic auto-refresh (e.g. every 30s while selected) for live-ish feel.
   Consider caching events per entity in `SnapshotStore` so panel opens instantly on re-select.

5. **Real gateway backend** — `GatewayClusterConnection` and `app/gateway/main.go` are both
   stubs. Gateway must also implement `loadEvents`.

## Architecture Reminder

```text
ClusterOrbitApp
  └── OrbitShell (owns SnapshotStore + ClusterConnection)
        ├── _bootstrap(): cache → live → save
        ├── _cycleCluster(): cache → live → save
        └── TopologyScreen / ResourcesScreen / ...

SnapshotStore (interface)
  └── SqfliteSnapshotStore
        ├── cluster_profiles table
        └── cluster_snapshots table

ClusterConnection (interface)
  ├── DirectClusterConnection  (real kubeconfig)
  └── GatewayClusterConnection (stub)
```

`OrbitShell` is the only widget that should call `SnapshotStore`. No other layer should
access it directly.

## Quick Resume Checklist

1. Read `PROJECT_PLAN.md`.
2. Read `app/mobile/lib/shared/widgets/orbit_shell.dart` — bootstrap flow.
3. Read `app/mobile/lib/core/sync_cache/snapshot_store.dart` — cache layer.
4. Read `app/mobile/lib/features/topology/topology_screen.dart` — map + detail.
5. Run `flutter test` in `app/mobile`.
6. Pick a task from the list above.
