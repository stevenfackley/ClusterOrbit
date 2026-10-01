import 'dart:async';
import 'dart:io';

import 'package:clusterorbit_mobile/core/connectivity/gateway_cluster_connection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DartIoGatewayHttpClient timeouts', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });
    tearDown(() => server.close(force: true));

    Uri url() => Uri.parse('http://127.0.0.1:${server.port}/v1/clusters');

    test('a gateway that never answers times out', () async {
      server.listen((_) {});
      const client = DartIoGatewayHttpClient(
        responseTimeout: Duration(milliseconds: 200),
      );

      await expectLater(
        client.getJson(url()),
        throwsA(isA<TimeoutException>()),
      );
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('a body that stalls after the headers times out', () async {
      server.listen((request) {
        request.response
          ..statusCode = 200
          ..write('[');
        unawaited(request.response.flush());
      });
      const client = DartIoGatewayHttpClient(
        responseTimeout: Duration(milliseconds: 200),
      );

      await expectLater(
        client.postJson(url(), body: const {}),
        throwsA(isA<TimeoutException>()),
      );
    }, timeout: const Timeout(Duration(seconds: 10)));
  });
}
