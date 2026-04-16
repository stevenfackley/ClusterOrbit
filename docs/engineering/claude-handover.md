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
- `DirectClusterConnection` can now:
  - read kubeconfig metadata
  - resolve contexts, clusters, users, auth material, and TLS settings
  - fetch read-only data from the Kubernetes API
  - build a `ClusterSnapshot` from live cluster resources
- `GatewayClusterConnection` still uses sample data and is intentionally a stub.
- The topology screen renders an interactive map-like workspace using `InteractiveViewer`, with compact node/workload/service cards and painted links.
- Entity selection and detail drill-down is implemented:
  - Tap any node/workload/service card on the map to select it.
  - Tablet: detail panel appears in the right sidebar column (scrollable, max 320px).
  - Phone portrait: detail panel slides up from the bottom.
  - Phone landscape: detail panel appears to the right with a scroll view.
  - Dismiss via the × button or tap the same entity again.
- Domain models enriched with additional K8s fields:
  - `ClusterNode`: `cpuCapacity`, `memoryCapacity`, `osImage`
  - `ClusterWorkload`: `images` (container image list)
  - `ClusterService`: `clusterIp` (nullable; null for Ingress-type)
- `KubernetesSnapshotLoader` extracts all new fields from the K8s API response.
- `_EntityDetailPanel` surfaces all new fields in the detail view.

Not implemented yet:

- SQLite persistence and offline restore
- mutation flows
- real gateway backend integration
- richer topology engine features: clustering, filtering, viewport-aware LOD, pan/zoom state persistence, force-based layout

## Important Files

### Mobile entry and shell

- [app/mobile/lib/app/clusterorbit_app.dart](C:/Users/steve/projects/ClusterOrbit/app/mobile/lib/app/clusterorbit_app.dart)
- [app/mobile/lib/shared/widgets/orbit_shell.dart](C:/Users/steve/projects/ClusterOrbit/app/mobile/lib/shared/widgets/orbit_shell.dart)

`OrbitShell` is the place where connection bootstrap happens. It selects a cluster, loads a snapshot, and passes it into the feature screens.

### Domain model

- [app/mobile/lib/core/cluster_domain/cluster_models.dart](C:/Users/steve/projects/ClusterOrbit/app/mobile/lib/core/cluster_domain/cluster_models.dart)

This file defines the contract the UI is currently built around:

- `ClusterProfile`
- `ClusterNode` (includes `cpuCapacity`, `memoryCapacity`, `osImage`)
- `ClusterWorkload` (includes `images`)
- `ClusterService` (includes `clusterIp`)
- `ClusterAlert`
- `TopologyLink`
- `ClusterSnapshot`

If you change these shapes, expect the topology screen and tests to need updates.

### Connectivity

- [app/mobile/lib/core/connectivity/cluster_connection.dart](C:/Users/steve/projects/ClusterOrbit/app/mobile/lib/core/connectivity/cluster_connection.dart)
- [app/mobile/lib/core/connectivity/cluster_connection_factory.dart](C:/Users/steve/projects/ClusterOrbit/app/mobile/lib/core/connectivity/cluster_connection_factory.dart)
- [app/mobile/lib/core/connectivity/kubeconfig_repository.dart](C:/Users/steve/projects/ClusterOrbit/app/mobile/lib/core/connectivity/kubeconfig_repository.dart)
- [app/mobile/lib/core/connectivity/kubernetes_snapshot_loader.dart](C:/Users/steve/projects/ClusterOrbit/app/mobile/lib/core/connectivity/kubernetes_snapshot_loader.dart)
- [app/mobile/lib/core/connectivity/sample_cluster_data.dart](C:/Users/steve/projects/ClusterOrbit/app/mobile/lib/core/connectivity/sample_cluster_data.dart)

Responsibilities:

- `cluster_connection_factory.dart`
  - chooses direct vs gateway mode from environment
  - owns `DirectClusterConnection` and `GatewayClusterConnection`
- `kubeconfig_repository.dart`
  - reads kubeconfig from env/default path
  - parses contexts, clusters, users, auth, and TLS material
- `kubernetes_snapshot_loader.dart`
  - calls the Kubernetes API
  - fetches nodes, pods, services, deployments, daemonsets, statefulsets, jobs, and replicasets
  - reduces them into the existing `ClusterSnapshot` model
  - extracts `cpuCapacity`, `memoryCapacity`, `osImage`, `images`, `clusterIp`
- `sample_cluster_data.dart`
  - still used as fallback and for tests

### Topology UI

- [app/mobile/lib/features/topology/topology_screen.dart](C:/Users/steve/projects/ClusterOrbit/app/mobile/lib/features/topology/topology_screen.dart)

This file currently contains:

- the interactive map workspace
- compact visual nodes for cluster entities
- painted curved links
- deterministic lane-based layout
- sidebar panels for summary and alerts (tablet)
- `_EntityDetailPanel` — the drill-down view showing entity fields
- selection state in `_TopologyScreenState._selectedEntity`

It is intentionally still self-contained. There is no reusable topology engine package yet.

## Tests

The mobile suite is currently green (23 tests) with:

```powershell
cd app/mobile
flutter test
```

Relevant tests:

- [app/mobile/test/cluster_connection_factory_test.dart](C:/Users/steve/projects/ClusterOrbit/app/mobile/test/cluster_connection_factory_test.dart)
- [app/mobile/test/kubernetes_snapshot_loader_test.dart](C:/Users/steve/projects/ClusterOrbit/app/mobile/test/kubernetes_snapshot_loader_test.dart)
- [app/mobile/test/topology_screen_test.dart](C:/Users/steve/projects/ClusterOrbit/app/mobile/test/topology_screen_test.dart)
- [app/mobile/test/orbit_shell_phone_test.dart](C:/Users/steve/projects/ClusterOrbit/app/mobile/test/orbit_shell_phone_test.dart)
- [app/mobile/test/orbit_shell_tablet_test.dart](C:/Users/steve/projects/ClusterOrbit/app/mobile/test/orbit_shell_tablet_test.dart)

Test infrastructure note:

- [app/mobile/test/test_helpers.dart](C:/Users/steve/projects/ClusterOrbit/app/mobile/test/test_helpers.dart) injects a deterministic test connection so widget tests do not depend on local kubeconfig or live cluster state.

Do not remove that isolation unless you also redesign the test strategy.

## Environment Expectations

The mobile app expects a local `.env` file based on:

- [app/mobile/.env.example](C:/Users/steve/projects/ClusterOrbit/app/mobile/.env.example)

Important env keys:

- `CLUSTERORBIT_CONNECTION_MODE`
- `CLUSTERORBIT_GATEWAY_URL`
- `CLUSTERORBIT_KUBECONFIG`
- `CLUSTERORBIT_CONTEXT`

Direct mode behavior:

1. try `CLUSTERORBIT_KUBECONFIG`
2. then `KUBECONFIG`
3. then default home kubeconfig path

If direct mode cannot resolve a usable kubeconfig context, it falls back to sample data.
If it resolves a real context and the Kubernetes API call fails, the failure should surface rather than silently fabricating a live result.

## Known Limitations

### 1. Topology screen is still a view, not an engine

The current map is useful, but it is not yet the retained-scene topology engine described in `PROJECT_PLAN.md`.
Layout is deterministic and lane-based, not force-based or hierarchical.
There is no filtering, no viewport-aware LOD, and no pan/zoom state persistence.

### 2. Gateway mode is still fake

`GatewayClusterConnection` remains a scaffold returning sample-backed snapshots.
No real auth/session/token/audit/gateway API flow exists yet.

### 3. Local caching is not implemented

There is no SQLite snapshot store yet, despite the architecture and product docs assuming it.

### 4. Some docs are stale

At least one top-level doc is out of date:

- [README.md](C:/Users/steve/projects/ClusterOrbit/README.md) still says Flutter and Go are not installed locally. That was true earlier, but not during the last implementation passes.

Treat the current code and test results as authoritative over that note.

## Recommended Next Task

Best next task: **SQLite snapshot caching**

Concrete shape:

1. Add `drift` (or `sqflite`) as a dependency in `app/mobile/pubspec.yaml`.
2. Create `app/mobile/lib/core/sync_cache/` with:
   - a `SnapshotStore` that persists and retrieves `ClusterSnapshot` by profile ID
   - a schema with a `snapshots` table: `(id TEXT PRIMARY KEY, profile_id TEXT, generated_at INTEGER, payload TEXT)`
   - serialization: encode `ClusterSnapshot` to/from JSON
3. Wire `OrbitShell` to: load cached snapshot immediately on startup, then refresh from cluster in the background and update.
4. Test: unit tests for the store (insert, fetch, stale detection).

Why this next:

- The map and detail drill-down are now the primary value. Caching makes them available offline and makes cold-start instant.
- The architecture doc explicitly calls for SQLite — this closes the biggest gap between current state and the described design.
- It requires no UI changes; it slots in below `OrbitShell`.

## Second-Best Next Task

Add per-entity event stream in the detail panel:

- Fetch `GET /api/v1/namespaces/{ns}/events?fieldSelector=involvedObject.name={name}` for the selected entity.
- Show the last 5 events in `_EntityDetailPanel` below the existing field rows.
- This makes the detail panel operationally useful, not just informational.

## Suggested Implementation Boundaries

If continuing from here, keep these boundaries intact:

- Keep kubeconfig parsing in `kubeconfig_repository.dart`.
- Keep HTTP Kubernetes fetch logic in `kubernetes_snapshot_loader.dart` or a sibling transport-focused file.
- Keep `ClusterSnapshot` as the UI-facing read model for the map.
- Avoid pushing more orchestration into `OrbitShell`; it should remain a shell/bootstrap layer.
- Avoid making widget tests depend on real machine state.

## Quick Resume Checklist

If you are Claude resuming this work:

1. Read [PROJECT_PLAN.md](C:/Users/steve/projects/ClusterOrbit/PROJECT_PLAN.md).
2. Read [app/mobile/lib/shared/widgets/orbit_shell.dart](C:/Users/steve/projects/ClusterOrbit/app/mobile/lib/shared/widgets/orbit_shell.dart).
3. Read [app/mobile/lib/features/topology/topology_screen.dart](C:/Users/steve/projects/ClusterOrbit/app/mobile/lib/features/topology/topology_screen.dart).
4. Read the connectivity files under [app/mobile/lib/core/connectivity](C:/Users/steve/projects/ClusterOrbit/app/mobile/lib/core/connectivity).
5. Run `flutter test` in `app/mobile`.
6. Implement the recommended next task above.
