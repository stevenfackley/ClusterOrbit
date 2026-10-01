import 'dart:async';
import 'dart:io';

import 'gateway_cluster_connection.dart';
import 'kube_transport.dart';

/// Short text for showing [error] to people: a gateway or Kubernetes API
/// failure's `userMessage` (no URL, no raw JSON), a plain sentence for a
/// timeout or network failure, otherwise the error's own text.
String readableError(Object error) => switch (error) {
      GatewayException(:final userMessage) => userMessage,
      KubernetesApiException(:final userMessage) => userMessage,
      TimeoutException() => 'The server did not respond in time',
      SocketException() => 'Could not reach the server',
      HandshakeException() => 'TLS handshake with the server failed',
      _ => '$error',
    };
