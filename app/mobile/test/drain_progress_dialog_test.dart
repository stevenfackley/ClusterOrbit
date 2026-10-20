import 'dart:async';

import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/theme/clusterorbit_theme.dart';
import 'package:clusterorbit_mobile/features/topology/drain_progress_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

/// Drain status polling on the test's fake clock: one request at a time,
/// and a job whose status keeps failing is given up on.
void main() {
  DrainJob job(DrainPhase phase, {int remaining = 3}) => DrainJob(
        id: 'drain-1',
        nodeId: 'cp-1',
        phase: phase,
        evicted: const [],
        skipped: const [],
        remaining: remaining,
      );

  Future<void> pumpDialog(
    WidgetTester tester,
    RecordingClusterConnection connection, {
    DrainPhase phase = DrainPhase.running,
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: ClusterOrbitTheme.dark(),
      home: Scaffold(
        body: DrainProgressDialog(
          connection: connection,
          clusterId: 'dev-orbit',
          nodeName: 'cp-1.dev-orbit',
          nodeId: 'cp-1',
          initialJob: job(phase),
        ),
      ),
    ));
  }

  int polls(RecordingClusterConnection connection) =>
      connection.callsTo('drainStatus').length;

  const interval = Duration(seconds: 2);
  const lost = 'Lost track of drain job drain-1';
  const retrying = 'Status update failed; retrying…';

  testWidgets('asks for the next status only once the last one is answered',
      (tester) async {
    var answer = Completer<DrainJob>();
    final connection = RecordingClusterConnection()
      ..onDrainStatus = () => answer.future;
    await pumpDialog(tester, connection);

    await tester.pump(interval);
    expect(polls(connection), 1);
    // A slow answer: no requests pile up behind it.
    await tester.pump(interval * 5);
    expect(polls(connection), 1);

    answer.complete(job(DrainPhase.running, remaining: 1));
    answer = Completer();
    await tester.pump();
    expect(find.text('Remaining: 1'), findsOneWidget);
    await tester.pump(interval);
    expect(polls(connection), 2);

    answer.complete(job(DrainPhase.succeeded, remaining: 0));
    await tester.pump();
    expect(find.text('Phase: Drained'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
    await tester.pump(interval * 5);
    expect(polls(connection), 2);
  });

  testWidgets('gives up after five failed polls in a row', (tester) async {
    final connection = RecordingClusterConnection()
      ..onDrainStatus = () async => throw StateError('drain job not found');
    await pumpDialog(tester, connection);

    for (var i = 0; i < 4; i++) {
      await tester.pump(interval);
    }
    expect(polls(connection), 4);
    expect(find.text(retrying), findsOneWidget);
    expect(find.text(lost), findsNothing);
    expect(find.text('Run in background'), findsOneWidget);

    await tester.pump(interval);
    expect(polls(connection), 5);
    expect(find.text(lost), findsOneWidget);
    expect(find.text(retrying), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Close'), findsOneWidget);

    await tester.pump(const Duration(minutes: 1));
    expect(polls(connection), 5);
  });

  testWidgets('only consecutive failures count toward giving up',
      (tester) async {
    var fail = true;
    final connection = RecordingClusterConnection()
      ..onDrainStatus = () async {
        if (fail) throw StateError('gateway unavailable');
        return job(DrainPhase.running);
      };
    await pumpDialog(tester, connection);

    for (var i = 0; i < 4; i++) {
      await tester.pump(interval);
    }
    fail = false;
    await tester.pump(interval);
    fail = true;
    for (var i = 0; i < 4; i++) {
      await tester.pump(interval);
    }

    expect(polls(connection), 9);
    expect(find.text(lost), findsNothing);
    expect(find.text(retrying), findsOneWidget);

    await tester.pump(interval);
    expect(polls(connection), 10);
    expect(find.text(lost), findsOneWidget);
  });

  testWidgets('a job that is already finished is never polled', (tester) async {
    final connection = RecordingClusterConnection()
      ..onDrainStatus = () async => job(DrainPhase.succeeded);
    await pumpDialog(tester, connection, phase: DrainPhase.failed);

    await tester.pump(interval * 5);
    expect(polls(connection), 0);
    expect(find.text('Close'), findsOneWidget);
  });
}
