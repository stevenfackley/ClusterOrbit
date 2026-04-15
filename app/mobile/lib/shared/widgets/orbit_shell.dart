import 'package:flutter/material.dart';

import '../../features/alerts/alerts_screen.dart';
import '../../features/changes/changes_screen.dart';
import '../../features/resources/resources_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/topology/topology_screen.dart';
import '../../core/theme/clusterorbit_theme.dart';

class OrbitShell extends StatefulWidget {
  const OrbitShell({super.key});

  @override
  State<OrbitShell> createState() => _OrbitShellState();
}

class _OrbitShellState extends State<OrbitShell> {
  int _index = 0;

  static const _destinations = [
    NavigationDestination(icon: Icon(Icons.blur_on_outlined), label: 'Map'),
    NavigationDestination(icon: Icon(Icons.inventory_2_outlined), label: 'Resources'),
    NavigationDestination(icon: Icon(Icons.alt_route_outlined), label: 'Changes'),
    NavigationDestination(icon: Icon(Icons.warning_amber_outlined), label: 'Alerts'),
    NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Settings'),
  ];

  static const _titles = ['Cluster Map', 'Resources', 'Changes', 'Alerts', 'Settings'];

  final List<Widget> _screens = const [
    TopologyScreen(),
    ResourcesScreen(),
    ChangesScreen(),
    AlertsScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final isTablet = MediaQuery.sizeOf(context).width >= 960;
    final palette = Theme.of(context).extension<ClusterOrbitPalette>()!;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_titles[_index]),
            Text(
              'clusterorbit.local / dev profile',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.white.withValues(alpha: 0.68),
                  ),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () {},
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
          child: isTablet ? _buildTabletLayout(context) : _screens[_index],
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

  Widget _buildTabletLayout(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 260,
          child: _SideRail(
            selectedIndex: _index,
            titles: _titles,
            onChanged: (value) => setState(() => _index = value),
          ),
        ),
        Expanded(child: _screens[_index]),
        const SizedBox(
          width: 360,
          child: _InspectorPanel(),
        ),
      ],
    );
  }
}

class _SideRail extends StatelessWidget {
  const _SideRail({
    required this.selectedIndex,
    required this.titles,
    required this.onChanged,
  });

  final int selectedIndex;
  final List<String> titles;
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
                children: const [
                  Chip(label: Text('3 clusters')),
                  Chip(label: Text('42 nodes')),
                  Chip(label: Text('5 alerts')),
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
  const _InspectorPanel();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                'This panel is reserved for node details, config diffs, logs, and guarded actions on tablet layouts.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 20),
              const _MetricTile(label: 'Control planes', value: '3'),
              const _MetricTile(label: 'Workers', value: '39'),
              const _MetricTile(label: 'Unschedulable', value: '1'),
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
