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
- `GatewayClusterConnection` speaks the real gateway HTTP contract
  (`X-ClusterOrbit-Token` header). A missing or unparseable gateway URL is an error, not
  sample data. Every HTTP call has connect + response timeouts.
- Topology screen renders an interactive map-like workspace with `InteractiveViewer`, compact
  node/workload/service cards, painted links, size-aware lane layout (`OrbMetrics`).
- Entity selection and detail drill-down implemented:
  - Tap any node/workload/service card on the map to select it. Selection is keyed by
    (kind, id), survives refreshes, and clears on a cluster switch.
  - Map pane ≥ 900 wide and ≥ 480 tall: detail replaces the alerts card in the sidebar.
  - Narrower portrait panes: detail panel docks at the bottom.
  - Landscape panes (width > height + keyboard): detail floats over the map's right edge.
  - Dismiss via × button or tap same entity again.
- Entity actions (cordon/uncordon, drain, scale, restart) are gated on
  `ClusterConnection.supportedOperations`. A gateway mutation parked for two-person approval
  (`202` with an `op` key) surfaces as `ApprovalPendingException` and shows "Awaiting
  second-operator approval" inline.
- Domain models enriched with K8s fields: `ClusterNode` has `cpuCapacity`, `memoryCapacity`,
  `osImage`; `ClusterWorkload` has `images`; `ClusterService` has `clusterIp`.
- **SQLite snapshot cache** — `lib/core/sync_cache/snapshot_store.dart`:
  - `SnapshotStore` abstract interface and `SqfliteSnapshotStore` implementation
  - `ScopedSnapshotStore` decorator keys rows `<connectionId>|<id>`; the root gate wraps the
    shared store per active saved connection, and deleting a connection purges its scope
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

`ClusterOrbitRootGate` picks the active saved connection and builds the shell for it.
`OrbitShell` is navigation only; `ClusterSessionController` owns the connection and store.
Bootstrap is cache-first: load cached profiles + snapshot immediately, show UI, then fetch
live and replace. A live failure behind a cached snapshot sets `staleError` and the AppBar
shows "Offline · cached Xm ago"; with no cache the screens show the error with Retry.

### Domain model

- `app/mobile/lib/core/cluster_domain/cluster_models.dart`

Defines the contract the UI is built around: `ClusterProfile`, `ClusterNode`, `ClusterWorkload`,
`ClusterService`, `ClusterAlert`, `TopologyLink`, `ClusterSnapshot`. All classes now have
`toJson()`/`fromJson()`. Changing shapes here breaks the topology screen, store, and tests.

### Session state

- `app/mobile/lib/shared/state/cluster_session_controller.dart`

`ClusterSessionController` (ChangeNotifier) owns: cluster list, selected cluster, current
snapshot, load/refresh flags, `lastRefreshedAt` (the cache row's `cached_at` when showing
cache), `staleError`, and the 30s ticker that drives the "Updated Xm ago" AppBar label.
A load generation counter drops responses that land after a cluster switch. `retry()`
re-runs a failed bootstrap; `refresh()` and the auto-refresh tick fall back to it when
nothing is selected. Cache writes are best-effort, after live state is applied.
`OrbitShell` is a thin navigation shell wrapped in `ListenableBuilder(listenable: _session)`.
Tests live in `test/cluster_session_controller_test.dart`.

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

- `app/mobile/lib/core/connectivity/cluster_connection.dart` — interface, `ClusterOperation`,
  `PendingApproval` / `ApprovalPendingException`
- `app/mobile/lib/core/connectivity/cluster_connection_factory.dart` — env factory, Direct + Sample
- `app/mobile/lib/core/connectivity/gateway_cluster_connection.dart` — gateway HTTP client,
  `GatewayException` (`statusCode`, `serverMessage`, `userMessage`)
- `app/mobile/lib/core/connectivity/kube_transport.dart` — K8s HTTP transport, URL builder
  (keeps the server's path prefix, escapes segments), TLS context, `KubernetesApiException`
- `app/mobile/lib/core/connectivity/connection_errors.dart` — `readableError` for on-screen text
- `app/mobile/lib/core/connectivity/kubeconfig_repository.dart` — `package:yaml` parser
- `app/mobile/lib/core/connectivity/kubernetes_snapshot_loader.dart` — mirrors the gateway's
  `transform.go` rules (namespace-scoped selectors, selectorless services, Job failure rule)
- `app/mobile/lib/core/connectivity/kubernetes_event_loader.dart`
- `app/mobile/lib/core/connectivity/sample_cluster_data.dart`

### Topology UI

Split across eleven files under `app/mobile/lib/features/topology/`:

- `topology_screen.dart` — orchestration (selection key, filter, viewport owner, breakpoints
  from its own constraints)
- `topology_selection.dart` — `TopologyEntityKey` (kind, id) and its resolution against a snapshot
- `topology_workspace.dart` — header (compact below 600 wide) + filter row + canvas; legend and
  status overlays only on canvases ≥ 420 wide
- `topology_panels.dart` — `TopologySidebar`: flight deck + either alerts or the selected detail
- `topology_layout.dart` — `OrbMetrics` + size-aware lane positioning + `TopologyFilter`
- `topology_orbs.dart` — `NodeOrb` / `WorkloadOrb` / `ServiceOrb` + legend/status cards
- `topology_painters.dart` — `OrbitBackdropPainter`, `TopologyGridPainter`, `TopologyLinkPainter`
- `topology_list_view.dart` — phone list mode; detail opens in a modal sheet
- `entity_detail_panel.dart` — fields + actions; every mutation goes through one
  `_confirm` / `_runMutation` (approval-pending, capability gating, inline result)
- `entity_events_controller.dart` — events cache-then-live-then-poll (`ChangeNotifier`)
- `drain_progress_dialog.dart` — drain polling (one-shot timer, stops after 5 failures)

## Tests

**313 tests, all passing.** Run with:

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

`test/test_helpers.dart` provides `NoOpSnapshotStore` (no SQLite I/O in widget tests),
`TestClusterConnection` (sample data, no kubeconfig needed), `RecordingClusterConnection`
(call log + scriptable failures/drain), and `InMemorySavedConnectionStore`. All widget tests
must use these — never let a test fall through to real SQLite or real kubeconfig.
`test/flutter_test_config.dart` makes missed taps (hit-test warnings) fatal.
`test/real_fonts.dart` loads Roboto (vendored in `test/fonts`) for layout tests that depend on text metrics
(the default test font draws every glyph 1em wide).

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

**`saveProfiles` on `ScopedSnapshotStore` replaces the scope's set** (via `deleteProfiles`);
on the raw `SqfliteSnapshotStore` it only upserts. Cache rows written before scoping are
unscoped and never read again.

**Stale-cache UX** — the AppBar shows a "Refreshing" spinner while a live fetch is in
flight, "Updated Xm ago" + a tap-to-refresh button once it lands, and "Offline · cached Xm
ago" when the live fetch behind a cached snapshot failed. A 30s ticker in
`ClusterSessionController` keeps the relative time fresh without a rebuild storm.

**Gateway tokens are stored in plaintext** in the sqflite DB. Android auto backup is off
(`allowBackup="false"`); moving tokens to `flutter_secure_storage` is still open.

**Direct mode has no UI to create it.** Only sample and gateway connections can be added;
`SavedConnection.kubeconfigYaml` is unused. The gateway client also can't trust a custom CA
or present a client cert yet.

**`@visibleForTesting dbForTest`** — exposes raw DB handle. Cleaner alternative: inject a
`DatabaseFactory` via constructor. Current approach works but leaks implementation detail.

**`sqlite3_flutter_libs` in `dev_dependencies`.** Sqflite bundles its own sqlite3 for
Android/iOS, so this is correct for mobile. Move to `dependencies` if desktop is added.

**Gateway has a real Kubernetes backend and is multi-cluster.** `MultiClusterBackend`
resolves every kubeconfig context on boot and routes by `cluster_id`. Rate limiting
(token-bucket, per-identity) + optional mTLS + JSON-Lines audit log all shipped. First
mutation endpoint — POST `/clusters/{id}/workloads/{wid}/scale` — is live and audited.

**Two-person approval flow shipped on the gateway** (`internal/api/approval.go`).
`ApprovalPolicy` (env `_POLICY_REQUIRE_APPROVAL`, comma list of scale/restart/cordon/drain)
parks a gated mutation instead of executing it: the handler returns `202` + a pollable
`PendingRequest`. A *second, distinct* identity calls `…/approvals/{rid}/approve`, which
runs the mutation inline and resolves the request `succeeded`/`failed` (drain launches a
DrainJob and carries its id in `ResultID`). Self-approve → 409; self-reject is allowed.
Lazy TTL expiry (`_POLICY_APPROVAL_TTL`, default 15m). The hard 403 policy gate always
runs first — approval never relaxes the ceiling. **In-memory only** (dropped on restart)
and **no mobile UI yet** — listing/approving pending requests from the app is the follow-up.

**Topology engine** is no longer a single file — filtering, LOD (hide labels below 0.9x),
viewport persistence (TransformationController retained across rebuilds), and a deterministic
lane layout are all shipped. Still no force-based layout.

## Recommended Next Tasks

Prior items 1–5 plus the real Kubernetes backend, gateway hardening, multi-cluster,
mutation flow, topology engine split, cache-invalidation UX, and the gateway-side
two-person approval flow are all done. New priorities:

1. **Mobile UI for the approval flow.** The gateway parks gated mutations (`202` +
   `PendingRequest` + `Location`) and exposes `GET …/approvals`, `GET/approve/reject
   …/approvals/{rid}`. The app already detects a parked mutation and says "Awaiting
   second-operator approval". Still needed: a pending-approvals list, polling the parked
   request, and an approve/reject action that surfaces the distinct-identity (409
   self-approve) rule. Gateway contract lives in `app/gateway/internal/api/approval.go` +
   `approval_http.go`.

2. **More mutation endpoints.** Cordon/drain nodes, restart deployments, rolling-update
   image. Each one needs an explicit confirmation dialog on the mobile side and an audit
   record on the gateway. (Cordon/restart/drain are already wired through the approval
   gate server-side.)

3. **Force-directed layout** as an optional topology mode — the deterministic lane
   layout reads fine for small clusters but doesn't scale past ~40 nodes.

4. **Retained scene graph** — orbs now rebuild only when the 0.9x label threshold flips
   and links sit behind a `RepaintBoundary`, but the orb layer is still a widget `Stack`
   and won't hold up under 200+ orbs. Move to a `CustomPainter` pass for the orb layer
   with hit-testing via a spatial index.

5. **Secure credentials + Direct onboarding** — move gateway tokens to
   `flutter_secure_storage`, add custom-CA / client-cert support to the gateway client, and
   give Direct mode a UI (pasted kubeconfig → `SavedConnection.kubeconfigYaml`; the parser
   already handles `kubectl config view --raw` output).

## Architecture Reminder

```text
ClusterOrbitApp
  └── ClusterOrbitRootGate (saved connections → onboarding or shell per active connection)
        └── OrbitShell (thin nav shell, ListenableBuilder on session)
              └── ClusterSessionController (owns ClusterConnection + SnapshotStore)
                    ├── bootstrap(): cache → live → apply → best-effort save
                    ├── refresh(): live → apply → save (error string for SnackBar)
                    ├── cycleCluster(): cache → live → apply → save
                    ├── retry(): re-run a failed bootstrap
                    └── TopologyScreen / ResourcesScreen / ...
              (results superseded by a cluster switch are dropped by generation)

SnapshotStore (interface)
  ├── ScopedSnapshotStore (decorator: per-saved-connection id prefix)
  └── SqfliteSnapshotStore (profiles, snapshots, events, saved connections)

ClusterConnection (interface; supportedOperations)
  ├── DirectClusterConnection  (real kubeconfig; scale/restart/cordon)
  ├── GatewayClusterConnection (real HTTP; all ops; parked 202 → ApprovalPendingException)
  └── SampleClusterConnection  (demo data; no ops)

Gateway server (app/gateway/)
  └── api.Server (mux, shared-token auth, per-identity rate limit, optional mTLS)
        └── api.ClusterBackend (interface)
              ├── SampleBackend (in-memory demo data)
              └── MultiClusterBackend (one KubeBackend per resolvable context)
```

`ClusterSessionController` is the only layer that should call `SnapshotStore`. Widgets
read through the controller via `ListenableBuilder`.

## Quick Resume Checklist

1. Read `docs/PROJECT_PLAN.md`.
2. Read `app/mobile/lib/shared/state/cluster_session_controller.dart` — session state.
3. Read `app/mobile/lib/shared/widgets/orbit_shell.dart` — nav shell wrapping the controller.
4. Read `app/mobile/lib/core/sync_cache/snapshot_store.dart` — cache layer.
5. Skim the `app/mobile/lib/features/topology/*.dart` split — screen / selection / workspace / panels / orbs / painters / layout / list view / entity_detail_panel / events controller / drain dialog.
6. Run `flutter test` in `app/mobile`.
7. Pick a task from the list above.
