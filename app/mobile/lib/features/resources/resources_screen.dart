import 'package:flutter/material.dart';

import '../../shared/widgets/feature_placeholder.dart';

class ResourcesScreen extends StatelessWidget {
  const ResourcesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const FeaturePlaceholder(
      title: 'Resources',
      description:
          'Resource details, config views, events, logs, and future diff-aware editing flows will live here.',
      chips: [
        'Configs',
        'Logs',
        'Events',
        'Diffs',
      ],
    );
  }
}
