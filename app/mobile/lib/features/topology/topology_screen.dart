import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/cluster_domain/cluster_models.dart';
import '../../core/connectivity/cluster_connection.dart';
import '../../core/sync_cache/snapshot_store.dart';
import '../../core/theme/clusterorbit_theme.dart';
import 'entity_detail_panel.dart';
import 'topology_layout.dart';
import 'topology_list_view.dart';
import 'topology_panels.dart';
import 'topology_workspace.dart';

class TopologyScreen extends StatefulWidget {
  const TopologyScreen({
    super.key,
    required this.snapshot,
    required this.isLoading,
    required this.error,
    this.connection,
    this.clusterId,
    this.store,
  });

  final ClusterSnapshot? snapshot;
  final bool isLoading;
  final Object? error;
  final ClusterConnection? connection;
  final String? clusterId;
  final SnapshotStore? store;

  @override
  State<TopologyScreen> createState() => _TopologyScreenState();
}

enum _PhoneView { list, map }

class _TopologyScreenState extends State<TopologyScreen> {
  Object? _selectedEntity;
  TopologyFilter _filter = const TopologyFilter();
  final TransformationController _viewport = TransformationController();
  _PhoneView _phoneView = _PhoneView.list;

  @override
  void dispose() {
    _viewport.dispose();
    super.dispose();
  }

  void _onEntityTap(Object entity) {
    setState(() {
      _selectedEntity = _selectedEntity == entity ? null : entity;
    });
  }

  void _clearSelection() {
    setState(() => _selectedEntity = null);
  }

  void _setFilter(TopologyFilter next) {
    setState(() => _filter = next);
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
        final layout = TopologyLayout.build(
          clusterSnapshot,
          canvasHeight: canvasHeight,
          filter: _filter,
        );

        final workspace = TopologyWorkspace(
          snapshot: clusterSnapshot,
          layout: layout,
          canvasHeight: canvasHeight,
          palette: palette,
          selectedEntity: _selectedEntity,
          onEntityTap: _onEntityTap,
          onDismiss: _clearSelection,
          showPortraitPanel: !isWide && !isLandscape,
          connection: widget.connection,
          clusterId: widget.clusterId,
          store: widget.store,
          filter: _filter,
          onFilterChange: _setFilter,
          viewport: _viewport,
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
                  child: TopologySidebar(
                    snapshot: clusterSnapshot,
                    palette: palette,
                    selectedEntity: _selectedEntity,
                    onDismiss: _clearSelection,
                    connection: widget.connection,
                    clusterId: widget.clusterId,
                    store: widget.store,
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
                            child: SingleChildScrollView(
                              child: EntityDetailPanel(
                                entity: _selectedEntity!,
                                palette: palette,
                                onDismiss: _clearSelection,
                                connection: widget.connection,
                                clusterId: widget.clusterId,
                                store: widget.store,
                                profileId: widget.clusterId,
                              ),
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          );
        } else {
          // Phone portrait — default to list; toggle to map.
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: SegmentedButton<_PhoneView>(
                  key: const ValueKey('phone-view-toggle'),
                  style: SegmentedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: const [
                    ButtonSegment(
                      value: _PhoneView.list,
                      label: Text('List'),
                      icon: Icon(Icons.list),
                    ),
                    ButtonSegment(
                      value: _PhoneView.map,
                      label: Text('Map'),
                      icon: Icon(Icons.hub_outlined),
                    ),
                  ],
                  selected: {_phoneView},
                  onSelectionChanged: (s) =>
                      setState(() => _phoneView = s.first),
                ),
              ),
              Expanded(
                child: _phoneView == _PhoneView.list
                    ? TopologyListView(
                        snapshot: clusterSnapshot,
                        connection: widget.connection,
                        clusterId: widget.clusterId,
                        store: widget.store,
                      )
                    : Padding(
                        padding: const EdgeInsets.all(20),
                        child: workspace,
                      ),
              ),
            ],
          );
        }
      },
    );
  }
}
