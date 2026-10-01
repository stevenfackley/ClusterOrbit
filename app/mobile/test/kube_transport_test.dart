import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clusterorbit_mobile/core/connectivity/kube_transport.dart';
import 'package:clusterorbit_mobile/core/connectivity/kubeconfig_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('HttpKubernetesTransport timeouts', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });
    tearDown(() => server.close(force: true));

    test('a server that never answers times out', () async {
      server.listen((_) {});
      const transport = HttpKubernetesTransport(
        responseTimeout: Duration(milliseconds: 200),
      );

      await expectLater(
        transport.getJson(_request(server)),
        throwsA(isA<TimeoutException>()),
      );
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('a body that stalls after the headers times out', () async {
      server.listen((request) {
        request.response
          ..statusCode = 200
          ..write('{"items": [');
        unawaited(request.response.flush());
      });
      const transport = HttpKubernetesTransport(
        responseTimeout: Duration(milliseconds: 200),
      );

      await expectLater(
        transport.getJson(_request(server)),
        throwsA(isA<TimeoutException>()),
      );
    }, timeout: const Timeout(Duration(seconds: 10)));
  });

  test('an API error carries the status and the Status message', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response
        ..statusCode = 403
        ..write(jsonEncode({
          'kind': 'Status',
          'status': 'Failure',
          'message': 'nodes "worker-1" is forbidden: User "dev" cannot patch',
          'reason': 'Forbidden',
          'code': 403,
        }));
      await request.response.close();
    });

    await expectLater(
      const HttpKubernetesTransport().getJson(_request(server)),
      throwsA(isA<HttpException>()
          .having((e) => (e as KubernetesApiException).statusCode, 'statusCode',
              403)
          .having(
              (e) => (e as KubernetesApiException).userMessage,
              'userMessage',
              'Forbidden by the cluster: nodes "worker-1" is forbidden: '
                  'User "dev" cannot patch')),
    );
  });

  test('a client certificate without a CA keeps the system trust roots', () {
    final trustedRoots = <bool>[];
    SecurityContext record({bool withTrustedRoots = false}) {
      trustedRoots.add(withTrustedRoots);
      return SecurityContext(withTrustedRoots: withTrustedRoots);
    }

    final clientCert = KubeconfigAuth(
      bearerToken: null,
      basicUsername: null,
      basicPassword: null,
      clientCertificateData: utf8.encode(_certPem),
      clientKeyData: utf8.encode(_keyPem),
    );

    kubeSecurityContext(
      const KubeconfigTlsConfig(
        insecureSkipTlsVerify: false,
        certificateAuthorityData: null,
      ),
      clientCert,
      create: record,
    );
    kubeSecurityContext(
      KubeconfigTlsConfig(
        insecureSkipTlsVerify: false,
        certificateAuthorityData: utf8.encode(_certPem),
      ),
      clientCert,
      create: record,
    );

    // Only an explicit CA replaces the platform trust store.
    expect(trustedRoots, [true, false]);
  });
}

KubernetesRequest _request(HttpServer server) => KubernetesRequest(
      uri: Uri.parse('http://127.0.0.1:${server.port}/api/v1/nodes'),
      auth: const KubeconfigAuth(
        bearerToken: null,
        basicUsername: null,
        basicPassword: null,
        clientCertificateData: null,
        clientKeyData: null,
      ),
      tls: const KubeconfigTlsConfig(
        insecureSkipTlsVerify: false,
        certificateAuthorityData: null,
      ),
    );

// Throwaway self-signed P-256 pair; only parsed, never used on the wire.
const _certPem = '''
-----BEGIN CERTIFICATE-----
MIIBjjCCATWgAwIBAgIUPufJIaGMBpdVTgTXz8RuwA4uPrcwCgYIKoZIzj0EAwIw
HDEaMBgGA1UEAwwRY2x1c3Rlcm9yYml0LXRlc3QwIBcNMjYxMDAxMTI0OTU4WhgP
MjEyNjA5MDcxMjQ5NThaMBwxGjAYBgNVBAMMEWNsdXN0ZXJvcmJpdC10ZXN0MFkw
EwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEUydM1N1qxMytcD0SFjJSN8Ezb/8cXqcm
Xz3H4sYs7m7vGTnnooq4DeH3Cmhdd//kUlRTTBkOnDFBVt/VHn4l/qNTMFEwHQYD
VR0OBBYEFHGrW58iRFaXaCoF9SGonGMoCbmFMB8GA1UdIwQYMBaAFHGrW58iRFaX
aCoF9SGonGMoCbmFMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDRwAwRAIg
NoaHomv9/ZmLcMVrz8co6iLu1hMuqG4uDwld1mIu1sYCIGq70cTULZmQWBH/2pCv
A0taZ4ePzJ7bk898CfwCaaP1
-----END CERTIFICATE-----
''';

const _keyPem = '''
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgxWmyFFw94IhmttOZ
3OfM9RCRFiNQLVyuLqUgrGu54CuhRANCAARTJ0zU3WrEzK1wPRIWMlI3wTNv/xxe
pyZfPcfixizubu8ZOeeiirgN4fcKaF13/+RSVFNMGQ6cMUFW39UefiX+
-----END PRIVATE KEY-----
''';
