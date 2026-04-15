import 'package:flutter/material.dart';

import '../../shared/widgets/feature_placeholder.dart';

class ChangesScreen extends StatelessWidget {
  const ChangesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const FeaturePlaceholder(
      title: 'Changes',
      description:
          'The changes view will track drafts, recent mutations, approvals, and rollback-friendly previews.',
      chips: [
        'Drafts',
        'Recent changes',
        'Approvals',
        'Audit trail',
      ],
    );
  }
}
