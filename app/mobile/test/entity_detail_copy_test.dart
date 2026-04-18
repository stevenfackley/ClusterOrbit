import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/theme/clusterorbit_theme.dart';
import 'package:clusterorbit_mobile/features/topology/entity_detail_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Verifies long-press on the entity title copies a useful payload to the
/// clipboard and surfaces a SnackBar. Exercises the "no connection" path so
/// we never have to stub ClusterConnection + event polling just to test
/// clipboard behavior.
void main() {
  const palette = ClusterOrbitPalette(
    canvasGlow: Color(0xFF0C0F1A),
    accentTeal: Color(0xFF14B8A6),
    accentCyan: Color(0xFF06B6D4),
    warning: Color(0xFFF59E0B),
    panel: Color(0xFF1A1F2E),
  );

  Widget host(Object entity) => MaterialApp(
        theme: ClusterOrbitTheme.dark(),
        home: Scaffold(
          body: EntityDetailPanel(
            entity: entity,
            palette: palette,
            onDismiss: () {},
            connection: null,
            clusterId: null,
          ),
        ),
      );

  setUp(() {
    // Clean clipboard between tests so assertions are unambiguous.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        _clipboardContents = (call.arguments as Map)['text'] as String?;
      }
      if (call.method == 'Clipboard.getData') {
        return {'text': _clipboardContents};
      }
      return null;
    });
    _clipboardContents = null;
  });

  testWidgets('long-press on node title copies node name', (tester) async {
    const node = ClusterNode(
      id: 'n-1',
      name: 'worker-0',
      role: ClusterNodeRole.worker,
      zone: 'us-east-1a',
      version: 'v1.28.2',
      osImage: 'Debian 12',
      cpuCapacity: '8 vCPU',
      memoryCapacity: '32 GiB',
      podCount: 12,
      schedulable: true,
      health: ClusterHealthLevel.healthy,
    );
    await tester.pumpWidget(host(node));
    await tester.longPress(find.text('worker-0'));
    await tester.pumpAndSettle();
    expect(_clipboardContents, 'worker-0');
    expect(find.textContaining('Copied: worker-0'), findsOneWidget);
  });

  testWidgets('long-press on workload title copies namespace/name',
      (tester) async {
    const workload = ClusterWorkload(
      id: 'w-1',
      name: 'api-server',
      namespace: 'prod',
      kind: WorkloadKind.deployment,
      desiredReplicas: 3,
      readyReplicas: 3,
      nodeIds: ['n-1'],
      images: ['app:1.0'],
      health: ClusterHealthLevel.healthy,
    );
    await tester.pumpWidget(host(workload));
    await tester.longPress(find.text('api-server'));
    await tester.pumpAndSettle();
    expect(_clipboardContents, 'prod/api-server');
    expect(find.textContaining('Copied: prod/api-server'), findsOneWidget);
  });

  testWidgets('long-press on service title copies namespace/name',
      (tester) async {
    const service = ClusterService(
      id: 's-1',
      name: 'payments',
      namespace: 'commerce',
      exposure: ServiceExposure.clusterIp,
      targetWorkloadIds: ['w-1'],
      ports: [],
      health: ClusterHealthLevel.healthy,
    );
    await tester.pumpWidget(host(service));
    await tester.longPress(find.text('payments'));
    await tester.pumpAndSettle();
    expect(_clipboardContents, 'commerce/payments');
    expect(find.textContaining('Copied: commerce/payments'), findsOneWidget);
  });
}

String? _clipboardContents;
