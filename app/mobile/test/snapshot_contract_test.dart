import 'dart:convert';
import 'dart:io';

import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/connectivity/kube_transport.dart';
import 'package:clusterorbit_mobile/core/connectivity/kubeconfig_repository.dart';
import 'package:clusterorbit_mobile/core/connectivity/kubernetes_snapshot_loader.dart';
import 'package:flutter_test/flutter_test.dart';

/// The snapshot contract, Direct mode's half. The gateway's transform.go and
/// this app's KubernetesSnapshotLoader must reduce the same Kubernetes lists
/// to the same snapshot: both read testdata/contract/snapshot-lists.json at
/// the repo root and compare what they build with
/// testdata/contract/snapshot.json, which the gateway's TestSnapshotContract
/// (contract_test.go) regenerates. profile and generatedAt depend on the
/// connection and the clock, so the contract leaves them out.
void main() {
  const server = 'https://cluster.example.internal:6443';
  final contract = '..${Platform.pathSeparator}..${Platform.pathSeparator}'
      'testdata${Platform.pathSeparator}contract${Platform.pathSeparator}';

  Map<String, dynamic> read(String name) =>
      jsonDecode(File('$contract$name').readAsStringSync())
          as Map<String, dynamic>;

  test('Direct mode builds the snapshot the gateway builds', () async {
    final lists = read('snapshot-lists.json');
    final loader = KubernetesSnapshotLoader(
      transport: _ContractTransport({
        for (final MapEntry(:key, :value) in lists.entries)
          '$server/$key': value as Map<String, dynamic>,
      }),
    );

    final snapshot = await loader.loadSnapshot(
      const KubeconfigResolvedCluster(
        profile: ClusterProfile(
          id: 'contract',
          name: 'contract',
          apiServerHost: 'cluster.example.internal',
          environmentLabel: 'Dev',
          connectionMode: ConnectionMode.direct,
        ),
        server: server,
        namespace: null,
        auth: KubeconfigAuth(
          bearerToken: null,
          basicUsername: null,
          basicPassword: null,
          clientCertificateData: null,
          clientKeyData: null,
        ),
        tls: KubeconfigTlsConfig(
          insecureSkipTlsVerify: false,
          certificateAuthorityData: null,
        ),
      ),
    );

    // Through JSON, so the comparison is between wire shapes.
    final got =
        jsonDecode(jsonEncode(snapshot.toJson())) as Map<String, dynamic>
          ..remove('profile')
          ..remove('generatedAt');
    final want = read('snapshot.json');

    expect(got.keys, unorderedEquals(want.keys));
    for (final key in want.keys) {
      expect(got[key], want[key], reason: key);
    }

    // And the gateway's snapshot, read the way the app reads it, is the same.
    final viaGateway = ClusterSnapshot.fromJson({
      ...want,
      'profile': snapshot.profile.toJson(),
      'generatedAt': 0,
    }).toJson()
      ..remove('profile')
      ..remove('generatedAt');
    expect(jsonDecode(jsonEncode(viaGateway)), got);
  });
}

/// Answers each LIST from the contract file and fails on anything else, so
/// the loader must fetch exactly the lists the gateway fetches.
final class _ContractTransport implements KubernetesTransport {
  _ContractTransport(this._lists);

  final Map<String, Map<String, dynamic>> _lists;

  @override
  Future<Map<String, dynamic>> getJson(KubernetesRequest request) async {
    final list = _lists[request.uri.toString()];
    if (list == null) {
      throw StateError('Not in the contract: ${request.uri}');
    }
    return list;
  }

  @override
  Future<Map<String, dynamic>> patchJson(
    KubernetesRequest request, {
    required String contentType,
    required List<int> body,
  }) async {
    throw UnimplementedError();
  }
}
