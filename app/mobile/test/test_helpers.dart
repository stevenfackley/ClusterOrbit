import 'dart:async';
import 'dart:ui';

import 'package:clusterorbit_mobile/app/clusterorbit_app.dart';
import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/cluster_domain/saved_connection.dart';
import 'package:clusterorbit_mobile/core/connectivity/cluster_connection.dart';
import 'package:clusterorbit_mobile/core/connectivity/sample_cluster_data.dart';
import 'package:clusterorbit_mobile/core/sync_cache/snapshot_store.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> pumpClusterOrbitApp(
  WidgetTester tester, {
  Size? size,
  ClusterConnection? connection,
}) async {
  if (size != null) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
  }

  await tester.pumpWidget(
    ClusterOrbitApp(
      connection: connection ?? TestClusterConnection(),
      store: const NoOpSnapshotStore(),
      autoRefreshInterval: null,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> resetTestSurface(WidgetTester tester) async {
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
  await tester.pump();
}

final class TestClusterConnection implements ClusterConnection {
  TestClusterConnection({
    List<ClusterEvent>? events,
    this.onScale,
    this.onRestart,
    this.onSetSchedulable,
  }) : _events = events;

  final List<ClusterEvent>? _events;
  final void Function(String clusterId, String workloadId, int replicas)?
      onScale;
  final void Function(String clusterId, String workloadId)? onRestart;
  final void Function(String clusterId, String nodeId, bool schedulable)?
      onSetSchedulable;
  final List<ClusterProfile> _profiles =
      SampleClusterData.profilesFor(ConnectionMode.direct);

  @override
  ConnectionMode get mode => ConnectionMode.direct;

  /// What a direct connection supports: everything but drain.
  @override
  Set<ClusterOperation> get supportedOperations => const {
        ClusterOperation.scale,
        ClusterOperation.restart,
        ClusterOperation.cordon,
      };

  @override
  Future<List<ClusterProfile>> listClusters() async => _profiles;

  @override
  Future<ClusterSnapshot> loadSnapshot(String clusterId) async {
    final profile = _profiles.firstWhere(
      (item) => item.id == clusterId,
      orElse: () => _profiles.first,
    );
    return SampleClusterData.snapshotFor(profile);
  }

  @override
  Future<List<ClusterEvent>> loadEvents({
    required String clusterId,
    required TopologyEntityKind kind,
    required String objectName,
    String? namespace,
    int limit = 5,
  }) async {
    if (_events != null) {
      return _events.take(limit).toList();
    }
    return SampleClusterData.eventsFor(kind: kind, objectName: objectName)
        .take(limit)
        .toList();
  }

  @override
  Future<void> scaleWorkload({
    required String clusterId,
    required String workloadId,
    required int replicas,
  }) async {
    onScale?.call(clusterId, workloadId, replicas);
  }

  @override
  Future<void> restartWorkload({
    required String clusterId,
    required String workloadId,
  }) async {
    onRestart?.call(clusterId, workloadId);
  }

  @override
  Future<void> setNodeSchedulable({
    required String clusterId,
    required String nodeId,
    required bool schedulable,
  }) async {
    onSetSchedulable?.call(clusterId, nodeId, schedulable);
  }

  @override
  Future<DrainJob> startDrain({
    required String clusterId,
    required String nodeId,
  }) async =>
      throw UnsupportedError('drain not supported in TestClusterConnection');

  @override
  Future<DrainJob> drainStatus({
    required String clusterId,
    required String nodeId,
    required String jobId,
  }) async =>
      throw UnsupportedError('drain not supported in TestClusterConnection');
}

/// No-op store used in widget tests — prevents any SQLite I/O during test runs.
final class NoOpSnapshotStore implements SnapshotStore {
  const NoOpSnapshotStore();

  @override
  Future<List<ClusterProfile>> loadProfiles({Duration? maxAge}) async =>
      const [];

  @override
  Future<void> saveProfiles(List<ClusterProfile> profiles) async {}

  @override
  Future<void> deleteProfiles(Iterable<String> ids) async {}

  @override
  Future<SnapshotCacheEntry?> loadSnapshotEntry(
    String profileId, {
    Duration? maxAge,
  }) async =>
      null;

  @override
  Future<void> saveSnapshot(ClusterSnapshot snapshot) async {}

  @override
  Future<List<ClusterEvent>?> loadEvents({
    required String profileId,
    required TopologyEntityKind kind,
    required String objectName,
    String? namespace,
    Duration? maxAge,
  }) async =>
      null;

  @override
  Future<void> saveEvents({
    required String profileId,
    required TopologyEntityKind kind,
    required String objectName,
    String? namespace,
    required List<ClusterEvent> events,
  }) async {}
}

/// In-memory [SavedConnectionStore] that honors the store contract: the list
/// is most-recently-touched first, so [saveConnection] inserts at index 0 and
/// the head is the active connection. Failure hooks let tests exercise error
/// paths without a real database.
final class InMemorySavedConnectionStore implements SavedConnectionStore {
  final List<SavedConnection> saved = [];

  /// Number of upcoming [listConnections] calls that throw.
  int failListings = 0;

  /// When true, [saveConnection] throws.
  bool failSaves = false;

  /// When set, [saveConnection] waits on it before writing.
  Completer<void>? saveGate;

  @override
  Future<List<SavedConnection>> listConnections() async {
    if (failListings > 0) {
      failListings--;
      throw StateError('db locked');
    }
    return List.of(saved);
  }

  @override
  Future<void> saveConnection(SavedConnection connection) async {
    if (failSaves) throw StateError('disk full');
    await saveGate?.future;
    saved.removeWhere((c) => c.id == connection.id);
    saved.insert(0, connection);
  }

  @override
  Future<void> deleteConnection(String id) async {
    saved.removeWhere((c) => c.id == id);
  }

  @override
  Future<void> setActiveConnection(String id) async {
    final idx = saved.indexWhere((c) => c.id == id);
    if (idx <= 0) return;
    final promoted = saved.removeAt(idx);
    saved.insert(0, promoted);
  }
}

/// Records every events load and mutation, cluster id included, so a test
/// can assert exactly what was asked of which cluster. Mutations change
/// nothing and succeed unless [mutationError] is set; drain works once
/// [drainJob] and [onDrainStatus] are set. Supports what a real connection
/// of [mode] does (drain only on the gateway) unless [supportedOperations]
/// says otherwise.
final class RecordingClusterConnection implements ClusterConnection {
  RecordingClusterConnection({
    this.mode = ConnectionMode.direct,
    Set<ClusterOperation>? supportedOperations,
  }) : supportedOperations = supportedOperations ??
            (mode == ConnectionMode.gateway
                ? ClusterOperation.values.toSet()
                : const {
                    ClusterOperation.scale,
                    ClusterOperation.restart,
                    ClusterOperation.cordon,
                  });

  @override
  final ConnectionMode mode;

  @override
  final Set<ClusterOperation> supportedOperations;

  /// Every call after the snapshot loads, as `[method, clusterId, ...args]`.
  final List<List<Object?>> calls = [];

  /// Thrown by every mutation, after it is recorded, while set.
  Object? mutationError;

  /// Answers loadEvents while set, instead of the sample events.
  Future<List<ClusterEvent>> Function()? onLoadEvents;

  /// Returned by startDrain; drain is unsupported while null.
  DrainJob? drainJob;

  /// Answers drainStatus; unsupported while null.
  Future<DrainJob> Function()? onDrainStatus;

  final List<ClusterProfile> _profiles =
      SampleClusterData.profilesFor(ConnectionMode.direct);

  /// The recorded calls to [method].
  List<List<Object?>> callsTo(String method) =>
      calls.where((call) => call.first == method).toList();

  @override
  Future<List<ClusterProfile>> listClusters() async => _profiles;

  @override
  Future<ClusterSnapshot> loadSnapshot(String clusterId) async =>
      SampleClusterData.snapshotFor(
        _profiles.firstWhere(
          (item) => item.id == clusterId,
          orElse: () => _profiles.first,
        ),
      );

  @override
  Future<List<ClusterEvent>> loadEvents({
    required String clusterId,
    required TopologyEntityKind kind,
    required String objectName,
    String? namespace,
    int limit = 5,
  }) async {
    calls.add(['loadEvents', clusterId, kind, objectName]);
    final onLoadEvents = this.onLoadEvents;
    if (onLoadEvents != null) return onLoadEvents();
    return SampleClusterData.eventsFor(kind: kind, objectName: objectName)
        .take(limit)
        .toList();
  }

  @override
  Future<void> scaleWorkload({
    required String clusterId,
    required String workloadId,
    required int replicas,
  }) async {
    calls.add(['scaleWorkload', clusterId, workloadId, replicas]);
    if (mutationError case final error?) throw error;
  }

  @override
  Future<void> restartWorkload({
    required String clusterId,
    required String workloadId,
  }) async {
    calls.add(['restartWorkload', clusterId, workloadId]);
    if (mutationError case final error?) throw error;
  }

  @override
  Future<void> setNodeSchedulable({
    required String clusterId,
    required String nodeId,
    required bool schedulable,
  }) async {
    calls.add(['setNodeSchedulable', clusterId, nodeId, schedulable]);
    if (mutationError case final error?) throw error;
  }

  @override
  Future<DrainJob> startDrain({
    required String clusterId,
    required String nodeId,
  }) async {
    calls.add(['startDrain', clusterId, nodeId]);
    if (mutationError case final error?) throw error;
    return drainJob ?? (throw UnsupportedError('drain not supported'));
  }

  @override
  Future<DrainJob> drainStatus({
    required String clusterId,
    required String nodeId,
    required String jobId,
  }) async {
    calls.add(['drainStatus', clusterId, nodeId, jobId]);
    final onDrainStatus = this.onDrainStatus;
    if (onDrainStatus == null) throw UnsupportedError('drain not supported');
    return onDrainStatus();
  }
}

/// A fresh copy of [snapshot], new objects throughout, as a refresh delivers
/// it: optionally with node [cordon] unschedulable or node [drop] removed.
ClusterSnapshot refreshedSnapshot(
  ClusterSnapshot snapshot, {
  String? cordon,
  String? drop,
}) {
  final json = snapshot.toJson();
  final nodes = json['nodes'] as List;
  nodes.removeWhere((node) => node['id'] == drop);
  for (final node in nodes) {
    if (node['id'] == cordon) node['schedulable'] = false;
  }
  return ClusterSnapshot.fromJson(json);
}
