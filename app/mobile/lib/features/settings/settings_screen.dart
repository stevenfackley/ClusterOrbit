import 'package:flutter/material.dart';

import '../../core/cluster_domain/saved_connection.dart';
import '../../core/sync_cache/snapshot_store.dart';
import '../../shared/widgets/feature_placeholder.dart';
import '../onboarding/onboarding_screen.dart';

/// Connection manager. Lists saved connections from [SavedConnectionStore]
/// and lets the user add (Gateway or Sample) or remove them. When the store
/// is null — the case for widget tests that never touch real persistence —
/// falls back to a placeholder card so the tab is still navigable.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.savedConnectionStore,
    this.activeConnectionId,
    this.onConnectionsChanged,
  });

  final SavedConnectionStore? savedConnectionStore;

  /// ID of the connection currently driving the shell. Used to render the
  /// "Active" chip so the user knows which one is live.
  final String? activeConnectionId;

  /// Called after any add/delete so the root gate can rebuild with the new
  /// active connection (or fall back to onboarding if the list is empty).
  final VoidCallback? onConnectionsChanged;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late Future<List<SavedConnection>> _savedFuture;

  @override
  void initState() {
    super.initState();
    _savedFuture = _load();
  }

  Future<List<SavedConnection>> _load() async {
    final store = widget.savedConnectionStore;
    if (store == null) return const [];
    return store.listConnections();
  }

  void _reload() {
    setState(() {
      _savedFuture = _load();
    });
  }

  Future<void> _onAdd(SavedConnection connection) async {
    await widget.savedConnectionStore!.saveConnection(connection);
    _reload();
    widget.onConnectionsChanged?.call();
  }

  Future<void> _onDelete(SavedConnection connection) async {
    await widget.savedConnectionStore!.deleteConnection(connection.id);
    _reload();
    widget.onConnectionsChanged?.call();
  }

  void _openAddGateway() {
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => AddGatewayScreen(onAddConnection: _onAdd),
      ),
    );
  }

  Future<void> _addSample() async {
    await _onAdd(
      SavedConnection(
        id: 'sample-${DateTime.now().millisecondsSinceEpoch}',
        displayName: 'Sample data',
        kind: SavedConnectionKind.sample,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.savedConnectionStore == null) {
      return const FeaturePlaceholder(
        title: 'Settings',
        description:
            'Cluster profiles, connection modes, caching, theme tuning, and security preferences will be managed here.',
        chips: ['Profiles', 'Gateway mode', 'SQLite cache', 'Security'],
      );
    }

    return FutureBuilder<List<SavedConnection>>(
      future: _savedFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return _ConnectionList(
          connections: snapshot.data!,
          activeId: widget.activeConnectionId,
          onAddGateway: _openAddGateway,
          onAddSample: _addSample,
          onDelete: _onDelete,
        );
      },
    );
  }
}

class _ConnectionList extends StatelessWidget {
  const _ConnectionList({
    required this.connections,
    required this.activeId,
    required this.onAddGateway,
    required this.onAddSample,
    required this.onDelete,
  });

  final List<SavedConnection> connections;
  final String? activeId;
  final VoidCallback onAddGateway;
  final VoidCallback onAddSample;
  final Future<void> Function(SavedConnection) onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 80),
      children: [
        Text('Connections', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(
          'The first connection in this list is the one driving the cluster map. '
          'Add more or remove ones you no longer need.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 20),
        if (connections.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                'No connections saved yet.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          )
        else
          for (final conn in connections)
            _ConnectionTile(
              connection: conn,
              isActive: conn.id == activeId,
              onDelete: () => _confirmDelete(context, conn),
            ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: onAddGateway,
                icon: const Icon(Icons.cloud_outlined),
                label: const Text('Add Gateway'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: onAddSample,
                icon: const Icon(Icons.science_outlined),
                label: const Text('Add Sample'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    SavedConnection conn,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove connection?'),
        content: Text(
          'Remove "${conn.displayName}"? Cached snapshot data for this '
          'connection stays on disk; you can re-add it later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await onDelete(conn);
    }
  }
}

class _ConnectionTile extends StatelessWidget {
  const _ConnectionTile({
    required this.connection,
    required this.isActive,
    required this.onDelete,
  });

  final SavedConnection connection;
  final bool isActive;
  final VoidCallback onDelete;

  IconData get _icon => switch (connection.kind) {
        SavedConnectionKind.sample => Icons.science_outlined,
        SavedConnectionKind.gateway => Icons.cloud_outlined,
        SavedConnectionKind.direct => Icons.vpn_key_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(_icon, size: 28, color: theme.colorScheme.primary),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          connection.displayName,
                          style: theme.textTheme.titleMedium,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isActive) ...[
                        const SizedBox(width: 8),
                        const Chip(
                          label: Text('Active'),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${connection.kind.label} · ${connection.subtitle}',
                    style: theme.textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Remove',
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }
}
