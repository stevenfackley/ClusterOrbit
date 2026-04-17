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

class OrbitShell extends StatefulWidget {
  const OrbitShell({
    super.key,
    this.connection,
    this.store,
  });

  final ClusterConnection? connection;
  final SnapshotStore? store;

  @override
  State<OrbitShell> createState() => _OrbitShellState();
}

class _OrbitShellState extends State<OrbitShell> {
  static const _cacheMaxAge = Duration(minutes: 10);

  int _index = 0;
  late final ClusterConnection _connection;
  late final SnapshotStore _store;
  List<ClusterProfile> _clusters = const [];
  ClusterProfile? _selectedCluster;
  ClusterSnapshot? _snapshot;
  Object? _loadError;
  bool _isLoading = true;
  bool _isRefreshing = false;

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
    _connection =
        widget.connection ?? ClusterConnectionFactory.fromEnvironment();
    _store = widget.store ?? SqfliteSnapshotStore();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    // Show cached data immediately, then fetch live in the background.
    bool cacheShown = false;

    try {
      final cachedProfiles = await _store.loadProfiles(maxAge: _cacheMaxAge);
      if (cachedProfiles.isNotEmpty) {
        final cachedSnapshot = await _store.loadSnapshot(
          cachedProfiles.first.id,
          maxAge: _cacheMaxAge,
        );
        if (cachedSnapshot != null && mounted) {
          setState(() {
            _clusters = cachedProfiles;
            _selectedCluster = cachedProfiles.first;
            _snapshot = cachedSnapshot;
            _loadError = null;
            _isLoading = false;
            _isRefreshing = true;
          });
          cacheShown = true;
        }
      }
    } catch (_) {
      // Cache read failure is non-fatal — fall through to live fetch.
    }

    try {
      final clusters = await _connection.listClusters();
      if (clusters.isEmpty) {
        if (mounted) setState(() => _isRefreshing = false);
        return;
      }

      final selectedCluster = clusters.first;
      final snapshot = await _connection.loadSnapshot(selectedCluster.id);

      // Save to cache regardless of mount status — cache is process-scoped.
      await _store.saveProfiles(clusters);
      await _store.saveSnapshot(snapshot);

      if (!mounted) return;

      setState(() {
        _clusters = clusters;
        _selectedCluster = selectedCluster;
        _snapshot = snapshot;
        _loadError = null;
        _isLoading = false;
        _isRefreshing = false;
      });
    } catch (error) {
      if (!mounted) return;

      if (cacheShown) {
        // Cache is visible; swallow the live-fetch error silently.
        setState(() => _isRefreshing = false);
        return;
      }

      setState(() {
        _loadError = error;
        _isLoading = false;
        _isRefreshing = false;
      });
    }
  }

  Future<void> _cycleCluster() async {
    if (_clusters.length < 2 || _isLoading || _selectedCluster == null) {
      return;
    }

    final currentIndex = _clusters.indexOf(_selectedCluster!);
    final nextCluster = _clusters[(currentIndex + 1) % _clusters.length];

    setState(() {
      _isLoading = true;
      _selectedCluster = nextCluster;
    });

    // Show cached snapshot for the target cluster immediately if available.
    bool cacheShown = false;
    try {
      final cachedSnapshot = await _store.loadSnapshot(
        nextCluster.id,
        maxAge: _cacheMaxAge,
      );
      if (cachedSnapshot != null && mounted) {
        setState(() {
          _snapshot = cachedSnapshot;
          _loadError = null;
          _isLoading = false;
          _isRefreshing = true;
        });
        cacheShown = true;
      }
    } catch (_) {
      // Non-fatal — fall through to live fetch.
    }

    try {
      final snapshot = await _connection.loadSnapshot(nextCluster.id);
      await _store.saveSnapshot(snapshot);

      if (!mounted) return;

      setState(() {
        _snapshot = snapshot;
        _loadError = null;
        _isLoading = false;
        _isRefreshing = false;
      });
    } catch (error) {
      if (!mounted) return;

      if (cacheShown) {
        setState(() => _isRefreshing = false);
        return;
      }

      setState(() {
        _loadError = error;
        _isLoading = false;
        _isRefreshing = false;
      });
    }
  }

  List<Widget> _buildScreens() {
    return [
      TopologyScreen(
        snapshot: _snapshot,
        isLoading: _isLoading,
        error: _loadError,
        connection: _connection,
        clusterId: _selectedCluster?.id,
      ),
      const ResourcesScreen(),
      const ChangesScreen(),
      const AlertsScreen(),
      const SettingsScreen(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final isTablet = MediaQuery.sizeOf(context).width >= 960;
    final palette = Theme.of(context).extension<ClusterOrbitPalette>()!;
    final screens = _buildScreens();
    final subtitle = _selectedCluster == null
        ? 'Preparing ${_connection.mode.label.toLowerCase()} connection'
        : '${_selectedCluster!.apiServerHost} / ${_selectedCluster!.environmentLabel}';

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
          if (_isRefreshing) const _RefreshingBadge(),
          TextButton.icon(
            onPressed: _clusters.isEmpty ? null : _cycleCluster,
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
          child:
              isTablet ? _buildTabletLayout(context, screens) : screens[_index],
        ),
      ),
      bottomNavigationBar: isTablet
          ? null
          : NavigationBar(
              selectedIndex: _index,
              destinations: _destinations,
              onDestinationSelected: (value) => setState(() => _index = value),
            ),
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
            clusterCount: _clusters.length,
            nodeCount: _snapshot?.nodes.length ?? 0,
            alertCount: _snapshot?.alerts.length ?? 0,
            onChanged: (value) => setState(() => _index = value),
          ),
        ),
        Expanded(child: screens[_index]),
        SizedBox(
          width: 360,
          child: _InspectorPanel(
            snapshot: _snapshot,
            isLoading: _isLoading,
          ),
        ),
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

class _SideRail extends StatelessWidget {
  const _SideRail({
    required this.selectedIndex,
    required this.titles,
    required this.clusterCount,
    required this.nodeCount,
    required this.alertCount,
    required this.onChanged,
  });

  final int selectedIndex;
  final List<String> titles;
  final int clusterCount;
  final int nodeCount;
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
                          ? theme.colorScheme.primary.withValues(alpha: 0.16)
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
                  Chip(label: Text('$alertCount alerts')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InspectorPanel extends StatelessWidget {
  const _InspectorPanel({
    required this.snapshot,
    required this.isLoading,
  });

  final ClusterSnapshot? snapshot;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controlPlanes = snapshot?.controlPlaneCount ?? 0;
    final workers = snapshot?.workerCount ?? 0;
    final unschedulable = snapshot?.unschedulableNodeCount ?? 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 20, 20, 20),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Inspector', style: theme.textTheme.titleLarge),
              const SizedBox(height: 12),
              Text(
                isLoading
                    ? 'Loading snapshot details for the selected cluster.'
                    : 'This panel is reserved for node details, config diffs, logs, and guarded actions on tablet layouts.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 20),
              _MetricTile(label: 'Control planes', value: '$controlPlanes'),
              _MetricTile(label: 'Workers', value: '$workers'),
              _MetricTile(label: 'Unschedulable', value: '$unschedulable'),
              const Spacer(),
              FilledButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.playlist_add_check_circle_outlined),
                label: const Text('Open change preview'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Text(label, style: theme.textTheme.bodyLarge),
          const Spacer(),
          Text(value, style: theme.textTheme.titleLarge),
        ],
      ),
    );
  }
}
