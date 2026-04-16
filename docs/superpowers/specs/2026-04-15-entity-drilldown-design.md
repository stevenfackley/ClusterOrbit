# Entity Drill-Down from Topology Map

**Date:** 2026-04-15  
**Status:** Approved

## Goal

Tapping a node, workload, or service card on the topology map opens a read-only detail surface showing all available fields for that entity from the current `ClusterSnapshot`. Tapping the same entity again deselects.

## Scope

- Read-only. No mutations, no new API calls, no new connectivity changes.
- All data sourced from the in-memory `ClusterSnapshot` already passed to `TopologyScreen`.
- No changes to `OrbitShell`, `cluster_models.dart`, or any connectivity layer.

## State

`TopologyScreen` converts from `StatelessWidget` to `StatefulWidget`.

New state field:

```dart
Object? _selectedEntity; // ClusterNode | ClusterWorkload | ClusterService | null
```

Type is resolved at render time via `is` pattern matching — no wrapper type introduced.

Selection rules:
- Tap entity → set `_selectedEntity` to that entity object.
- Tap same entity again → set `_selectedEntity = null` (deselect).
- Tap empty canvas area → no change. Deselect is explicit (same-entity tap or `X` button only). InteractiveViewer consumes pan gestures so accidental deselect on drag is not a concern.
- `X` button in detail panel → set `_selectedEntity = null`.

## Tap Handling

`_CanvasNode` gains an `onTap` callback:

```dart
class _CanvasNode extends StatelessWidget {
  final Offset offset;
  final Widget child;
  final VoidCallback? onTap; // new
}
```

Each orb site (`_NodeOrb`, `_WorkloadOrb`, `_ServiceOrb`) is wrapped at the `_CanvasNode` call site, not inside the orb widget itself, so the orbs stay presentational.

Selected entity visual feedback:
- Highlighted border: brighter color, slightly thicker (2px → 2.5px), glow shadow increases.
- Implemented via a `selected` bool passed into each orb — orb switches its decoration.

## Breakpoints

Detected inside `TopologyScreen` using `MediaQuery`:

| Condition | Layout mode |
|-----------|-------------|
| `constraints.maxWidth >= 1180` | Tablet |
| `constraints.maxWidth < 1180` AND `orientation == landscape` | Phone landscape |
| `constraints.maxWidth < 1180` AND `orientation == portrait` | Phone portrait |

The existing `isWide` threshold of 1180 is kept unchanged.

## Tablet Layout (>= 1180px)

The existing 312px `_TopologySidebar` column becomes a scrollable `Column`:

1. `_InsightPanel` — unchanged (naturally compact).
2. `_AlertPanel` — takes remaining space above detail panel (shrinks via `Flexible`).
3. `_EntityDetailPanel` — slides in below with `AnimatedSize` when `_selectedEntity != null`. Hidden (zero height) when nothing is selected.

The sidebar slot width (312px) is unchanged. No layout shift on the canvas side.

`_EntityDetailPanel` is a self-contained card widget:
- Header: entity name + type badge + `X` dismiss button.
- Body: entity-specific field rows.
- Styling matches the existing `_AlertTile` / `_MetricRow` aesthetic.

## Phone Portrait Layout

An `AnimatedSlide` panel built into the widget tree — **not** a modal bottom sheet.  
This keeps the canvas interactive while detail is visible.

- Panel sits in a `Stack` at the bottom of the canvas area.
- Transition: `Offset(0, 1)` → `Offset(0, 0)` when `_selectedEntity != null`.
- Height: 220px fixed — sufficient for all field types without internal scrolling.
- Content: same `_EntityDetailPanel` widget, just placed differently.
- Canvas panning and zooming remain fully interactive with panel open.

## Phone Landscape Layout

When `width < 1180` AND `orientation == landscape`: right-side slide-in panel (~260px wide).

- Canvas occupies remaining width on the left.
- Panel slides in from `Offset(1, 0)` → `Offset(0, 0)`.
- Same `_EntityDetailPanel` widget, vertical layout.
- No recommendation banner — landscape simply works, providing an inspector-style layout that uses the extra width naturally.

## Detail Fields per Entity Type

All fields sourced from `ClusterSnapshot` — no new model properties needed.

**ClusterNode**
- Name
- Role (Control Plane / Worker)
- Zone
- Kubernetes version
- Pod count
- Schedulable (yes / cordoned)
- Health status

**ClusterWorkload**
- Name
- Namespace
- Kind (Deployment / DaemonSet / StatefulSet / Job)
- Ready replicas / desired replicas
- Node placement count (length of `nodeIds`)
- Health status

**ClusterService**
- Name
- Namespace
- Exposure type (ClusterIP / NodePort / LoadBalancer / Ingress)
- Ports (each: `port → targetPort / protocol`)
- Target workload count
- Health status

## Component Summary

| New/Changed | File | Change |
|-------------|------|--------|
| Changed | `topology_screen.dart` | `StatelessWidget` → `StatefulWidget`; add `_selectedEntity` state |
| Changed | `_CanvasNode` | Add `onTap` callback |
| Changed | `_NodeOrb`, `_WorkloadOrb`, `_ServiceOrb` | Add `selected` bool; adjust decoration |
| Changed | `_TopologyWorkspace` | Accept `selectedEntity` and `onEntityTap` params; pass `onTap` through to `_CanvasNode`; layout branching for phone portrait/landscape/tablet handled in parent `TopologyScreen` |
| Changed | `_TopologySidebar` | Wrap in scrollable; add `AnimatedSize` slot for `_EntityDetailPanel` |
| New | `_EntityDetailPanel` | Dismissible card; switches content by entity type |

## Testing

Existing tests must remain green — `test_helpers.dart` injects deterministic connection, no changes needed there.

New widget tests in `topology_screen_test.dart`:
- Tap a node card → `_EntityDetailPanel` appears with node fields.
- Tap same card again → panel disappears.
- Tap `X` → panel disappears.
- Tap workload card → workload fields shown, not node fields.
- Tap service card → service fields shown including ports.
- On wide layout (>= 1180): detail appears in sidebar column.
- On narrow portrait layout: detail appears as bottom panel.
- On narrow landscape layout: detail appears as right panel.
