import '../../core/cluster_domain/saved_connection.dart';

/// Builders for user-added [SavedConnection]s. Ids are timestamp-prefixed
/// (`sample-`, `gateway-`) so the connection kind is readable in the store.
SavedConnection newSampleConnection() => SavedConnection(
      id: 'sample-${DateTime.now().millisecondsSinceEpoch}',
      displayName: 'Sample data',
      kind: SavedConnectionKind.sample,
    );

/// Trims all inputs; a blank [token] becomes null (no auth header).
SavedConnection newGatewayConnection({
  required String displayName,
  required String url,
  String token = '',
}) {
  final trimmedToken = token.trim();
  return SavedConnection(
    id: 'gateway-${DateTime.now().millisecondsSinceEpoch}',
    displayName: displayName.trim(),
    kind: SavedConnectionKind.gateway,
    gatewayUrl: url.trim(),
    gatewayToken: trimmedToken.isEmpty ? null : trimmedToken,
  );
}
