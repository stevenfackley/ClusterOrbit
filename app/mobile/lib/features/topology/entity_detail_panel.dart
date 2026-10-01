import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/cluster_domain/cluster_models.dart';
import '../../core/connectivity/cluster_connection.dart';
import '../../core/connectivity/connection_errors.dart';
import '../../core/sync_cache/snapshot_store.dart';
import '../../core/theme/clusterorbit_theme.dart';
import 'drain_progress_dialog.dart';
import 'entity_events_controller.dart';
import 'topology_orbs.dart';
import 'topology_selection.dart';

/// Side panel that shows detail + live events for the selected topology entity.
class EntityDetailPanel extends StatefulWidget {
  const EntityDetailPanel({
    super.key,
    required this.entity,
    required this.palette,
    required this.onDismiss,
    required this.connection,
    required this.clusterId,
    this.store,
    this.profileId,
  });

  final Object entity;
  final ClusterOrbitPalette palette;
  final VoidCallback onDismiss;
  final ClusterConnection? connection;
  final String? clusterId;
  final SnapshotStore? store;
  final String? profileId;

  @override
  State<EntityDetailPanel> createState() => _EntityDetailPanelState();
}

class _EntityDetailPanelState extends State<EntityDetailPanel> {
  final EntityEventsController _events = EntityEventsController();

  /// The last mutation's outcome, shown above the action buttons. The
  /// SnackBar that also reports it can end up under a modal sheet.
  ({String message, _MutationOutcome outcome})? _lastActionResult;

  @override
  void initState() {
    super.initState();
    _loadEvents();
    _events.addListener(_onEventsChanged);
  }

  @override
  void didUpdateWidget(EntityDetailPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A refresh hands over a new object for the same entity: show its
    // fields, but keep the events and their polling.
    if (topologyEntityKey(oldWidget.entity) !=
            topologyEntityKey(widget.entity) ||
        oldWidget.connection != widget.connection ||
        oldWidget.clusterId != widget.clusterId ||
        oldWidget.store != widget.store ||
        oldWidget.profileId != widget.profileId) {
      _lastActionResult = null;
      _loadEvents();
    }
  }

  @override
  void dispose() {
    _events.dispose();
    super.dispose();
  }

  void _loadEvents() => _events.load(
        entity: widget.entity,
        connection: widget.connection,
        clusterId: widget.clusterId,
        store: widget.store,
        profileId: widget.profileId,
      );

  void _onEventsChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: widget.palette.panel.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.40),
            blurRadius: 24,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(child: _buildTitle(theme)),
              if (_events.isSupported)
                IconButton(
                  onPressed: _events.isLoading || _events.isRefreshing
                      ? null
                      : () => unawaited(_events.refresh()),
                  icon:
                      const Icon(Icons.refresh, size: 18, color: Colors.white),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: 'Refresh events',
                ),
              if (_events.isSupported) const SizedBox(width: 8),
              IconButton(
                onPressed: widget.onDismiss,
                icon: const Icon(Icons.close, size: 18, color: Colors.white),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                tooltip: 'Dismiss',
              ),
            ],
          ),
          const SizedBox(height: 12),
          ..._buildFields(theme),
          if (_events.isSupported) ...[
            const SizedBox(height: 16),
            Divider(color: Colors.white.withValues(alpha: 0.12), height: 1),
            const SizedBox(height: 12),
            Row(
              children: [
                Text('Recent Events', style: theme.textTheme.titleSmall),
                if (_events.isRefreshing) ...[
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        Colors.white.withValues(alpha: 0.60),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            _EventList(
              isLoading: _events.isLoading,
              error: _events.error,
              events: _events.events,
              palette: widget.palette,
            ),
          ],
        ],
      ),
    );
  }

  static String? _copyPayload(Object entity) => switch (entity) {
        ClusterNode n => n.name,
        ClusterWorkload w => '${w.namespace}/${w.name}',
        ClusterService s => '${s.namespace}/${s.name}',
        _ => null,
      };

  Future<void> _copyToClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text('Copied: $text'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Widget _buildTitle(ThemeData theme) {
    final (name, badge) = switch (widget.entity) {
      ClusterNode n => (n.name, n.role.label),
      ClusterWorkload w => (w.name, w.kind.label),
      ClusterService s => (s.name, s.exposure.label),
      _ => ('Unknown', ''),
    };
    final copyPayload = _copyPayload(widget.entity);
    return Row(
      children: [
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: copyPayload == null
                ? null
                : () => _copyToClipboard(copyPayload),
            child: Text(
              name,
              style: theme.textTheme.titleMedium,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              badge,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.white70),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildFields(ThemeData theme) => switch (widget.entity) {
        ClusterNode n => _nodeFields(n, theme),
        ClusterWorkload w => _workloadFields(w, theme),
        ClusterService s => _serviceFields(s, theme),
        _ => const [],
      };

  List<Widget> _nodeFields(ClusterNode n, ThemeData theme) {
    final tint = healthTint(n.health, widget.palette);
    return [
      _DetailRow(label: 'Role', value: n.role.label, theme: theme),
      _DetailRow(label: 'Zone', value: n.zone, theme: theme),
      _DetailRow(label: 'K8s Version', value: n.version, theme: theme),
      _DetailRow(label: 'OS', value: n.osImage, theme: theme),
      _DetailRow(label: 'CPU', value: n.cpuCapacity, theme: theme),
      _DetailRow(label: 'Memory', value: n.memoryCapacity, theme: theme),
      _DetailRow(label: 'Pod Count', value: '${n.podCount}', theme: theme),
      _DetailRow(
          label: 'Schedulable',
          value: n.schedulable ? 'Yes' : 'Cordoned',
          theme: theme),
      _DetailStatusRow(
          label: 'Health', value: n.health.name, tint: tint, theme: theme),
      ..._actions(theme, [
        if (_supports(ClusterOperation.cordon))
          _ActionButton(
            icon: n.schedulable ? Icons.block : Icons.play_circle_outline,
            label: n.schedulable ? 'Cordon' : 'Uncordon',
            onPressed: () => _onCordonPressed(n),
          ),
        if (_supports(ClusterOperation.drain))
          _ActionButton(
            icon: Icons.cleaning_services_outlined,
            label: 'Drain',
            onPressed: () => _onDrainPressed(n),
          ),
      ]),
    ];
  }

  /// Whether the connection can perform [op] on this panel's cluster.
  bool _supports(ClusterOperation op) =>
      widget.clusterId != null &&
      (widget.connection?.supportedOperations.contains(op) ?? false);

  /// The action buttons, under the last mutation's outcome. A connection
  /// that can't mutate anything (sample data) says so instead of offering
  /// actions that would only fail.
  List<Widget> _actions(ThemeData theme, List<Widget> buttons) {
    final connection = widget.connection;
    if (connection == null || widget.clusterId == null) return const [];
    if (connection.supportedOperations.isEmpty) {
      return [
        const SizedBox(height: 4),
        Text(
          'Actions are available on live connections',
          style: theme.textTheme.bodySmall?.copyWith(color: Colors.white60),
        ),
      ];
    }
    if (buttons.isEmpty) return const [];
    final result = _lastActionResult;
    return [
      const SizedBox(height: 4),
      if (result != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            result.message,
            style: theme.textTheme.bodySmall?.copyWith(
              color: switch (result.outcome) {
                _MutationOutcome.done => widget.palette.accentTeal,
                _MutationOutcome.awaitingApproval => widget.palette.warning,
                _MutationOutcome.failed => theme.colorScheme.error,
              },
            ),
          ),
        ),
      Wrap(spacing: 8, runSpacing: 8, children: buttons),
    ];
  }

  /// Asks before a mutation. False when declined, or when the panel went
  /// away meanwhile (another cluster or entity), so nothing runs.
  Future<bool> _confirm({
    required String title,
    required String body,
    required String action,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return confirmed == true && mounted;
  }

  /// Runs a confirmed mutation: the one place every mutation's outcome is
  /// decided and reported, inline above the actions and as a SnackBar. A
  /// mutation the gateway parked for approval is neither done nor failed.
  Future<void> _runMutation(
    String verb,
    Future<void> Function() op,
    String successMsg,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    ({String message, _MutationOutcome outcome}) result;
    try {
      await op();
      result = (message: successMsg, outcome: _MutationOutcome.done);
    } on ApprovalPendingException catch (e) {
      result = (
        message: 'Awaiting second-operator approval '
            '(request ${e.pending.id})',
        outcome: _MutationOutcome.awaitingApproval,
      );
    } catch (e) {
      result = (
        message: '$verb failed: ${readableError(e)}',
        outcome: _MutationOutcome.failed,
      );
    }
    messenger?.showSnackBar(SnackBar(content: Text(result.message)));
    if (mounted) setState(() => _lastActionResult = result);
  }

  Future<void> _onDrainPressed(ClusterNode n) async {
    final connection = widget.connection;
    final clusterId = widget.clusterId;
    if (connection == null || clusterId == null) return;

    final confirmed = await _confirm(
      title: 'Drain ${n.name}?',
      body: 'This cordons ${n.name} and evicts its pods (skipping DaemonSet, '
          'mirror, and completed pods). Evictions honor PodDisruptionBudgets '
          'and may take a while.',
      action: 'Drain',
    );
    if (!confirmed) return;

    // Stays null unless the drain really started: a parked or failed drain
    // has no job to follow.
    DrainJob? job;
    await _runMutation(
      'Drain',
      () async {
        job = await connection.startDrain(clusterId: clusterId, nodeId: n.id);
      },
      'Started draining ${n.name}.',
    );
    final started = job;
    if (started == null || !mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => DrainProgressDialog(
        connection: connection,
        clusterId: clusterId,
        nodeName: n.name,
        nodeId: n.id,
        initialJob: started,
      ),
    );
  }

  Future<void> _onCordonPressed(ClusterNode n) async {
    final connection = widget.connection;
    final clusterId = widget.clusterId;
    if (connection == null || clusterId == null) return;

    // Toggling: schedulable node → cordon (make unschedulable), and vice versa.
    final makeSchedulable = !n.schedulable;
    final verb = makeSchedulable ? 'Uncordon' : 'Cordon';

    final confirmed = await _confirm(
      title: '$verb ${n.name}?',
      body: makeSchedulable
          ? 'This allows new pods to be scheduled on ${n.name}.'
          : 'This blocks new pods from scheduling on ${n.name}. '
              'Running pods are not evicted.',
      action: verb,
    );
    if (!confirmed) return;

    await _runMutation(
      verb,
      () => connection.setNodeSchedulable(
        clusterId: clusterId,
        nodeId: n.id,
        schedulable: makeSchedulable,
      ),
      'Requested ${verb.toLowerCase()} of ${n.name}. Refresh to see applied state.',
    );
  }

  List<Widget> _workloadFields(ClusterWorkload w, ThemeData theme) {
    final tint = healthTint(w.health, widget.palette);
    final isScalable =
        w.kind == WorkloadKind.deployment || w.kind == WorkloadKind.statefulSet;
    final isRestartable = isScalable || w.kind == WorkloadKind.daemonSet;
    return [
      _DetailRow(label: 'Namespace', value: w.namespace, theme: theme),
      _DetailRow(label: 'Kind', value: w.kind.label, theme: theme),
      _DetailRow(
          label: 'Replicas',
          value: '${w.readyReplicas} / ${w.desiredReplicas} ready',
          theme: theme),
      _DetailRow(
          label: 'Nodes',
          value: '${w.nodeIds.length} placement(s)',
          theme: theme),
      for (final image in w.images)
        _DetailRow(label: 'Image', value: image, theme: theme),
      _DetailStatusRow(
          label: 'Health', value: w.health.name, tint: tint, theme: theme),
      if (isScalable || isRestartable)
        ..._actions(theme, [
          if (isScalable && _supports(ClusterOperation.scale))
            _ActionButton(
              icon: Icons.tune,
              label: 'Scale',
              onPressed: () => _onScalePressed(w),
            ),
          if (isRestartable && _supports(ClusterOperation.restart))
            _ActionButton(
              icon: Icons.restart_alt,
              label: 'Restart',
              onPressed: () => _onRestartPressed(w),
            ),
        ]),
    ];
  }

  Future<void> _onRestartPressed(ClusterWorkload w) async {
    final connection = widget.connection;
    final clusterId = widget.clusterId;
    if (connection == null || clusterId == null) return;

    final confirmed = await _confirm(
      title: 'Restart ${w.name}?',
      body: 'This triggers a rolling restart of all pods in ${w.name}. '
          'Existing pods are replaced gradually.',
      action: 'Restart',
    );
    if (!confirmed) return;

    await _runMutation(
      'Restart',
      () => connection.restartWorkload(clusterId: clusterId, workloadId: w.id),
      'Requested rolling restart of ${w.name}. Refresh to see applied state.',
    );
  }

  Future<void> _onScalePressed(ClusterWorkload w) async {
    final connection = widget.connection;
    final clusterId = widget.clusterId;
    if (connection == null || clusterId == null) return;

    final replicas = await showDialog<int>(
      context: context,
      builder: (ctx) => _ScaleDialog(
        workloadName: w.name,
        currentReplicas: w.desiredReplicas,
      ),
    );
    if (replicas == null || !mounted) return;

    await _runMutation(
      'Scale',
      () => connection.scaleWorkload(
        clusterId: clusterId,
        workloadId: w.id,
        replicas: replicas,
      ),
      'Requested scale of ${w.name} to $replicas replica(s). Refresh to see applied state.',
    );
  }

  List<Widget> _serviceFields(ClusterService s, ThemeData theme) {
    final tint = healthTint(s.health, widget.palette);
    return [
      _DetailRow(label: 'Namespace', value: s.namespace, theme: theme),
      _DetailRow(label: 'Exposure', value: s.exposure.label, theme: theme),
      if (s.clusterIp != null)
        _DetailRow(label: 'Cluster IP', value: s.clusterIp!, theme: theme),
      _DetailRow(
          label: 'Targets',
          value: '${s.targetWorkloadIds.length} workload(s)',
          theme: theme),
      for (final p in s.ports)
        _DetailRow(
          label: 'Port',
          value:
              '${p.port} → ${p.targetPort} / ${p.protocol}${p.name != null ? ' (${p.name})' : ''}',
          theme: theme,
        ),
      _DetailStatusRow(
          label: 'Health', value: s.health.name, tint: tint, theme: theme),
    ];
  }
}

enum _MutationOutcome { done, awaitingApproval, failed }

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
    required this.theme,
  });

  final String label;
  final String value;
  final ThemeData theme;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text('Copied: $value'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.white54),
            ),
          ),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onLongPress: () => _copy(context),
              child: Text(
                value,
                style: theme.textTheme.bodySmall?.copyWith(color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailStatusRow extends StatelessWidget {
  const _DetailStatusRow({
    required this.label,
    required this.value,
    required this.tint,
    required this.theme,
  });

  final String label;
  final String value;
  final Color tint;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.white54),
            ),
          ),
          StatusDot(color: tint),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(color: tint),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        backgroundColor: Colors.white.withValues(alpha: 0.08),
      ),
    );
  }
}

class _EventList extends StatelessWidget {
  const _EventList({
    required this.isLoading,
    required this.error,
    required this.events,
    required this.palette,
  });

  final bool isLoading;
  final Object? error;
  final List<ClusterEvent>? events;
  final ClusterOrbitPalette palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (isLoading && events == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (error != null && events == null) {
      return Text(
        'Could not load events',
        style: theme.textTheme.bodySmall?.copyWith(color: Colors.white60),
      );
    }
    final list = events ?? const <ClusterEvent>[];
    if (list.isEmpty) {
      return Text(
        'No recent events',
        style: theme.textTheme.bodySmall?.copyWith(color: Colors.white60),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final event in list)
          _EventRow(event: event, palette: palette, theme: theme),
      ],
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({
    required this.event,
    required this.palette,
    required this.theme,
  });

  final ClusterEvent event;
  final ClusterOrbitPalette palette;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final tint = event.type == ClusterEventType.warning
        ? palette.warning
        : palette.accentTeal;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: StatusDot(color: tint),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        event.reason,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: Colors.white),
                      ),
                    ),
                    Text(
                      _relativeTime(event.lastTimestamp),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: Colors.white54),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  event.message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: Colors.white70),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _relativeTime(DateTime ts) {
    final diff = DateTime.now().toUtc().difference(ts.toUtc());
    if (diff.inSeconds < 60) return '${diff.inSeconds}s';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    return '${diff.inDays}d';
  }
}

class _ScaleDialog extends StatefulWidget {
  const _ScaleDialog({
    required this.workloadName,
    required this.currentReplicas,
  });

  final String workloadName;
  final int currentReplicas;

  @override
  State<_ScaleDialog> createState() => _ScaleDialogState();
}

class _ScaleDialogState extends State<_ScaleDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: '${widget.currentReplicas}',
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final parsed = int.tryParse(_controller.text.trim());
    if (parsed == null || parsed < 0) {
      setState(() => _error = 'Enter a non-negative integer');
      return;
    }
    Navigator.of(context).pop(parsed);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Scale ${widget.workloadName}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Current replicas: ${widget.currentReplicas}'),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            keyboardType: TextInputType.number,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Desired replicas',
              errorText: _error,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Apply'),
        ),
      ],
    );
  }
}
