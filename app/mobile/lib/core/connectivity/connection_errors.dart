import 'gateway_cluster_connection.dart';
import 'kube_transport.dart';

/// Short text for showing [error] to people: a gateway or Kubernetes API
/// failure's `userMessage` (no URL, no raw JSON), otherwise its own text.
String readableError(Object error) => switch (error) {
      GatewayException(:final userMessage) => userMessage,
      KubernetesApiException(:final userMessage) => userMessage,
      _ => '$error',
    };
