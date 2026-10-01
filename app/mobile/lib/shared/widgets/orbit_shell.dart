import 'package:flutter/material.dart';

import '../../core/cluster_domain/cluster_models.dart';
import '../../core/connectivity/cluster_connection.dart';
import '../../core/connectivity/cluster_connection_factory.dart';
import '../../core/sync_cache/snapshot_store.dart';
import '../../core/theme/clusterorbit_theme.dart';
import '../../features/alerts/alerts_screen.dart';
import '../../features/changes/changes_screen.dart';
import '../../features/resources/resources_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/topology/topology_screen.dart';
import '../state/cluster_session_controller.dart';

class OrbitShell extends StatefulWidget {
  const OrbitShell({
    super.key,
    this.connection,
    this.store,
    this.savedConnectionStore,
    this.activeConnectionId,
    this.onConnectionsChanged,
    this.autoRefreshInterval = const Duration(seconds: 30),
  });

  final ClusterConnection? connection;
  final SnapshotStore? store;
  final SavedConnectionStore? savedConnectionStore;
  final String? activeConnectionId;
  final VoidCallback? onConnectionsChanged;

  /// How often to silently re-fetch the current cluster's snapshot.
  /// Set to `null` or `Duration.zero` to disable. Tests pass `null` so
  /// widget fakes aren't chattier than needed.
  final Duration? autoRefreshInterval;

  @override
  State<OrbitShell> createState() => _OrbitShellState();
}

class _OrbitShellState extends State<OrbitShell> {
  int _index = 0;
  late final ClusterSessionController _session;

  static const _destinations = [
    NavigationDestination(icon: Icon(Icons.blur_on_outlined), label: 'Map'),
    NavigationDestination(
      icon: Icon(Icons.inventory_2_outlined),
      label: 'Resources',
    ),
    NavigationDestination(
        icon: Icon(Icons.alt_route_outlined), label: 'Changes'),
    NavigationDestination(
      icon: Icon(Icons.warning_amber_outlined),
      label: 'Alerts',
    ),
    NavigationDestination(
        icon: Icon(Icons.settings_outlined), label: 'Settings'),
  ];

  static const _titles = [
    'Cluster Map',
    'Resources',
    'Changes',
    'Alerts',
    'Settings',
  ];

  @override
  void initState() {
    super.initState();
    _session = ClusterSessionController(
      connection:
          widget.connection ?? ClusterConnectionFactory.fromEnvironment(),
      store: widget.store ?? SqfliteSnapshotStore(),
      autoRefreshInterval: widget.autoRefreshInterval,
    );
    _session.bootstrap();
  }

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  Future<void> _onRefresh() async {
    final error = await _session.refresh();
    if (!mounted || error == null) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(error)));
  }

  List<Widget> _buildScreens() {
    return [
      TopologyScreen(
        snapshot: _session.snapshot,
        isLoading: _session.isLoading,
        error: _session.loadError,
        connection: _session.connection,
        clusterId: _session.selectedCluster?.id,
        store: _session.store,
        onRefresh: _onRefresh,
      ),
      ResourcesScreen(
        snapshot: _session.snapshot,
        isLoading: _session.isLoading,
        error: _session.loadError,
        onRefresh: _onRefresh,
      ),
      ChangesScreen(
        snapshot: _session.snapshot,
        isLoading: _session.isLoading,
        error: _session.loadError,
        onRefresh: _onRefresh,
      ),
      AlertsScreen(
        snapshot: _session.snapshot,
        isLoading: _session.isLoading,
        error: _session.loadError,
        onRefresh: _onRefresh,
      ),
      SettingsScreen(
        savedConnectionStore: widget.savedConnectionStore,
        activeConnectionId: widget.activeConnectionId,
        onConnectionsChanged: widget.onConnectionsChanged,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _session,
      builder: (context, _) {
        final screenWidth = MediaQuery.sizeOf(context).width;
        final isTablet = screenWidth >= 960;
        final isCompact = screenWidth < 600;
        final palette = Theme.of(context).extension<ClusterOrbitPalette>()!;
        final screens = _buildScreens();
        final selectedCluster = _session.selectedCluster;
        final subtitle = selectedCluster != null
            ? '${selectedCluster.apiServerHost} / ${selectedCluster.environmentLabel}'
            : _session.loadError != null
                ? 'Connection failed'
                : _session.hasNoClusters
                    ? 'No clusters visible'
                    : 'Preparing ${_session.connection.mode.label.toLowerCase()} connection';

        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_titles[_index]),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.white.withValues(alpha: 0.68),
                      ),
                ),
              ],
            ),
            actions: [
              if (_session.isRefreshing) const _RefreshingBadge(),
              if (_session.lastRefreshedAt != null && !_session.isRefreshing)
                _LastRefreshedIndicator(
                  refreshedAt: _session.lastRefreshedAt!,
                  onRefresh: selectedCluster == null ? null : _onRefresh,
                  compact: isCompact,
                ),
              if (isCompact)
                IconButton(
                  tooltip: 'Switch cluster',
                  onPressed:
                      _session.clusters.isEmpty ? null : _session.cycleCluster,
                  icon: const Icon(Icons.hub_outlined),
                )
              else
                TextButton.icon(
                  onPressed:
                      _session.clusters.isEmpty ? null : _session.cycleCluster,
                  icon: const Icon(Icons.hub_outlined),
                  label: const Text('Switch Cluster'),
                ),
              const SizedBox(width: 8),
            ],
          ),
          body: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0.8, -0.9),
                radius: 1.5,
                colors: [
                  palette.canvasGlow.withValues(alpha: 0.18),
                  Colors.transparent,
                ],
              ),
            ),
            child: SafeArea(
              top: false,
              child: isTablet
                  ? _buildTabletLayout(context, screens)
                  : screens[_index],
            ),
          ),
          bottomNavigationBar: isTablet
              ? null
              : NavigationBar(
                  selectedIndex: _index,
                  destinations: _destinations,
                  onDestinationSelected: (value) =>
                      setState(() => _index = value),
                ),
        );
      },
    );
  }

  Widget _buildTabletLayout(BuildContext context, List<Widget> screens) {
    return Row(
      children: [
        SizedBox(
          width: 260,
          child: _SideRail(
            selectedIndex: _index,
            titles: _titles,
            clusterCount: _session.clusters.length,
            nodeCount: _session.snapshot?.nodes.length ?? 0,
            controlPlaneCount: _session.snapshot?.controlPlaneCount ?? 0,
            workerCount: _session.snapshot?.workerCount ?? 0,
            unschedulableCount: _session.snapshot?.unschedulableNodeCount ?? 0,
            alertCount: _session.snapshot?.alerts.length ?? 0,
            onChanged: (value) => setState(() => _index = value),
          ),
        ),
        Expanded(child: screens[_index]),
      ],
    );
  }
}

class _RefreshingBadge extends StatelessWidget {
  const _RefreshingBadge();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(
                Colors.white.withValues(alpha: 0.68),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Refreshing',
            style: theme.textTheme.bodySmall?.copyWith(
              color: Colors.white.withValues(alpha: 0.68),
            ),
          ),
        ],
      ),
    );
  }
}

class _LastRefreshedIndicator extends StatelessWidget {
  const _LastRefreshedIndicator({
    required this.refreshedAt,
    required this.onRefresh,
    this.compact = false,
  });

  final DateTime refreshedAt;
  final VoidCallback? onRefresh;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final relative = _formatRelative(refreshedAt);
    final tooltip = 'Updated $relative · tap to refresh';
    if (compact) {
      return IconButton(
        tooltip: tooltip,
        onPressed: onRefresh,
        icon: const Icon(Icons.refresh, size: 18),
      );
    }
    return Tooltip(
      message: tooltip,
      child: TextButton.icon(
        onPressed: onRefresh,
        icon: const Icon(Icons.refresh, size: 16),
        label: Text(
          'Updated $relative',
          style: theme.textTheme.bodySmall?.copyWith(
            color: Colors.white.withValues(alpha: 0.82),
          ),
        ),
        style: TextButton.styleFrom(
          foregroundColor: Colors.white.withValues(alpha: 0.82),
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }
}

String _formatRelative(DateTime past) {
  final delta = DateTime.now().difference(past);
  if (delta.inSeconds < 10) return 'just now';
  if (delta.inSeconds < 60) return '${delta.inSeconds}s ago';
  if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
  if (delta.inHours < 24) return '${delta.inHours}h ago';
  return '${delta.inDays}d ago';
}

class _SideRail extends StatelessWidget {
  const _SideRail({
    required this.selectedIndex,
    required this.titles,
    required this.clusterCount,
    required this.nodeCount,
    required this.controlPlaneCount,
    required this.workerCount,
    required this.unschedulableCount,
    required this.alertCount,
    required this.onChanged,
  });

  final int selectedIndex;
  final List<String> titles;
  final int clusterCount;
  final int nodeCount;
  final int controlPlaneCount;
  final int workerCount;
  final int unschedulableCount;
  final int alertCount;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          // Scrolls when the rail is taller than the pane (short tablets,
          // keyboard up, large text); otherwise the chips stay pinned low.
          child: LayoutBuilder(
            builder: (context, box) => SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: box.maxHeight),
                child: IntrinsicHeight(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('ClusterOrbit', style: theme.textTheme.titleLarge),
                      const SizedBox(height: 8),
                      Text(
                        'Machine-first cluster visibility with guarded operations.',
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 20),
                      for (var i = 0; i < titles.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: FilledButton.tonal(
                            onPressed: () => onChanged(i),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(52),
                              alignment: Alignment.centerLeft,
                              backgroundColor: i == selectedIndex
                                  ? theme.colorScheme.primary
                                      .withValues(alpha: 0.16)
                                  : Colors.white.withValues(alpha: 0.04),
                            ),
                            child: Text(titles[i]),
                          ),
                        ),
                      const Spacer(),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          Chip(label: Text('$clusterCount clusters')),
                          Chip(label: Text('$nodeCount nodes')),
                          Chip(
                            label: Text('$controlPlaneCount control planes'),
                          ),
                          Chip(label: Text('$workerCount workers')),
                          Chip(
                            label: Text('$unschedulableCount unschedulable'),
                          ),
                          Chip(label: Text('$alertCount alerts')),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
