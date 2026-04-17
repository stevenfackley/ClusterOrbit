/// A user-configured connection — one row per saved target. The session
/// controller reads these at bootstrap to build the list of reachable
/// clusters. Distinct from [ClusterProfile], which is per-cluster
/// metadata returned by a live connection.
enum SavedConnectionKind {
  /// In-memory demo data. Useful for first-run and offline.
  sample,

  /// HTTP-backed gateway with token auth.
  gateway,

  /// Pasted kubeconfig YAML, parsed on-device.
  direct,
}

extension SavedConnectionKindLabel on SavedConnectionKind {
  String get label => switch (this) {
        SavedConnectionKind.sample => 'Sample data',
        SavedConnectionKind.gateway => 'Gateway',
        SavedConnectionKind.direct => 'Direct (kubeconfig)',
      };

  static SavedConnectionKind fromName(String name) => switch (name) {
        'gateway' => SavedConnectionKind.gateway,
        'direct' => SavedConnectionKind.direct,
        _ => SavedConnectionKind.sample,
      };
}

final class SavedConnection {
  const SavedConnection({
    required this.id,
    required this.displayName,
    required this.kind,
    this.gatewayUrl,
    this.gatewayToken,
    this.kubeconfigYaml,
    this.kubeconfigContext,
  });

  final String id;
  final String displayName;
  final SavedConnectionKind kind;

  /// Gateway-mode: base URL like `https://gateway.example.com`.
  final String? gatewayUrl;

  /// Gateway-mode: shared token sent as `X-ClusterOrbit-Token`.
  final String? gatewayToken;

  /// Direct-mode: full kubeconfig YAML pasted by the user.
  final String? kubeconfigYaml;

  /// Direct-mode: preferred context name, or null to use current-context.
  final String? kubeconfigContext;

  SavedConnection copyWith({
    String? displayName,
    String? gatewayUrl,
    String? gatewayToken,
    String? kubeconfigYaml,
    String? kubeconfigContext,
  }) {
    return SavedConnection(
      id: id,
      displayName: displayName ?? this.displayName,
      kind: kind,
      gatewayUrl: gatewayUrl ?? this.gatewayUrl,
      gatewayToken: gatewayToken ?? this.gatewayToken,
      kubeconfigYaml: kubeconfigYaml ?? this.kubeconfigYaml,
      kubeconfigContext: kubeconfigContext ?? this.kubeconfigContext,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'displayName': displayName,
        'kind': kind.name,
        if (gatewayUrl != null) 'gatewayUrl': gatewayUrl,
        if (gatewayToken != null) 'gatewayToken': gatewayToken,
        if (kubeconfigYaml != null) 'kubeconfigYaml': kubeconfigYaml,
        if (kubeconfigContext != null) 'kubeconfigContext': kubeconfigContext,
      };

  factory SavedConnection.fromJson(Map<String, dynamic> json) {
    return SavedConnection(
      id: json['id'] as String,
      displayName: json['displayName'] as String,
      kind: SavedConnectionKindLabel.fromName(json['kind'] as String),
      gatewayUrl: json['gatewayUrl'] as String?,
      gatewayToken: json['gatewayToken'] as String?,
      kubeconfigYaml: json['kubeconfigYaml'] as String?,
      kubeconfigContext: json['kubeconfigContext'] as String?,
    );
  }

  /// Short human summary for list rows. Hides the token.
  String get subtitle => switch (kind) {
        SavedConnectionKind.sample => 'Built-in demo data',
        SavedConnectionKind.gateway =>
          gatewayUrl?.isNotEmpty == true ? gatewayUrl! : 'Gateway (no URL)',
        SavedConnectionKind.direct => kubeconfigContext?.isNotEmpty == true
            ? 'Kubeconfig · ${kubeconfigContext!}'
            : 'Kubeconfig (current-context)',
      };
}
