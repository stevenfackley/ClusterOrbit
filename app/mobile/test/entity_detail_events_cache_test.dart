import 'dart:async';

import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/connectivity/cluster_connection.dart';
import 'package:clusterorbit_mobile/core/connectivity/sample_cluster_data.dart';
import 'package:clusterorbit_mobile/core/sync_cache/snapshot_store.dart';
import 'package:clusterorbit_mobile/core/theme/clusterorbit_theme.dart';
import 'package:clusterorbit_mobile/features/topology/topology_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
        theme: ClusterOrbitTheme.dark(),
        home: Scaffold(body: child),
      );

  testWidgets(
    'entity detail panel renders cached events immediately, then overwrites on live fetch',
    (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1400, 900);

      final profile =
          SampleClusterData.profilesFor(ConnectionMode.direct).first;
      final snapshot = SampleClusterData.snapshotFor(profile);

      final cached = [
        _event(reason: 'CachedReason', message: 'from cache'),
      ];
      final live = [
        _event(reason: 'LiveReason', message: 'from live'),
      ];

      final liveCompleter = Completer<List<ClusterEvent>>();
      final connection = _RecordingConnection(
        liveEventsFuture: liveCompleter.future,
      );
      final store = _MemoryStore(cached: {
        _cacheKey(
          profile.id,
          TopologyEntityKind.node,
          snapshot.nodes.first.name,
          null,
        ): cached,
      });

      await tester.pumpWidget(host(TopologyScreen(
        snapshot: snapshot,
        isLoading: false,
        error: null,
        connection: connection,
        clusterId: profile.id,
        store: store,
      )));
      await tester.pumpAndSettle();

      // Tap the first control-plane node to open the detail panel.
      await tester.tap(find.text(snapshot.nodes.first.name).first);
      // Pump once to let cache read resolve, but DO NOT settle (live fetch is pending).
      await tester.pump();
      await tester.pump();

      // Cached event should be visible BEFORE live fetch completes.
      expect(find.text('CachedReason'), findsOneWidget);
      expect(find.text('LiveReason'), findsNothing);

      // Complete the live fetch — cached rows should be replaced.
      liveCompleter.complete(live);
      await tester.pumpAndSettle();

      expect(find.text('LiveReason'), findsOneWidget);
      expect(find.text('CachedReason'), findsNothing);

      // Live events were saved back to cache.
      expect(
        store.saved[_cacheKey(
          profile.id,
          TopologyEntityKind.node,
          snapshot.nodes.first.name,
          null,
        )],
        isNotNull,
      );
      expect(
        store
            .saved[_cacheKey(
          profile.id,
          TopologyEntityKind.node,
          snapshot.nodes.first.name,
          null,
        )]!
            .first
            .reason,
        'LiveReason',
      );

      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      await tester.pump();
    },
  );

  testWidgets(
    'manual refresh button re-fetches live events',
    (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1400, 900);

      final profile =
          SampleClusterData.profilesFor(ConnectionMode.direct).first;
      final snapshot = SampleClusterData.snapshotFor(profile);

      final firstLive = [_event(reason: 'FirstLive', message: 'first')];
      final secondLive = [_event(reason: 'SecondLive', message: 'second')];

      int liveCalls = 0;
      final connection = _RecordingConnection.callback(
        onLoadEvents: () {
          liveCalls++;
          return Future.value(liveCalls == 1 ? firstLive : secondLive);
        },
      );
      final store = _MemoryStore();

      await tester.pumpWidget(host(TopologyScreen(
        snapshot: snapshot,
        isLoading: false,
        error: null,
        connection: connection,
        clusterId: profile.id,
        store: store,
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.text(snapshot.nodes.first.name).first);
      await tester.pumpAndSettle();
      expect(find.text('FirstLive'), findsOneWidget);
      expect(liveCalls, 1);

      // Tap the refresh button in the detail panel header.
      await tester.tap(find.byTooltip('Refresh events'));
      await tester.pumpAndSettle();

      expect(liveCalls, 2);
      expect(find.text('SecondLive'), findsOneWidget);
      expect(find.text('FirstLive'), findsNothing);

      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      await tester.pump();
    },
  );
}

ClusterEvent _event({required String reason, required String message}) {
  return ClusterEvent(
    type: ClusterEventType.normal,
    reason: reason,
    message: message,
    lastTimestamp: DateTime.now(),
    count: 1,
  );
}

String _cacheKey(
  String profileId,
  TopologyEntityKind kind,
  String objectName,
  String? namespace,
) =>
    '$profileId|${kind.name}|${namespace ?? ''}|$objectName';

final class _RecordingConnection implements ClusterConnection {
  _RecordingConnection({required Future<List<ClusterEvent>> liveEventsFuture})
      : _liveEventsFuture = liveEventsFuture,
        _onLoadEvents = null;

  _RecordingConnection.callback({
    required Future<List<ClusterEvent>> Function() onLoadEvents,
  })  : _liveEventsFuture = null,
        _onLoadEvents = onLoadEvents;

  final Future<List<ClusterEvent>>? _liveEventsFuture;
  final Future<List<ClusterEvent>> Function()? _onLoadEvents;
  final List<ClusterProfile> _profiles =
      SampleClusterData.profilesFor(ConnectionMode.direct);

  @override
  ConnectionMode get mode => ConnectionMode.direct;

  @override
  Future<List<ClusterProfile>> listClusters() async => _profiles;

  @override
  Future<ClusterSnapshot> loadSnapshot(String clusterId) async =>
      SampleClusterData.snapshotFor(_profiles.first);

  @override
  Stream<ClusterSnapshot> watchSnapshot(String clusterId) async* {
    yield await loadSnapshot(clusterId);
  }

  @override
  Future<List<ClusterEvent>> loadEvents({
    required String clusterId,
    required TopologyEntityKind kind,
    required String objectName,
    String? namespace,
    int limit = 5,
  }) {
    if (_onLoadEvents != null) return _onLoadEvents();
    return _liveEventsFuture!;
  }
}

final class _MemoryStore implements SnapshotStore {
  _MemoryStore({Map<String, List<ClusterEvent>>? cached})
      : cached = cached ?? {};

  final Map<String, List<ClusterEvent>> cached;
  final Map<String, List<ClusterEvent>> saved = {};

  @override
  Future<List<ClusterProfile>> loadProfiles({Duration? maxAge}) async =>
      const [];

  @override
  Future<void> saveProfiles(List<ClusterProfile> profiles) async {}

  @override
  Future<ClusterSnapshot?> loadSnapshot(
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
      cached[_cacheKey(profileId, kind, objectName, namespace)];

  @override
  Future<void> saveEvents({
    required String profileId,
    required TopologyEntityKind kind,
    required String objectName,
    String? namespace,
    required List<ClusterEvent> events,
  }) async {
    saved[_cacheKey(profileId, kind, objectName, namespace)] = events;
  }
}
