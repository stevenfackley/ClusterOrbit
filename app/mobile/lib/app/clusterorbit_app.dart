import 'package:flutter/material.dart';

import '../core/connectivity/cluster_connection.dart';
import '../core/sync_cache/snapshot_store.dart';
import '../core/theme/clusterorbit_theme.dart';
import '../shared/widgets/orbit_shell.dart';

class ClusterOrbitApp extends StatelessWidget {
  const ClusterOrbitApp({
    super.key,
    this.connection,
    this.store,
  });

  final ClusterConnection? connection;
  final SnapshotStore? store;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ClusterOrbit',
      debugShowCheckedModeBanner: false,
      theme: ClusterOrbitTheme.light(),
      darkTheme: ClusterOrbitTheme.dark(),
      themeMode: ThemeMode.dark,
      home: OrbitShell(connection: connection, store: store),
    );
  }
}
