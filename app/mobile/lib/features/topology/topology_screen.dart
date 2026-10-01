import 'package:flutter/material.dart';

import '../../core/cluster_domain/cluster_models.dart';
import '../../core/connectivity/cluster_connection.dart';
import '../../core/connectivity/connection_errors.dart';
import '../../core/sync_cache/snapshot_store.dart';
import '../../core/theme/clusterorbit_theme.dart';
import 'entity_detail_panel.dart';
import 'topology_layout.dart';
import 'topology_list_view.dart';
import 'topology_panels.dart';
import 'topology_selection.dart';
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
    this.onRefresh,
  });

  final ClusterSnapshot? snapshot;
  final bool isLoading;
  final Object? error;
  final ClusterConnection? connection;
  final String? clusterId;
  final SnapshotStore? store;
  final Future<void> Function()? onRefresh;

  @override
  State<TopologyScreen> createState() => _TopologyScreenState();
}

enum _PhoneView { list, map }

class _TopologyScreenState extends State<TopologyScreen> {
  /// Resolved against each new snapshot in [build], so a refresh keeps the
  /// selection and the panel shows the refreshed entity.
  TopologyEntityKey? _selection;
  TopologyFilter _filter = const TopologyFilter();
  final TransformationController _viewport = TransformationController();
  _PhoneView _phoneView = _PhoneView.list;

  @override
  void didUpdateWidget(TopologyScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final selection = _selection;
    if (selection == null) return;
    final snapshot = widget.snapshot;
    // Ids repeat across clusters, so a cluster switch always drops the
    // selection: a mutation must never reach the new cluster's namesake.
    if (oldWidget.clusterId != widget.clusterId ||
        (snapshot != null &&
            resolveTopologyEntity(snapshot, selection) == null)) {
      _selection = null;
    }
  }

  @override
  void dispose() {
    _viewport.dispose();
    super.dispose();
  }

  void _onEntityTap(Object entity) {
    final key = topologyEntityKey(entity);
    setState(() => _selection = _selection == key ? null : key);
  }

  void _clearSelection() {
    setState(() => _selection = null);
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

    final error = widget.error;
    if (error != null || clusterSnapshot == null) {
      // Not loading and nothing to show: the connection failed, or it works
      // but lists no clusters. Either way Retry re-runs the session's load.
      final onRetry = widget.onRefresh;
      return Center(
        child: SingleChildScrollView(
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
                      error != null
                          ? 'Connection failed: ${readableError(error)}'
                          : 'No clusters visible. The connection works but '
                              'lists no clusters; check its access, then retry.',
                      style: theme.textTheme.bodyLarge,
                    ),
                    if (onRetry != null) ...[
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: onRetry,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    final selection = _selection;
    final selectedEntity = selection == null
        ? null
        : resolveTopologyEntity(clusterSnapshot, selection);

    return LayoutBuilder(
      builder: (context, constraints) {
        // Both measured on the map's own pane, which the shell's tablet rail
        // has already narrowed; the window size would overstate it.
        final isWide = constraints.maxWidth >= 900;
        final isLandscape = constraints.maxWidth > constraints.maxHeight;
        final layout = TopologyLayout.build(clusterSnapshot, filter: _filter);

        final workspace = TopologyWorkspace(
          snapshot: clusterSnapshot,
          layout: layout,
          palette: palette,
          selectedEntity: selectedEntity,
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
                    selectedEntity: selectedEntity,
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
          // The detail panel floats over the map's right edge instead of
          // taking width from an already narrow workspace.
          return Padding(
            padding: const EdgeInsets.all(20),
            child: Stack(
              children: [
                Positioned.fill(child: workspace),
                if (selectedEntity != null)
                  Positioned(
                    top: 8,
                    right: 8,
                    bottom: 8,
                    width: 260,
                    child: SingleChildScrollView(
                      child: EntityDetailPanel(
                        entity: selectedEntity,
                        palette: palette,
                        onDismiss: _clearSelection,
                        connection: widget.connection,
                        clusterId: widget.clusterId,
                        store: widget.store,
                        profileId: widget.clusterId,
                      ),
                    ),
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
                        onRefresh: widget.onRefresh,
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
