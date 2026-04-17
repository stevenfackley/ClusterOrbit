import 'package:flutter/material.dart';

import '../core/connectivity/cluster_connection.dart';
import '../core/sync_cache/snapshot_store.dart';
import '../core/theme/clusterorbit_theme.dart';
import '../shared/widgets/orbit_shell.dart';
import 'clusterorbit_root_gate.dart';

class ClusterOrbitApp extends StatefulWidget {
  const ClusterOrbitApp({
    super.key,
    this.connection,
    this.store,
    this.savedConnectionStore,
  });

  /// When non-null, bypasses the root gate and mounts [OrbitShell] directly.
  /// Widget tests pass a deterministic [ClusterConnection] here so they
  /// never touch sqflite or the onboarding flow.
  final ClusterConnection? connection;
  final SnapshotStore? store;

  /// Optional override for the saved-connection persistence backend.
  /// Defaults to the sqflite store when null and [connection] is null.
  final SavedConnectionStore? savedConnectionStore;

  @override
  State<ClusterOrbitApp> createState() => _ClusterOrbitAppState();
}

class _ClusterOrbitAppState extends State<ClusterOrbitApp> {
  /// Lazy so widget tests that pass [connection] never trigger sqflite init.
  SqfliteSnapshotStore? _sqlite;
  SqfliteSnapshotStore get _sqliteLazy => _sqlite ??= SqfliteSnapshotStore();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ClusterOrbit',
      debugShowCheckedModeBanner: false,
      theme: ClusterOrbitTheme.light(),
      darkTheme: ClusterOrbitTheme.dark(),
      themeMode: ThemeMode.dark,
      home: widget.connection != null
          ? OrbitShell(connection: widget.connection, store: widget.store)
          : ClusterOrbitRootGate(
              savedConnectionStore: widget.savedConnectionStore ?? _sqliteLazy,
              snapshotStore: widget.store ?? _sqliteLazy,
            ),
    );
  }
}
