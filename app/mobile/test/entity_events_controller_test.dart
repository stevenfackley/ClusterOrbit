import 'dart:async';

import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/connectivity/sample_cluster_data.dart';
import 'package:clusterorbit_mobile/core/sync_cache/snapshot_store.dart';
import 'package:clusterorbit_mobile/features/topology/entity_events_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

/// The cache-then-live-then-poll logic, without pumping a screen.
void main() {
  const clusterId = 'dev-orbit';
  final snapshot = SampleClusterData.snapshotFor(
      SampleClusterData.profilesFor(ConnectionMode.direct).first);
  final node = snapshot.nodes[0];
  final otherNode = snapshot.nodes[1];

  late EntityEventsController controller;
  setUp(() => controller = EntityEventsController());
  tearDown(() => controller.dispose());

  test('shows cached events until the live ones land, then caches those',
      () async {
    final cached = [_event('CachedReason')];
    final live = [_event('LiveReason')];
    final liveFetch = Completer<List<ClusterEvent>>();
    final connection = RecordingClusterConnection()
      ..onLoadEvents = () => liveFetch.future;
    final store = _EventStore({node.name: cached});

    controller.load(
      entity: node,
      connection: connection,
      clusterId: clusterId,
      store: store,
      profileId: clusterId,
    );
    expect(controller.isSupported, isTrue);
    expect(controller.isLoading, isTrue);
    expect(controller.events, isNull);

    await pumpEventQueue();
    expect(controller.events, cached);
    expect(controller.isLoading, isFalse);
    expect(controller.isRefreshing, isTrue);

    liveFetch.complete(live);
    await pumpEventQueue();
    expect(controller.events, live);
    expect(controller.isRefreshing, isFalse);
    expect(store.saved[node.name], live);
  });

  test('without a connection or cluster there is nothing to load', () async {
    final connection = RecordingClusterConnection();
    controller.load(entity: node, connection: connection, clusterId: null);

    expect(controller.isSupported, isFalse);
    expect(controller.isLoading, isFalse);
    await controller.refresh();
    expect(connection.calls, isEmpty);
  });

  test('a failed first load is an error; a failed refresh keeps the events',
      () async {
    final live = [_event('LiveReason')];
    Object? failure = StateError('offline');
    final connection = RecordingClusterConnection()
      ..onLoadEvents = () async {
        if (failure case final error?) throw error;
        return live;
      };

    controller.load(entity: node, connection: connection, clusterId: clusterId);
    await pumpEventQueue();
    expect(controller.error, isA<StateError>());
    expect(controller.events, isNull);
    expect(controller.isLoading, isFalse);

    failure = null;
    await controller.refresh();
    expect(controller.events, live);
    expect(controller.error, isNull);

    failure = StateError('offline again');
    await controller.refresh();
    expect(controller.events, live);
    expect(controller.error, isNull);
    expect(controller.isRefreshing, isFalse);
  });

  test("loading another entity drops the previous one's late response",
      () async {
    final slow = Completer<List<ClusterEvent>>();
    final connection = RecordingClusterConnection()
      ..onLoadEvents = () => slow.future;
    controller.load(entity: node, connection: connection, clusterId: clusterId);

    final other = [_event('OtherReason')];
    connection.onLoadEvents = () async => other;
    controller.load(
        entity: otherNode, connection: connection, clusterId: clusterId);
    await pumpEventQueue();
    expect(controller.events, other);

    slow.complete([_event('StaleReason')]);
    await pumpEventQueue();
    expect(controller.events, other);
  });

  // testWidgets only for its fake clock: nothing is pumped on screen.
  testWidgets('re-fetches every poll interval until disposed', (tester) async {
    final polling = EntityEventsController();
    final connection = RecordingClusterConnection();
    polling.load(entity: node, connection: connection, clusterId: clusterId);
    await tester.pump();
    expect(connection.callsTo('loadEvents'), hasLength(1));

    await tester.pump(polling.pollInterval);
    expect(connection.callsTo('loadEvents'), hasLength(2));

    polling.dispose();
    await tester.pump(polling.pollInterval * 3);
    expect(connection.callsTo('loadEvents'), hasLength(2));
  });
}

ClusterEvent _event(String reason) => ClusterEvent(
      type: ClusterEventType.normal,
      reason: reason,
      message: reason,
      lastTimestamp: DateTime.now(),
      count: 1,
    );

/// Events cached and saved by object name; nothing else is stored.
final class _EventStore implements SnapshotStore {
  _EventStore(this.cached);

  final Map<String, List<ClusterEvent>> cached;
  final Map<String, List<ClusterEvent>> saved = {};

  @override
  Future<List<ClusterEvent>?> loadEvents({
    required String profileId,
    required TopologyEntityKind kind,
    required String objectName,
    String? namespace,
    Duration? maxAge,
  }) async =>
      cached[objectName];

  @override
  Future<void> saveEvents({
    required String profileId,
    required TopologyEntityKind kind,
    required String objectName,
    String? namespace,
    required List<ClusterEvent> events,
  }) async {
    saved[objectName] = events;
  }

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
}
