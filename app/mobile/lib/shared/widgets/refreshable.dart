import 'package:flutter/material.dart';

import '../../core/connectivity/connection_errors.dart';

/// Wraps [child] in a pull-to-refresh when [onRefresh] is provided.
class MaybeRefreshIndicator extends StatelessWidget {
  const MaybeRefreshIndicator({
    super.key,
    required this.onRefresh,
    required this.child,
  });

  final Future<void> Function()? onRefresh;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final refresh = onRefresh;
    if (refresh == null) return child;
    return RefreshIndicator(onRefresh: refresh, child: child);
  }
}

/// Body for a snapshot-backed screen that has no snapshot to show: a spinner
/// while loading, the load error when one failed, otherwise [emptyMessage].
/// The error and empty states scroll so pull-to-refresh can retry.
class NoSnapshotView extends StatelessWidget {
  const NoSnapshotView({
    super.key,
    required this.isLoading,
    required this.error,
    required this.onRefresh,
    required this.emptyMessage,
  });

  final bool isLoading;
  final Object? error;
  final Future<void> Function()? onRefresh;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = this.error;
    final reason = error == null ? '' : readableError(error);
    // Some messages already end in punctuation; don't double it.
    final stop = RegExp(r'[.!?]$').hasMatch(reason) ? '' : '.';
    final message = error == null
        ? emptyMessage
        : 'Could not load cluster: $reason$stop'
            '${onRefresh == null ? '' : ' Pull to retry.'}';
    return MaybeRefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 120),
          Text(
            message,
            style: Theme.of(context).textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
