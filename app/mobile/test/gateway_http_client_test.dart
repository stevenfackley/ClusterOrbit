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

  group('DartIoGatewayHttpClient errors', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });
    tearDown(() => server.close(force: true));

    void answer(int status, String body) {
      server.listen((request) async {
        request.response
          ..statusCode = status
          ..write(body);
        await request.response.close();
      });
    }

    test('a 403 carries the status and the gateway error text', () async {
      answer(403, '{"error":"policy violation: replicas 9 exceed max 5"}');
      final url = Uri.parse('http://127.0.0.1:${server.port}/v1/clusters');

      await expectLater(
        const DartIoGatewayHttpClient()
            .postJson(url, body: const {'replicas': 9}),
        throwsA(isA<GatewayException>()
            .having((e) => e.statusCode, 'statusCode', 403)
            .having((e) => e.serverMessage, 'serverMessage',
                'policy violation: replicas 9 exceed max 5')
            .having((e) => e.userMessage, 'userMessage',
                'Not allowed by the gateway: policy violation: replicas 9 exceed max 5')
            .having((e) => e.message, 'message', contains('$url'))),
      );
    });

    test('a non-JSON 5xx body still yields a short message', () async {
      answer(502, '<html>Bad Gateway</html>');
      final url = Uri.parse('http://127.0.0.1:${server.port}/v1/clusters');

      await expectLater(
        const DartIoGatewayHttpClient().getJson(url),
        throwsA(isA<GatewayException>()
            .having((e) => e.statusCode, 'statusCode', 502)
            .having((e) => e.serverMessage, 'serverMessage', isNull)
            .having(
                (e) => e.userMessage, 'userMessage', 'Gateway error (502)')),
      );
    });
  });
}
