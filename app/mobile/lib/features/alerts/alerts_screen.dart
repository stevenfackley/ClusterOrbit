import 'package:flutter/material.dart';

import '../../shared/widgets/feature_placeholder.dart';

class AlertsScreen extends StatelessWidget {
  const AlertsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const FeaturePlaceholder(
      title: 'Alerts',
      description:
          'Operational health summaries, node pressure, and prioritized issue overlays will be summarized in this area.',
      chips: [
        'Node pressure',
        'Workload risk',
        'Recent failures',
        'Health summary',
      ],
    );
  }
}
