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
- `GatewayClusterConnection` now speaks the real gateway HTTP contract
  (`X-ClusterOrbit-Token` header; falls back to sample data when no URL configured).
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

### Session state

- `app/mobile/lib/shared/state/cluster_session_controller.dart`

`ClusterSessionController` (ChangeNotifier) owns: cluster list, selected cluster, current
snapshot, load/refresh flags, `lastRefreshedAt`, and the 30s ticker that drives the
"Updated Xm ago" AppBar label. `OrbitShell` is now a thin navigation shell wrapped in
`ListenableBuilder(listenable: _session)`. Tests live in `test/cluster_session_controller_test.dart`.

### Snapshot cache

- `app/mobile/lib/core/sync_cache/snapshot_store.dart`

`SnapshotStore` interface + `SqfliteSnapshotStore`. The store is the only layer that should
touch SQLite. `ClusterSessionController` is the only layer that should call the store.

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

Split across eight files under `app/mobile/lib/features/topology/`:

- `topology_screen.dart` — orchestration only (selection state, filter state, viewport owner)
- `topology_workspace.dart` — the canvas Stack + header + summary chips + filter row
- `topology_panels.dart` — `TopologySidebar` (tablet rail) with flight-deck + priority alerts
- `topology_layout.dart` — deterministic lane-based positioning + `TopologyFilter`
- `topology_orbs.dart` — `NodeOrb` / `WorkloadOrb` / `ServiceOrb` + legend/status cards
- `topology_painters.dart` — `OrbitBackdropPainter`, `TopologyGridPainter`, `TopologyLinkPainter`
- `entity_detail_panel.dart` — tap-to-open side panel with events + scale dialog

## Tests

**101 tests, all passing.** Run with:

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

**Stale-cache UX** — the AppBar shows a "Refreshing" spinner while a live fetch is in
flight and "Updated Xm ago" + a tap-to-refresh button once it lands. A 30s ticker in
`ClusterSessionController` keeps the relative time fresh without a rebuild storm.

**`@visibleForTesting dbForTest`** — exposes raw DB handle. Cleaner alternative: inject a
`DatabaseFactory` via constructor. Current approach works but leaks implementation detail.

**`sqlite3_flutter_libs` in `dev_dependencies`.** Sqflite bundles its own sqlite3 for
Android/iOS, so this is correct for mobile. Move to `dependencies` if desktop is added.

**Gateway has a real Kubernetes backend and is multi-cluster.** `MultiClusterBackend`
resolves every kubeconfig context on boot and routes by `cluster_id`. Rate limiting
(token-bucket, per-identity) + optional mTLS + JSON-Lines audit log all shipped. First
mutation endpoint — POST `/clusters/{id}/workloads/{wid}/scale` — is live and audited.

**Topology engine** is no longer a single file — filtering, LOD (hide labels below 0.9x),
viewport persistence (TransformationController retained across rebuilds), and a deterministic
lane layout are all shipped. Still no force-based layout.

## Recommended Next Tasks

Prior items 1–5 plus the real Kubernetes backend, gateway hardening, multi-cluster,
mutation flow, topology engine split, and cache-invalidation UX are all done. New
priorities:

1. **Approval / policy flows on the gateway.** `scale` is audited but unconditional —
   add policy gates (e.g. max replicas, namespace allowlist, two-person approval) before
   exposing more write paths.

2. **More mutation endpoints.** Cordon/drain nodes, restart deployments, rolling-update
   image. Each one needs an explicit confirmation dialog on the mobile side and an audit
   record on the gateway.

3. **Force-directed layout** as an optional topology mode — the deterministic lane
   layout reads fine for small clusters but doesn't scale past ~40 nodes.

4. **Retained scene graph** — re-rendering the full Stack on every frame of pan/zoom
   is fine today but won't hold up under 200+ orbs. Move to a `CustomPainter` pass for
   the orb layer with hit-testing via a spatial index.

5. **Settings screen wiring** — `settings_screen.dart` is still a placeholder. First
   real control: pick kubeconfig context from a dropdown (today it's implicit on boot).

## Architecture Reminder

```text
ClusterOrbitApp
  └── OrbitShell (thin nav shell, ListenableBuilder on session)
        └── ClusterSessionController (owns ClusterConnection + SnapshotStore)
              ├── bootstrap(): cache → live → save
              ├── refresh(): live → save (returns error string for SnackBar)
              ├── cycleCluster(): cache → live → save
              └── TopologyScreen / ResourcesScreen / ...

SnapshotStore (interface)
  └── SqfliteSnapshotStore
        ├── cluster_profiles table
        └── cluster_snapshots table

ClusterConnection (interface)
  ├── DirectClusterConnection  (real kubeconfig)
  └── GatewayClusterConnection (real HTTP; sample fallback on empty URL)

Gateway server (app/gateway/)
  └── api.Server (mux, shared-token auth, per-identity rate limit, optional mTLS)
        └── api.ClusterBackend (interface)
              ├── SampleBackend (in-memory demo data)
              └── MultiClusterBackend (one KubeBackend per resolvable context)
```

`ClusterSessionController` is the only layer that should call `SnapshotStore`. Widgets
read through the controller via `ListenableBuilder`.

## Quick Resume Checklist

1. Read `PROJECT_PLAN.md`.
2. Read `app/mobile/lib/shared/state/cluster_session_controller.dart` — session state.
3. Read `app/mobile/lib/shared/widgets/orbit_shell.dart` — nav shell wrapping the controller.
4. Read `app/mobile/lib/core/sync_cache/snapshot_store.dart` — cache layer.
5. Skim the `app/mobile/lib/features/topology/*.dart` split — screen / workspace / panels / orbs / painters / layout / entity_detail_panel.
6. Run `flutter test` in `app/mobile`.
7. Pick a task from the list above.
