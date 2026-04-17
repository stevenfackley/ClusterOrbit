import 'package:flutter/material.dart';

import '../../core/cluster_domain/saved_connection.dart';

/// First-run landing. Shown whenever [SavedConnectionStore] is empty.
///
/// The goal is explicit intent: the user must pick how to connect rather
/// than silently getting sample data. This minimal version offers "Use
/// sample data" as a one-tap choice; task #18 will add the real Gateway
/// URL / token form and a paste-kubeconfig path.
class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key, required this.onAddConnection});

  final Future<void> Function(SavedConnection) onAddConnection;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Welcome to ClusterOrbit')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Connect a cluster',
                      style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  Text(
                    'ClusterOrbit needs an endpoint before it can show real data. '
                    'Pick one below — you can add more and switch between them from Settings.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 24),
                  _OptionCard(
                    icon: Icons.science_outlined,
                    title: 'Use sample data',
                    subtitle:
                        'Explore the UI with a built-in demo cluster. No network, no credentials.',
                    actionLabel: 'Use sample',
                    onPressed: _addSample,
                  ),
                  const SizedBox(height: 12),
                  const _OptionCard(
                    icon: Icons.cloud_outlined,
                    title: 'Connect to a Gateway',
                    subtitle:
                        'Point at a ClusterOrbit gateway URL with a shared token. Coming next.',
                    actionLabel: 'Add gateway',
                    onPressed: null,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _addSample() async {
    await onAddConnection(
      SavedConnection(
        id: 'sample-${DateTime.now().millisecondsSinceEpoch}',
        displayName: 'Sample data',
        kind: SavedConnectionKind.sample,
      ),
    );
  }
}

class _OptionCard extends StatelessWidget {
  const _OptionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.onPressed,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String actionLabel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, size: 32, color: theme.colorScheme.primary),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(subtitle, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(onPressed: onPressed, child: Text(actionLabel)),
          ],
        ),
      ),
    );
  }
}
