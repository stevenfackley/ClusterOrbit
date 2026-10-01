import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/cluster_domain/cluster_models.dart';
import '../../core/connectivity/cluster_connection.dart';

/// Polls `drainStatus` until the job reaches a terminal phase, showing live
/// evicted/skipped/remaining counts. The poll timer is tied to the dialog
/// lifecycle so it stops the moment the dialog is dismissed.
class DrainProgressDialog extends StatefulWidget {
  const DrainProgressDialog({
    super.key,
    required this.connection,
    required this.clusterId,
    required this.nodeName,
    required this.nodeId,
    required this.initialJob,
  });

  final ClusterConnection connection;
  final String clusterId;
  final String nodeName;
  final String nodeId;
  final DrainJob initialJob;

  @override
  State<DrainProgressDialog> createState() => _DrainProgressDialogState();
}

class _DrainProgressDialogState extends State<DrainProgressDialog> {
  static const _pollInterval = Duration(seconds: 2);

  late DrainJob _job = widget.initialJob;
  Timer? _timer;
  Object? _pollError;

  @override
  void initState() {
    super.initState();
    if (!_job.phase.isTerminal) {
      _timer = Timer.periodic(_pollInterval, (_) => unawaited(_poll()));
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    try {
      final next = await widget.connection.drainStatus(
        clusterId: widget.clusterId,
        nodeId: widget.nodeId,
        jobId: _job.id,
      );
      if (!mounted) return;
      setState(() {
        _job = next;
        _pollError = null;
      });
      if (next.phase.isTerminal) _timer?.cancel();
    } catch (e) {
      if (!mounted) return;
      // Transient poll failures shouldn't kill the dialog — keep polling and
      // surface the latest error so the user knows status may be stale.
      setState(() => _pollError = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final done = _job.phase.isTerminal;
    return AlertDialog(
      title: Text('Draining ${widget.nodeName}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (!done) ...[
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
              ],
              Text('Phase: ${_job.phase.label}',
                  style: theme.textTheme.bodyMedium),
            ],
          ),
          const SizedBox(height: 12),
          Text('Evicted: ${_job.evicted.length}'),
          Text('Skipped: ${_job.skipped.length}'),
          Text('Remaining: ${_job.remaining}'),
          if (_job.error != null && _job.error!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(_job.error!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error)),
          ],
          if (_pollError != null && !done) ...[
            const SizedBox(height: 8),
            Text('Status update failed; retrying…',
                style:
                    theme.textTheme.bodySmall?.copyWith(color: Colors.white54)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(done ? 'Close' : 'Run in background'),
        ),
      ],
    );
  }
}
