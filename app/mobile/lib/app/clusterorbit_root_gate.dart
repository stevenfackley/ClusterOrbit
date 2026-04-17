import 'package:flutter/material.dart';

import '../core/cluster_domain/saved_connection.dart';
import '../core/connectivity/cluster_connection_factory.dart';
import '../core/sync_cache/snapshot_store.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../shared/widgets/orbit_shell.dart';

/// Chooses between the onboarding flow and the main shell based on what the
/// user has saved in [SavedConnectionStore]. Kept in its own widget so the
/// shell's lifecycle (and its [ClusterSessionController]) is fully torn
/// down when the user swaps the active connection — preventing a stale
/// snapshot from bleeding into the new connection's data.
class ClusterOrbitRootGate extends StatefulWidget {
  const ClusterOrbitRootGate({
    super.key,
    required this.savedConnectionStore,
    required this.snapshotStore,
  });

  final SavedConnectionStore savedConnectionStore;
  final SnapshotStore snapshotStore;

  @override
  State<ClusterOrbitRootGate> createState() => _ClusterOrbitRootGateState();
}

class _ClusterOrbitRootGateState extends State<ClusterOrbitRootGate> {
  late Future<List<SavedConnection>> _savedFuture;

  @override
  void initState() {
    super.initState();
    _savedFuture = widget.savedConnectionStore.listConnections();
  }

  void _reload() {
    setState(() {
      _savedFuture = widget.savedConnectionStore.listConnections();
    });
  }

  Future<void> _onAddConnection(SavedConnection connection) async {
    await widget.savedConnectionStore.saveConnection(connection);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<SavedConnection>>(
      future: _savedFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final saved = snapshot.data!;
        if (saved.isEmpty) {
          return OnboardingScreen(onAddConnection: _onAddConnection);
        }
        final active = saved.first;
        return OrbitShell(
          key: ValueKey('shell:${active.id}'),
          connection: ClusterConnectionFactory.fromSavedConnection(active),
          store: widget.snapshotStore,
        );
      },
    );
  }
}
