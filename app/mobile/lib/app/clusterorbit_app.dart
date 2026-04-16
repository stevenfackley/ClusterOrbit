import 'package:flutter/material.dart';

import '../core/connectivity/cluster_connection.dart';
import '../core/theme/clusterorbit_theme.dart';
import '../shared/widgets/orbit_shell.dart';

class ClusterOrbitApp extends StatelessWidget {
  const ClusterOrbitApp({
    super.key,
    this.connection,
  });

  final ClusterConnection? connection;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ClusterOrbit',
      debugShowCheckedModeBanner: false,
      theme: ClusterOrbitTheme.light(),
      darkTheme: ClusterOrbitTheme.dark(),
      themeMode: ThemeMode.dark,
      home: OrbitShell(connection: connection),
    );
  }
}
