import 'package:flutter/material.dart';

import '../core/theme/clusterorbit_theme.dart';
import '../shared/widgets/orbit_shell.dart';

class ClusterOrbitApp extends StatelessWidget {
  const ClusterOrbitApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ClusterOrbit',
      debugShowCheckedModeBanner: false,
      theme: ClusterOrbitTheme.light(),
      darkTheme: ClusterOrbitTheme.dark(),
      themeMode: ThemeMode.dark,
      home: const OrbitShell(),
    );
  }
}
