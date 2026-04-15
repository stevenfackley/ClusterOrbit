import 'package:flutter/material.dart';

import '../../shared/widgets/feature_placeholder.dart';

class TopologyScreen extends StatelessWidget {
  const TopologyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const FeaturePlaceholder(
      title: 'Cluster Map',
      description:
          'This placeholder represents the future machine-first topology canvas with grouped nodes, overlays, and tablet-scale navigation.',
      chips: [
        'Machine-first',
        'Fast pan/zoom',
        'Grouping modes',
        'Orbit visual language',
      ],
    );
  }
}
