import 'package:clusterorbit_mobile/core/connectivity/kubeconfig_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('KubeconfigDocument.parse', () {
    test('reads kubectl config view --raw output with column-0 list items', () {
      final document = KubeconfigDocument.parse('''
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: Y2EtYnl0ZXM=
    server: https://prod.example.internal:6443
  name: prod-cluster
- cluster:
    insecure-skip-tls-verify: true
    server: https://dev.example.internal:6443
  name: dev-cluster
contexts:
- context:
    cluster: prod-cluster
    namespace: kube-system
    user: prod-user
  name: prod-admin
kind: Config
current-context: prod-admin
users:
- name: prod-user
  user:
    client-certificate-data: Y2VydA==
    client-key-data: a2V5
    token: "abc123"
''');

      expect(document.currentContext, 'prod-admin');
      expect(document.clusters.map((c) => c.name), [
        'prod-cluster',
        'dev-cluster',
      ]);
      final prod = document.clusterByName['prod-cluster']!;
      expect(prod.server, 'https://prod.example.internal:6443');
      expect(prod.certificateAuthorityData, 'Y2EtYnl0ZXM=');
      expect(prod.insecureSkipTlsVerify, isFalse);
      expect(
          document.clusterByName['dev-cluster']!.insecureSkipTlsVerify, isTrue);

      final context = document.contextByName['prod-admin']!;
      expect(context.clusterName, 'prod-cluster');
      expect(context.namespace, 'kube-system');
      expect(context.userName, 'prod-user');

      final user = document.userByName['prod-user']!;
      expect(user.token, 'abc123');
      expect(user.clientCertificateData, 'Y2VydA==');
      expect(user.clientKeyData, 'a2V5');
    });

    test('reads indented list items and skips nameless entries', () {
      final document = KubeconfigDocument.parse('''
clusters:
  - cluster:
      server: https://a.example.internal
    name: a
  - cluster:
      server: https://nameless.example.internal
contexts:
  - context:
      cluster: a
    name: ctx
  - context:
      user: u
    name: no-cluster
''');

      expect(document.clusters.map((c) => c.name), ['a']);
      expect(document.contexts.map((c) => c.name), ['ctx']);
      expect(document.currentContext, isNull);
    });

    test('empty content yields an empty document', () {
      final document = KubeconfigDocument.parse('');

      expect(document.clusters, isEmpty);
      expect(document.contexts, isEmpty);
      expect(document.users, isEmpty);
    });

    test('throws on malformed YAML', () {
      expect(
        () => KubeconfigDocument.parse('clusters: [unterminated\n  - x: : y'),
        throwsFormatException,
      );
      expect(
        () => KubeconfigDocument.parse('just a string'),
        throwsFormatException,
      );
    });
  });
}
