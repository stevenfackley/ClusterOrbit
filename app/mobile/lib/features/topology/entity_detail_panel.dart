import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/cluster_domain/cluster_models.dart';
import '../../core/connectivity/cluster_connection.dart';
import '../../core/sync_cache/snapshot_store.dart';
import '../../core/theme/clusterorbit_theme.dart';
import 'topology_orbs.dart';

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
  static const _pollInterval = Duration(seconds: 30);
  static const _eventCacheMaxAge = Duration(minutes: 5);

  List<ClusterEvent>? _events;
  bool _eventsSupported = false;
  bool _isLoadingEvents = false;
  bool _isRefreshingEvents = false;
  Object? _eventsError;
  Timer? _pollTimer;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _startLoadForCurrentEntity();
  }

  @override
  void didUpdateWidget(EntityDetailPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.entity, widget.entity) ||
        oldWidget.connection != widget.connection ||
        oldWidget.clusterId != widget.clusterId ||
        oldWidget.store != widget.store ||
        oldWidget.profileId != widget.profileId) {
      _startLoadForCurrentEntity();
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  void _startLoadForCurrentEntity() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _loadGeneration++;
    final generation = _loadGeneration;

    final connection = widget.connection;
    final clusterId = widget.clusterId;
    final ref = _entityRef(widget.entity);
    if (connection == null || clusterId == null || ref == null) {
      _events = null;
      _eventsSupported = false;
      _isLoadingEvents = false;
      _isRefreshingEvents = false;
      _eventsError = null;
      return;
    }

    _events = null;
    _eventsSupported = true;
    _isLoadingEvents = true;
    _isRefreshingEvents = false;
    _eventsError = null;

    unawaited(_loadEvents(generation: generation, ref: ref));

    _pollTimer = Timer.periodic(_pollInterval, (_) {
      if (!mounted) return;
      unawaited(_refreshLiveEvents(generation: generation, ref: ref));
    });
  }

  Future<void> _loadEvents({
    required int generation,
    required _EntityRef ref,
  }) async {
    final store = widget.store;
    final profileId = widget.profileId;

    if (store != null && profileId != null) {
      try {
        final cached = await store.loadEvents(
          profileId: profileId,
          kind: ref.kind,
          objectName: ref.name,
          namespace: ref.namespace,
          maxAge: _eventCacheMaxAge,
        );
        if (!mounted || generation != _loadGeneration) return;
        if (cached != null) {
          setState(() {
            _events = cached;
            _isLoadingEvents = false;
            _isRefreshingEvents = true;
            _eventsError = null;
          });
        }
      } catch (_) {
        // Cache read failure is non-fatal — fall through to live fetch.
      }
    }

    await _refreshLiveEvents(generation: generation, ref: ref);
  }

  Future<void> _refreshLiveEvents({
    required int generation,
    required _EntityRef ref,
  }) async {
    final connection = widget.connection;
    final clusterId = widget.clusterId;
    if (connection == null || clusterId == null) return;

    if (mounted && generation == _loadGeneration && _events != null) {
      setState(() => _isRefreshingEvents = true);
    }

    try {
      final events = await connection.loadEvents(
        clusterId: clusterId,
        kind: ref.kind,
        objectName: ref.name,
        namespace: ref.namespace,
      );
      if (!mounted || generation != _loadGeneration) return;

      final store = widget.store;
      final profileId = widget.profileId;
      if (store != null && profileId != null) {
        try {
          await store.saveEvents(
            profileId: profileId,
            kind: ref.kind,
            objectName: ref.name,
            namespace: ref.namespace,
            events: events,
          );
        } catch (_) {
          // Cache write failure is non-fatal.
        }
      }

      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _events = events;
        _isLoadingEvents = false;
        _isRefreshingEvents = false;
        _eventsError = null;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _isLoadingEvents = false;
        _isRefreshingEvents = false;
        if (_events == null) _eventsError = error;
      });
    }
  }

  void _onManualRefresh() {
    final ref = _entityRef(widget.entity);
    if (ref == null) return;
    unawaited(
      _refreshLiveEvents(generation: _loadGeneration, ref: ref),
    );
  }

  static _EntityRef? _entityRef(Object entity) => switch (entity) {
        ClusterNode n => _EntityRef(TopologyEntityKind.node, n.name, null),
        ClusterWorkload w =>
          _EntityRef(TopologyEntityKind.workload, w.name, w.namespace),
        ClusterService s =>
          _EntityRef(TopologyEntityKind.service, s.name, s.namespace),
        _ => null,
      };

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
              if (_eventsSupported)
                IconButton(
                  onPressed: _isLoadingEvents || _isRefreshingEvents
                      ? null
                      : _onManualRefresh,
                  icon:
                      const Icon(Icons.refresh, size: 18, color: Colors.white),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: 'Refresh events',
                ),
              if (_eventsSupported) const SizedBox(width: 8),
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
          if (_eventsSupported) ...[
            const SizedBox(height: 16),
            Divider(color: Colors.white.withValues(alpha: 0.12), height: 1),
            const SizedBox(height: 12),
            Row(
              children: [
                Text('Recent Events', style: theme.textTheme.titleSmall),
                if (_isRefreshingEvents) ...[
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
              isLoading: _isLoadingEvents,
              error: _eventsError,
              events: _events,
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
      if (widget.connection != null && widget.clusterId != null) ...[
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _ActionButton(
              icon: n.schedulable ? Icons.block : Icons.play_circle_outline,
              label: n.schedulable ? 'Cordon' : 'Uncordon',
              onPressed: () => _onCordonPressed(n),
            ),
            // Drain evicts pods via the gateway's async job API; direct and
            // sample connections don't implement it, so gate on gateway mode.
            if (widget.connection!.mode == ConnectionMode.gateway)
              _ActionButton(
                icon: Icons.cleaning_services_outlined,
                label: 'Drain',
                onPressed: () => _onDrainPressed(n),
              ),
          ],
        ),
      ],
    ];
  }

  Future<void> _onDrainPressed(ClusterNode n) async {
    final connection = widget.connection;
    final clusterId = widget.clusterId;
    if (connection == null || clusterId == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Drain ${n.name}?'),
        content: Text(
          'This cordons ${n.name} and evicts its pods (skipping DaemonSet, '
          'mirror, and completed pods). Evictions honor PodDisruptionBudgets '
          'and may take a while.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Drain'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.maybeOf(context);
    final DrainJob job;
    try {
      job = await connection.startDrain(clusterId: clusterId, nodeId: n.id);
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text('Drain failed: $e')));
      return;
    }
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _DrainProgressDialog(
        connection: connection,
        clusterId: clusterId,
        nodeName: n.name,
        nodeId: n.id,
        initialJob: job,
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

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$verb ${n.name}?'),
        content: Text(
          makeSchedulable
              ? 'This allows new pods to be scheduled on ${n.name}.'
              : 'This blocks new pods from scheduling on ${n.name}. '
                  'Running pods are not evicted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(verb),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await connection.setNodeSchedulable(
        clusterId: clusterId,
        nodeId: n.id,
        schedulable: makeSchedulable,
      );
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
              'Requested ${verb.toLowerCase()} of ${n.name}. Refresh to see applied state.'),
        ),
      );
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text('$verb failed: $e')),
      );
    }
  }

  List<Widget> _workloadFields(ClusterWorkload w, ThemeData theme) {
    final tint = healthTint(w.health, widget.palette);
    final isScalable =
        w.kind == WorkloadKind.deployment || w.kind == WorkloadKind.statefulSet;
    final isRestartable = isScalable || w.kind == WorkloadKind.daemonSet;
    final hasActions = (isScalable || isRestartable) &&
        widget.connection != null &&
        widget.clusterId != null;
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
      if (hasActions) ...[
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (isScalable)
              _ActionButton(
                icon: Icons.tune,
                label: 'Scale',
                onPressed: () => _onScalePressed(w),
              ),
            if (isRestartable)
              _ActionButton(
                icon: Icons.restart_alt,
                label: 'Restart',
                onPressed: () => _onRestartPressed(w),
              ),
          ],
        ),
      ],
    ];
  }

  Future<void> _onRestartPressed(ClusterWorkload w) async {
    final connection = widget.connection;
    final clusterId = widget.clusterId;
    if (connection == null || clusterId == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Restart ${w.name}?'),
        content: Text(
          'This triggers a rolling restart of all pods in ${w.name}. '
          'Existing pods are replaced gradually.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Restart'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await connection.restartWorkload(
        clusterId: clusterId,
        workloadId: w.id,
      );
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
              'Requested rolling restart of ${w.name}. Refresh to see applied state.'),
        ),
      );
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Restart failed: $e')),
      );
    }
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

    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await connection.scaleWorkload(
        clusterId: clusterId,
        workloadId: w.id,
        replicas: replicas,
      );
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
              'Requested scale of ${w.name} to $replicas replica(s). Refresh to see applied state.'),
        ),
      );
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Scale failed: $e')),
      );
    }
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

class _EntityRef {
  const _EntityRef(this.kind, this.name, this.namespace);
  final TopologyEntityKind kind;
  final String name;
  final String? namespace;
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

/// Polls `drainStatus` until the job reaches a terminal phase, showing live
/// evicted/skipped/remaining counts. The poll timer is tied to the dialog
/// lifecycle so it stops the moment the dialog is dismissed.
class _DrainProgressDialog extends StatefulWidget {
  const _DrainProgressDialog({
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
  State<_DrainProgressDialog> createState() => _DrainProgressDialogState();
}

class _DrainProgressDialogState extends State<_DrainProgressDialog> {
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
