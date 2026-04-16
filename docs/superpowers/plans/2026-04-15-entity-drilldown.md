# Entity Drill-Down from Topology Map — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tap any node, workload, or service on the topology map to open a read-only detail surface showing all available fields from the current `ClusterSnapshot`.

**Architecture:** Selection state lives in `TopologyScreen` (converted from `StatelessWidget` to `StatefulWidget`). `_CanvasNode` gains an `onTap` callback. Orbs gain a `selected` bool that brightens their border. A new `_EntityDetailPanel` widget renders entity-specific fields and is placed in three positions depending on breakpoint: inside the `_TopologySidebar` column on tablet (AnimatedSize), as a bottom overlay on phone portrait, as a right-side panel on phone landscape. No changes to `OrbitShell`, `cluster_models.dart`, or any connectivity layer.

**Tech Stack:** Flutter, Dart 3 (switch expressions, exhaustive patterns), `AnimatedSize`, `MediaQuery.orientationOf`.

---

## File Map

| File | Change |
|------|--------|
| `app/mobile/lib/features/topology/topology_screen.dart` | Convert `TopologyScreen` to `StatefulWidget`; add `_TopologyScreenState` with `_selectedEntity` state; extend `_CanvasNode`, all three orbs, `_TopologyWorkspace`, `_TopologySidebar`; add `_EntityDetailPanel`, `_DetailRow`, `_DetailStatusRow` |
| `app/mobile/test/topology_screen_test.dart` | Replace existing single test with a suite of 9 tests covering all entity types and all three breakpoints |

No new files. No changes to `cluster_models.dart`, `orbit_shell.dart`, `test_helpers.dart`, or anything under `core/`.

---

## Reference: Sample Data Entity Names

These names come from `SampleClusterData` and are used in test assertions:
- **Control plane node**: `cp-1.dev-orbit` (healthy, schedulable, zone `use1-a`, version `v1.32.3+k3s1`, 17 pods)
- **Workload** (index 0): name `service-1`, kind `Deployment`, namespace `platform`, 3/3 replicas, healthy
- **Service** (index 0): name `service-1`, exposure `ClusterIP`, namespace `platform`, port 80→8080/TCP (name: http)
- Workload orb shows `Deployment / platform`; service orb shows `ClusterIP / platform` — use these to distinguish the two `service-1` entities

---

## Task 1: Write failing tap test + add `onTap` to `_CanvasNode`

**Files:**
- Test: `app/mobile/test/topology_screen_test.dart`
- Modify: `app/mobile/lib/features/topology/topology_screen.dart` (lines 517–534, `_CanvasNode` class)

- [ ] **Step 1: Replace topology_screen_test.dart**

Write `app/mobile/test/topology_screen_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  testWidgets('topology screen renders interactive canvas with live entities',
      (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(1280, 900));

    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.text('Cluster Map'), findsWidgets);
    expect(find.text('Map status'), findsOneWidget);
    expect(find.text('Legend'), findsOneWidget);
    expect(find.text('Direct mode'), findsOneWidget);

    await resetTestSurface(tester);
  });

  // ── tablet (1280×900, isWide = true) ───────────────────────────────────

  testWidgets('tablet: tapping a node shows detail in sidebar column',
      (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(1280, 900));

    // Before tap: name appears once (in orb only)
    expect(find.text('cp-1.dev-orbit'), findsOneWidget);

    await tester.tap(find.text('cp-1.dev-orbit'));
    await tester.pumpAndSettle();

    // After tap: name appears in orb AND detail panel header
    expect(find.text('cp-1.dev-orbit'), findsNWidgets(2));
    // K8s Version label only ever appears in the node detail panel
    expect(find.text('K8s Version'), findsOneWidget);
    // Flight Deck summary still visible alongside detail
    expect(find.text('Flight Deck'), findsOneWidget);

    await resetTestSurface(tester);
  });

  testWidgets('tablet: tapping same node again deselects', (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(1280, 900));

    await tester.tap(find.text('cp-1.dev-orbit'));
    await tester.pumpAndSettle();
    expect(find.text('K8s Version'), findsOneWidget);

    await tester.tap(find.text('cp-1.dev-orbit').first);
    await tester.pumpAndSettle();
    expect(find.text('K8s Version'), findsNothing);

    await resetTestSurface(tester);
  });

  testWidgets('tablet: dismiss button clears selection', (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(1280, 900));

    await tester.tap(find.text('cp-1.dev-orbit'));
    await tester.pumpAndSettle();
    expect(find.text('K8s Version'), findsOneWidget);

    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.text('K8s Version'), findsNothing);

    await resetTestSurface(tester);
  });

  testWidgets('tablet: tapping a workload shows workload fields',
      (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(1280, 900));

    // Find workload by its orb subtitle (kind / namespace) to avoid
    // ambiguity with the service also named service-1
    await tester.tap(find.text('Deployment / platform').first);
    await tester.pumpAndSettle();

    // Namespace label only appears in workload and service detail panels
    expect(find.text('Namespace'), findsOneWidget);
    // Replicas label is specific to workload detail
    expect(find.text('Replicas'), findsOneWidget);

    await resetTestSurface(tester);
  });

  testWidgets('tablet: tapping a service shows service fields', (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(1280, 900));

    // Find service by its orb subtitle
    await tester.tap(find.text('ClusterIP / platform').first);
    await tester.pumpAndSettle();

    // Exposure label only appears in service detail panel
    expect(find.text('Exposure'), findsOneWidget);
    // Port label appears for each port entry
    expect(find.text('Port'), findsOneWidget);

    await resetTestSurface(tester);
  });

  // ── phone portrait (390×844) ────────────────────────────────────────────

  testWidgets('phone portrait: tapping a node shows bottom panel',
      (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(390, 844));

    await tester.tap(find.text('cp-1.dev-orbit'));
    await tester.pumpAndSettle();

    expect(find.text('K8s Version'), findsOneWidget);

    await resetTestSurface(tester);
  });

  testWidgets('phone portrait: dismiss button clears bottom panel',
      (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(390, 844));

    await tester.tap(find.text('cp-1.dev-orbit'));
    await tester.pumpAndSettle();
    expect(find.text('K8s Version'), findsOneWidget);

    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.text('K8s Version'), findsNothing);

    await resetTestSurface(tester);
  });

  // ── phone landscape (844×390) ────────────────────────────────────────────

  testWidgets('phone landscape: tapping a node shows right panel',
      (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(844, 390));

    await tester.tap(find.text('cp-1.dev-orbit'));
    await tester.pumpAndSettle();

    expect(find.text('K8s Version'), findsOneWidget);

    await resetTestSurface(tester);
  });

  testWidgets('phone landscape: right panel absent when nothing selected',
      (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(844, 390));

    expect(find.text('K8s Version'), findsNothing);

    await resetTestSurface(tester);
  });
}
```

- [ ] **Step 2: Run all new tests — expect compile error or FAIL (no implementation yet)**

```bash
cd app/mobile && flutter test test/topology_screen_test.dart -v 2>&1 | head -40
```

Expected: tests FAIL with assertion errors (no detail panel exists).

- [ ] **Step 3: Add `onTap` to `_CanvasNode`**

In `topology_screen.dart`, replace the `_CanvasNode` class (currently lines 517–534):

```dart
class _CanvasNode extends StatelessWidget {
  const _CanvasNode({
    required this.offset,
    required this.child,
    this.onTap,
  });

  final Offset offset;
  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: offset.dx,
      top: offset.dy,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: child,
      ),
    );
  }
}
```

- [ ] **Step 4: Commit**

```bash
cd app/mobile
git add test/topology_screen_test.dart lib/features/topology/topology_screen.dart
git commit -m "test: add entity drill-down test suite; feat: add onTap to _CanvasNode"
```

---

## Task 2: Convert `TopologyScreen` to `StatefulWidget` + scaffold all new widget signatures

This task converts the class, adds state + methods, updates `_TopologyWorkspace` and `_TopologySidebar` signatures, and adds a stub `_EntityDetailPanel`. After this task every test compiles; the detail-content tests still FAIL (stub renders nothing).

**Files:**
- Modify: `app/mobile/lib/features/topology/topology_screen.dart` (entire file restructured)

- [ ] **Step 1: Replace `TopologyScreen` class + add `_TopologyScreenState`**

In `topology_screen.dart`, replace lines 8–107 (the `TopologyScreen` class and its `build` method):

```dart
class TopologyScreen extends StatefulWidget {
  const TopologyScreen({
    super.key,
    required this.snapshot,
    required this.isLoading,
    required this.error,
  });

  final ClusterSnapshot? snapshot;
  final bool isLoading;
  final Object? error;

  @override
  State<TopologyScreen> createState() => _TopologyScreenState();
}

class _TopologyScreenState extends State<TopologyScreen> {
  Object? _selectedEntity;

  void _onEntityTap(Object entity) {
    setState(() {
      _selectedEntity = _selectedEntity == entity ? null : entity;
    });
  }

  void _clearSelection() {
    setState(() => _selectedEntity = null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<ClusterOrbitPalette>()!;
    final clusterSnapshot = widget.snapshot;

    if (widget.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (widget.error != null || clusterSnapshot == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Cluster Map', style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 12),
                    Text(
                      'The topology workspace could not be loaded. Direct and gateway connections both feed this canvas once a snapshot is available.',
                      style: theme.textTheme.bodyLarge,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 1180;
        final isLandscape =
            MediaQuery.orientationOf(context) == Orientation.landscape;
        final canvasHeight = math.max(520.0, constraints.maxHeight - 40);
        final layout = _TopologyLayout.build(
          clusterSnapshot,
          canvasHeight: canvasHeight,
        );

        final workspace = _TopologyWorkspace(
          snapshot: clusterSnapshot,
          layout: layout,
          canvasHeight: canvasHeight,
          palette: palette,
          selectedEntity: _selectedEntity,
          onEntityTap: _onEntityTap,
          onDismiss: _clearSelection,
          showPortraitPanel: !isWide && !isLandscape,
        );

        if (isWide) {
          return Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 10,
                  child: workspace,
                ),
                const SizedBox(width: 20),
                SizedBox(
                  width: 312,
                  child: _TopologySidebar(
                    snapshot: clusterSnapshot,
                    palette: palette,
                    selectedEntity: _selectedEntity,
                    onDismiss: _clearSelection,
                  ),
                ),
              ],
            ),
          );
        } else if (isLandscape) {
          return Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: workspace),
                AnimatedSize(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeInOut,
                  child: _selectedEntity != null
                      ? SizedBox(
                          width: 260,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 16),
                            child: _EntityDetailPanel(
                              entity: _selectedEntity!,
                              palette: palette,
                              onDismiss: _clearSelection,
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          );
        } else {
          // Phone portrait: panel rendered inside _TopologyWorkspace's Stack
          return Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [Expanded(child: workspace)],
            ),
          );
        }
      },
    );
  }
}
```

- [ ] **Step 2: Update `_TopologyWorkspace` constructor to accept selection params**

Replace the `_TopologyWorkspace` class declaration and constructor (keep `build` body unchanged for now — just add the new fields and pass them through where needed):

```dart
class _TopologyWorkspace extends StatelessWidget {
  const _TopologyWorkspace({
    required this.snapshot,
    required this.layout,
    required this.canvasHeight,
    required this.palette,
    required this.selectedEntity,
    required this.onEntityTap,
    required this.onDismiss,
    required this.showPortraitPanel,
  });

  final ClusterSnapshot snapshot;
  final _TopologyLayout layout;
  final double canvasHeight;
  final ClusterOrbitPalette palette;
  final Object? selectedEntity;
  final void Function(Object) onEntityTap;
  final VoidCallback onDismiss;
  final bool showPortraitPanel;
```

Keep the existing `build` method body unchanged for now (orbs still won't pass `selected` or `onTap` — that's Task 3).

- [ ] **Step 3: Update `_TopologySidebar` to accept selection params (stub wiring)**

Add `selectedEntity` and `onDismiss` to the `_TopologySidebar` constructor — accept them but don't use them yet:

```dart
class _TopologySidebar extends StatelessWidget {
  const _TopologySidebar({
    required this.snapshot,
    required this.palette,
    required this.selectedEntity,
    required this.onDismiss,
    this.compact = false,
  });

  final ClusterSnapshot snapshot;
  final ClusterOrbitPalette palette;
  final Object? selectedEntity;
  final VoidCallback onDismiss;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final alerts = snapshot.alerts.take(compact ? 2 : 4).toList();
    return compact
        ? Row(
            children: [
              Expanded(child: _InsightPanel(snapshot: snapshot)),
              const SizedBox(width: 16),
              Expanded(child: _AlertPanel(alerts: alerts)),
            ],
          )
        : Column(
            children: [
              _InsightPanel(snapshot: snapshot),
              const SizedBox(height: 16),
              Expanded(child: _AlertPanel(alerts: alerts)),
              // _EntityDetailPanel wired in Task 5
            ],
          );
  }
}
```

- [ ] **Step 4: Add stub `_EntityDetailPanel` at the end of the file**

Append after the last class in `topology_screen.dart`:

```dart
class _EntityDetailPanel extends StatelessWidget {
  const _EntityDetailPanel({
    required this.entity,
    required this.palette,
    required this.onDismiss,
  });

  final Object entity;
  final ClusterOrbitPalette palette;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    // Stub — content implemented in Task 4
    return const SizedBox.shrink();
  }
}
```

- [ ] **Step 5: Verify the file compiles**

```bash
cd app/mobile && flutter analyze lib/features/topology/topology_screen.dart
```

Expected: no errors (warnings about unused params are fine).

- [ ] **Step 6: Run tests to confirm compile + partial pass**

```bash
cd app/mobile && flutter test test/topology_screen_test.dart -v 2>&1 | tail -20
```

Expected: the original canvas-render test PASSES; all detail-content tests FAIL with `findsOneWidget` assertions (panel is empty stub).

- [ ] **Step 7: Commit**

```bash
cd app/mobile && git add lib/features/topology/topology_screen.dart
git commit -m "feat: convert TopologyScreen to StatefulWidget, scaffold selection params"
```

---

## Task 3: Wire tap callbacks + selection highlight into orbs

**Files:**
- Modify: `app/mobile/lib/features/topology/topology_screen.dart` (orbs + `_TopologyWorkspace.build`)

- [ ] **Step 1: Add `selected` bool to `_NodeOrb`**

Replace the `_NodeOrb` class:

```dart
class _NodeOrb extends StatelessWidget {
  const _NodeOrb({
    required this.node,
    required this.palette,
    this.selected = false,
  });

  final ClusterNode node;
  final ClusterOrbitPalette palette;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = _healthTint(node.health, palette);

    return Container(
      width: 132,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: selected ? 0.20 : 0.12),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: tint.withValues(alpha: selected ? 0.80 : 0.24),
          width: selected ? 2.5 : 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: tint.withValues(alpha: selected ? 0.28 : 0.14),
            blurRadius: selected ? 28 : 18,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(node.name, style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text('${node.role.label} / ${node.zone}',
              style: theme.textTheme.bodyMedium),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _StatusDot(color: tint),
              Text(
                '${node.podCount} pods',
                style: theme.textTheme.bodySmall?.copyWith(color: Colors.white),
              ),
              if (!node.schedulable)
                Text(
                  'Cordoned',
                  style: theme.textTheme.bodySmall?.copyWith(color: tint),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: Add `selected` bool to `_WorkloadOrb`**

Replace the `_WorkloadOrb` class:

```dart
class _WorkloadOrb extends StatelessWidget {
  const _WorkloadOrb({
    required this.workload,
    required this.palette,
    this.selected = false,
  });

  final ClusterWorkload workload;
  final ClusterOrbitPalette palette;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = _healthTint(workload.health, palette);

    return Container(
      width: 132,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: selected ? 0.08 : 0.04),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: tint.withValues(alpha: selected ? 0.80 : 0.22),
          width: selected ? 2.5 : 1.0,
        ),
        boxShadow: selected
            ? [BoxShadow(color: tint.withValues(alpha: 0.22), blurRadius: 24)]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(workload.name, style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            '${workload.kind.label} / ${workload.namespace}',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _StatusDot(color: tint),
              Text(
                '${workload.readyReplicas}/${workload.desiredReplicas} ready',
                style: theme.textTheme.bodySmall?.copyWith(color: Colors.white),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 3: Add `selected` bool to `_ServiceOrb`**

Replace the `_ServiceOrb` class:

```dart
class _ServiceOrb extends StatelessWidget {
  const _ServiceOrb({
    required this.service,
    required this.palette,
    this.selected = false,
  });

  final ClusterService service;
  final ClusterOrbitPalette palette;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = _healthTint(service.health, palette);

    return Container(
      width: 128,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            palette.canvasGlow.withValues(alpha: selected ? 0.26 : 0.16),
            palette.accentCyan.withValues(alpha: selected ? 0.16 : 0.08),
          ],
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: tint.withValues(alpha: selected ? 0.80 : 0.24),
          width: selected ? 2.5 : 1.0,
        ),
        boxShadow: selected
            ? [BoxShadow(color: tint.withValues(alpha: 0.22), blurRadius: 24)]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(service.name, style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            '${service.exposure.label} / ${service.namespace}',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 10),
          Text(
            '${service.targetWorkloadIds.length} workload targets',
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.white),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Update `_TopologyWorkspace.build` to wire `onTap` + `selected` + portrait panel**

In `_TopologyWorkspace.build`, replace the three `for` loops that produce `_CanvasNode` widgets and the inner `Stack` — the one inside `InteractiveViewer` — to add `onTap` and `selected`. Also add the portrait panel at the end of the outer `Stack`.

Replace the section starting at `for (final node in snapshot.nodes)` through `for (final service in snapshot.services)`:

```dart
              for (final node in snapshot.nodes)
                _CanvasNode(
                  offset: layout.positions[node.id]!,
                  onTap: () => onEntityTap(node),
                  child: _NodeOrb(
                    node: node,
                    palette: palette,
                    selected: selectedEntity == node,
                  ),
                ),
              for (final workload in snapshot.workloads)
                _CanvasNode(
                  offset: layout.positions[workload.id]!,
                  onTap: () => onEntityTap(workload),
                  child: _WorkloadOrb(
                    workload: workload,
                    palette: palette,
                    selected: selectedEntity == workload,
                  ),
                ),
              for (final service in snapshot.services)
                _CanvasNode(
                  offset: layout.positions[service.id]!,
                  onTap: () => onEntityTap(service),
                  child: _ServiceOrb(
                    service: service,
                    palette: palette,
                    selected: selectedEntity == service,
                  ),
                ),
```

Then in the outer canvas `Stack` (the one containing `_LegendCard` and `_MiniStatusCard`), add the portrait panel after `_MiniStatusCard`:

```dart
                    if (showPortraitPanel && selectedEntity != null)
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: _EntityDetailPanel(
                          entity: selectedEntity!,
                          palette: palette,
                          onDismiss: onDismiss,
                        ),
                      ),
```

- [ ] **Step 5: Compile check**

```bash
cd app/mobile && flutter analyze lib/features/topology/topology_screen.dart
```

Expected: no errors.

- [ ] **Step 6: Run tests — still FAIL on detail content (stub renders nothing)**

```bash
cd app/mobile && flutter test test/topology_screen_test.dart -v 2>&1 | tail -20
```

Expected: all tests compile; the original canvas test PASSES; all others FAIL with missing text assertions.

- [ ] **Step 7: Commit**

```bash
cd app/mobile && git add lib/features/topology/topology_screen.dart
git commit -m "feat: wire tap callbacks and selection highlight into orbs"
```

---

## Task 4: Implement `_EntityDetailPanel` with real content

**Files:**
- Modify: `app/mobile/lib/features/topology/topology_screen.dart` (`_EntityDetailPanel` stub → full; add `_DetailRow`, `_DetailStatusRow`)

- [ ] **Step 1: Replace the stub `_EntityDetailPanel` and add `_DetailRow` + `_DetailStatusRow`**

Replace the stub `_EntityDetailPanel` class (and everything after the last existing class in the file) with:

```dart
class _EntityDetailPanel extends StatelessWidget {
  const _EntityDetailPanel({
    required this.entity,
    required this.palette,
    required this.onDismiss,
  });

  final Object entity;
  final ClusterOrbitPalette palette;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.panel.withValues(alpha: 0.96),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.40),
            blurRadius: 24,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(child: _buildTitle(theme)),
              IconButton(
                onPressed: onDismiss,
                icon: const Icon(Icons.close, size: 18, color: Colors.white),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                tooltip: 'Dismiss',
              ),
            ],
          ),
          const SizedBox(height: 12),
          ..._buildFields(theme),
        ],
      ),
    );
  }

  Widget _buildTitle(ThemeData theme) {
    final (name, badge) = switch (entity) {
      ClusterNode n => (n.name, n.role.label),
      ClusterWorkload w => (w.name, w.kind.label),
      ClusterService s => (s.name, s.exposure.label),
      _ => ('Unknown', ''),
    };
    return Row(
      children: [
        Expanded(
          child: Text(
            name,
            style: theme.textTheme.titleMedium,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            badge,
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.white70),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildFields(ThemeData theme) => switch (entity) {
        ClusterNode n => _nodeFields(n, theme),
        ClusterWorkload w => _workloadFields(w, theme),
        ClusterService s => _serviceFields(s, theme),
        _ => const [],
      };

  List<Widget> _nodeFields(ClusterNode n, ThemeData theme) {
    final tint = _healthTint(n.health, palette);
    return [
      _DetailRow(label: 'Role', value: n.role.label, theme: theme),
      _DetailRow(label: 'Zone', value: n.zone, theme: theme),
      _DetailRow(label: 'K8s Version', value: n.version, theme: theme),
      _DetailRow(label: 'Pod Count', value: '${n.podCount}', theme: theme),
      _DetailRow(
          label: 'Schedulable',
          value: n.schedulable ? 'Yes' : 'Cordoned',
          theme: theme),
      _DetailStatusRow(
          label: 'Health', value: n.health.name, tint: tint, theme: theme),
    ];
  }

  List<Widget> _workloadFields(ClusterWorkload w, ThemeData theme) {
    final tint = _healthTint(w.health, palette);
    return [
      _DetailRow(label: 'Namespace', value: w.namespace, theme: theme),
      _DetailRow(label: 'Kind', value: w.kind.label, theme: theme),
      _DetailRow(
          label: 'Replicas',
          value: '${w.readyReplicas} / ${w.desiredReplicas} ready',
          theme: theme),
      _DetailRow(
          label: 'Nodes',
          value: '${w.nodeIds.length} placement(s)',
          theme: theme),
      _DetailStatusRow(
          label: 'Health', value: w.health.name, tint: tint, theme: theme),
    ];
  }

  List<Widget> _serviceFields(ClusterService s, ThemeData theme) {
    final tint = _healthTint(s.health, palette);
    return [
      _DetailRow(label: 'Namespace', value: s.namespace, theme: theme),
      _DetailRow(label: 'Exposure', value: s.exposure.label, theme: theme),
      _DetailRow(
          label: 'Targets',
          value: '${s.targetWorkloadIds.length} workload(s)',
          theme: theme),
      for (final p in s.ports)
        _DetailRow(
          label: 'Port',
          value:
              '${p.port} → ${p.targetPort} / ${p.protocol}${p.name != null ? ' (${p.name})' : ''}',
          theme: theme,
        ),
      _DetailStatusRow(
          label: 'Health', value: s.health.name, tint: tint, theme: theme),
    ];
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
    required this.theme,
  });

  final String label;
  final String value;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.white54),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailStatusRow extends StatelessWidget {
  const _DetailStatusRow({
    required this.label,
    required this.value,
    required this.tint,
    required this.theme,
  });

  final String label;
  final String value;
  final Color tint;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.white54),
            ),
          ),
          _StatusDot(color: tint),
          const SizedBox(width: 6),
          Text(
            value,
            style: theme.textTheme.bodySmall?.copyWith(color: tint),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: Run the full test suite**

```bash
cd app/mobile && flutter test test/topology_screen_test.dart -v
```

Expected: all tests that do NOT require the tablet sidebar or landscape panel should now PASS:
- `tablet: tapping a node shows detail in sidebar column` — still FAIL (sidebar not wired yet)
- `tablet: tapping same node again deselects` — still FAIL
- `tablet: dismiss button clears selection` — still FAIL
- `tablet: tapping a workload shows workload fields` — still FAIL
- `tablet: tapping a service shows service fields` — still FAIL
- `phone portrait:` tests — PASS (portrait panel is in `_TopologyWorkspace` stack)
- `phone landscape:` tests — PASS (landscape panel is in `_TopologyScreenState`)
- Original canvas render test — PASS

- [ ] **Step 3: Run the full mobile suite**

```bash
cd app/mobile && flutter test -v
```

Expected: no regressions on orbit_shell or other existing tests.

- [ ] **Step 4: Commit**

```bash
cd app/mobile && git add lib/features/topology/topology_screen.dart
git commit -m "feat: implement _EntityDetailPanel with node/workload/service fields"
```

---

## Task 5: Wire `_EntityDetailPanel` into `_TopologySidebar` (tablet)

**Files:**
- Modify: `app/mobile/lib/features/topology/topology_screen.dart` (`_TopologySidebar.build`)

- [ ] **Step 1: Update `_TopologySidebar.build` to render `_EntityDetailPanel` via `AnimatedSize`**

Replace the `_TopologySidebar.build` method body. Keep the constructor and fields from Task 2. Only the `build` method changes:

```dart
  @override
  Widget build(BuildContext context) {
    final alerts = snapshot.alerts.take(compact ? 2 : 4).toList();
    return compact
        ? Row(
            children: [
              Expanded(child: _InsightPanel(snapshot: snapshot)),
              const SizedBox(width: 16),
              Expanded(child: _AlertPanel(alerts: alerts)),
            ],
          )
        : Column(
            children: [
              _InsightPanel(snapshot: snapshot),
              const SizedBox(height: 16),
              Expanded(child: _AlertPanel(alerts: alerts)),
              AnimatedSize(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOut,
                child: selectedEntity != null
                    ? Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: _EntityDetailPanel(
                          entity: selectedEntity!,
                          palette: palette,
                          onDismiss: onDismiss,
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          );
  }
```

- [ ] **Step 2: Run the tablet tests**

```bash
cd app/mobile && flutter test test/topology_screen_test.dart --name "tablet:" -v
```

Expected: all five tablet tests PASS.

- [ ] **Step 3: Run the full suite**

```bash
cd app/mobile && flutter test -v
```

Expected: all tests PASS.

- [ ] **Step 4: Run lint and format**

```bash
cd app/mobile && dart format --output=none --set-exit-if-changed lib test && flutter analyze
```

Expected: no issues.

- [ ] **Step 5: Commit**

```bash
cd app/mobile && git add lib/features/topology/topology_screen.dart
git commit -m "feat: wire entity detail into tablet sidebar column via AnimatedSize"
```

---

## Task 6: Final verification — all tests green, format clean

- [ ] **Step 1: Run the full mobile test suite**

```bash
cd app/mobile && flutter test -v
```

Expected output ends with something like:

```
00:XX +9: All tests passed!
```

All 9 topology tests + existing orbit_shell + connection factory + snapshot loader tests PASS.

- [ ] **Step 2: Run the Go gateway tests (no regressions)**

```bash
cd ../.. && go test ./... && go vet ./...
```

Expected: PASS (no changes to gateway code).

- [ ] **Step 3: Final commit if any formatting fixes were needed**

If `dart format` made changes, commit them:

```bash
cd app/mobile && git add -u && git commit -m "style: dart format"
```

Otherwise skip.

---

## Troubleshooting

**`find.text('cp-1.dev-orbit')` returns 0 widgets on phone portrait:**
The entities are all in the widget tree (built inside `Stack`/`Positioned`), so `find.text` should find them regardless of scroll position. If not, verify `pumpAndSettle()` was called after `pumpClusterOrbitApp`.

**Landscape orientation not detected (`isLandscape = false` at 844×390):**
`MediaQuery.orientationOf` derives orientation from physical size set via `tester.view.physicalSize`. At width 844, height 390: width > height → `Orientation.landscape`. If this fails, check `tester.view.devicePixelRatio = 1.0` is set (it is, in `pumpClusterOrbitApp`).

**`AnimatedSize` not visible in tests:**
Call `tester.pumpAndSettle()` after the tap — `AnimatedSize` needs frames to animate to its final size.

**Tap on `service-1` text hits the wrong widget (service vs workload):**
Use the subtitle text unique to each: workloads show `'Deployment / platform'`, services show `'ClusterIP / platform'`. These are never ambiguous.
