import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

import '../cluster_domain/cluster_models.dart';

final class KubeconfigRepository {
  KubeconfigRepository({
    Map<String, String>? environment,
  }) : _environment = environment;

  final Map<String, String>? _environment;

  Future<List<ClusterProfile>> loadProfiles() async {
    final document = await _loadDocument();
    if (document == null || document.contexts.isEmpty) {
      return const [];
    }

    final preferredContext = _environmentValue('CLUSTERORBIT_CONTEXT');
    final orderedContexts = [
      if (preferredContext != null)
        ...document.contexts
            .where((context) => context.name == preferredContext),
      if (document.currentContext != null &&
          document.currentContext != preferredContext)
        ...document.contexts
            .where((context) => context.name == document.currentContext),
      ...document.contexts.where(
        (context) =>
            context.name != preferredContext &&
            context.name != document.currentContext,
      ),
    ];

    final seen = <String>{};
    return [
      for (final context in orderedContexts)
        if (seen.add(context.name)) _profileFromContext(document, context),
    ];
  }

  Future<KubeconfigResolvedCluster?> loadResolvedCluster(
      String contextName) async {
    final document = await _loadDocument();
    if (document == null) {
      return null;
    }

    final context = document.contextByName[contextName];
    if (context == null) {
      return null;
    }

    final cluster = document.clusterByName[context.clusterName];
    if (cluster == null || cluster.server == null || cluster.server!.isEmpty) {
      return null;
    }

    final user = context.userName == null
        ? null
        : document.userByName[context.userName!];

    return KubeconfigResolvedCluster(
      profile: _profileFromContext(document, context),
      server: cluster.server!,
      namespace: context.namespace,
      auth: KubeconfigAuth(
        bearerToken: await _resolveBearerToken(user),
        basicUsername: user?.username,
        basicPassword: user?.password,
        clientCertificateData: await _resolveBytes(
          inlineBase64: user?.clientCertificateData,
          path: user?.clientCertificatePath,
        ),
        clientKeyData: await _resolveBytes(
          inlineBase64: user?.clientKeyData,
          path: user?.clientKeyPath,
        ),
      ),
      tls: KubeconfigTlsConfig(
        insecureSkipTlsVerify: cluster.insecureSkipTlsVerify,
        certificateAuthorityData: await _resolveBytes(
          inlineBase64: cluster.certificateAuthorityData,
          path: cluster.certificateAuthorityPath,
        ),
      ),
    );
  }

  Future<KubeconfigDocument?> _loadDocument() async {
    final path = _resolveKubeconfigPath();
    if (path == null) {
      return null;
    }

    final file = File(path);
    if (!await file.exists()) {
      return null;
    }

    return KubeconfigDocument.parse(await file.readAsString());
  }

  ClusterProfile _profileFromContext(
    KubeconfigDocument document,
    KubeconfigContextEntry context,
  ) {
    final cluster = document.clusterByName[context.clusterName];
    final name =
        context.clusterName.isEmpty ? context.name : context.clusterName;
    return ClusterProfile(
      id: context.name,
      name: name,
      apiServerHost: _hostFor(cluster?.server),
      environmentLabel: _environmentLabelFor(context.name, name),
      connectionMode: ConnectionMode.direct,
    );
  }

  Future<String?> _resolveBearerToken(KubeconfigUserEntry? user) async {
    if (user == null) {
      return null;
    }
    if (user.token != null && user.token!.isNotEmpty) {
      return user.token;
    }
    if (user.tokenFile != null && user.tokenFile!.isNotEmpty) {
      final file = File(user.tokenFile!);
      if (await file.exists()) {
        return (await file.readAsString()).trim();
      }
    }
    return null;
  }

  Future<List<int>?> _resolveBytes({
    String? inlineBase64,
    String? path,
  }) async {
    if (inlineBase64 != null && inlineBase64.isNotEmpty) {
      return base64Decode(inlineBase64);
    }
    if (path != null && path.isNotEmpty) {
      final file = File(path);
      if (await file.exists()) {
        return file.readAsBytes();
      }
    }
    return null;
  }

  String _hostFor(String? server) {
    if (server == null || server.isEmpty) {
      return 'unresolved-cluster';
    }

    final uri = Uri.tryParse(server);
    if (uri == null) {
      return server;
    }

    if (uri.hasAuthority && uri.host.isNotEmpty) {
      return uri.host;
    }

    return server;
  }

  String _environmentLabelFor(String contextName, String clusterName) {
    final probe = '${contextName.toLowerCase()} ${clusterName.toLowerCase()}';
    if (probe.contains('prod')) {
      return 'Production';
    }
    if (probe.contains('stage')) {
      return 'Staging';
    }
    if (probe.contains('dev')) {
      return 'Development';
    }
    if (probe.contains('test')) {
      return 'Testing';
    }
    if (probe.contains('home') || probe.contains('lab')) {
      return 'Homelab';
    }
    return 'Direct access';
  }

  String? _resolveKubeconfigPath() {
    final explicitPath = _environmentValue('CLUSTERORBIT_KUBECONFIG');
    if (explicitPath != null && explicitPath.isNotEmpty) {
      return explicitPath;
    }

    final kubeconfigEnv = _environmentValue('KUBECONFIG');
    if (kubeconfigEnv != null && kubeconfigEnv.isNotEmpty) {
      final separator = Platform.isWindows ? ';' : ':';
      for (final candidate in kubeconfigEnv.split(separator)) {
        final trimmed = candidate.trim();
        if (trimmed.isNotEmpty) {
          return trimmed;
        }
      }
    }

    final home = _environmentValue('HOME') ?? _environmentValue('USERPROFILE');
    if (home == null || home.isEmpty) {
      return null;
    }

    return '$home${Platform.pathSeparator}.kube${Platform.pathSeparator}config';
  }

  String? _environmentValue(String key) =>
      _environment?[key] ?? Platform.environment[key];
}

final class KubeconfigResolvedCluster {
  const KubeconfigResolvedCluster({
    required this.profile,
    required this.server,
    required this.namespace,
    required this.auth,
    required this.tls,
  });

  final ClusterProfile profile;
  final String server;
  final String? namespace;
  final KubeconfigAuth auth;
  final KubeconfigTlsConfig tls;
}

final class KubeconfigAuth {
  const KubeconfigAuth({
    required this.bearerToken,
    required this.basicUsername,
    required this.basicPassword,
    required this.clientCertificateData,
    required this.clientKeyData,
  });

  final String? bearerToken;
  final String? basicUsername;
  final String? basicPassword;
  final List<int>? clientCertificateData;
  final List<int>? clientKeyData;
}

final class KubeconfigTlsConfig {
  const KubeconfigTlsConfig({
    required this.insecureSkipTlsVerify,
    required this.certificateAuthorityData,
  });

  final bool insecureSkipTlsVerify;
  final List<int>? certificateAuthorityData;
}

final class KubeconfigDocument {
  KubeconfigDocument({
    required this.clusters,
    required this.contexts,
    required this.users,
    required this.currentContext,
  });

  final List<KubeconfigClusterEntry> clusters;
  final List<KubeconfigContextEntry> contexts;
  final List<KubeconfigUserEntry> users;
  final String? currentContext;

  Map<String, KubeconfigClusterEntry> get clusterByName => {
        for (final cluster in clusters) cluster.name: cluster,
      };

  Map<String, KubeconfigContextEntry> get contextByName => {
        for (final context in contexts) context.name: context,
      };

  Map<String, KubeconfigUserEntry> get userByName => {
        for (final user in users) user.name: user,
      };

  /// Parses kubeconfig YAML. Throws a [FormatException] (a `YamlException` for
  /// bad syntax) when [content] is not a kubeconfig mapping.
  static KubeconfigDocument parse(String content) {
    final root = loadYaml(content);
    if (root != null && root is! Map) {
      throw const FormatException('Kubeconfig must be a YAML mapping.');
    }
    final doc = root as Map? ?? const {};

    final clusters = <KubeconfigClusterEntry>[];
    for (final item in _entries(doc['clusters'])) {
      final name = _string(item['name']);
      if (name == null || name.isEmpty) continue;
      final cluster = _map(item['cluster']);
      clusters.add(
        KubeconfigClusterEntry(
          name: name,
          server: _string(cluster['server']),
          certificateAuthorityData:
              _string(cluster['certificate-authority-data']),
          certificateAuthorityPath: _string(cluster['certificate-authority']),
          insecureSkipTlsVerify:
              _string(cluster['insecure-skip-tls-verify'])?.toLowerCase() ==
                  'true',
        ),
      );
    }

    final contexts = <KubeconfigContextEntry>[];
    for (final item in _entries(doc['contexts'])) {
      final name = _string(item['name']);
      final context = _map(item['context']);
      final clusterName = _string(context['cluster']);
      if (name == null ||
          name.isEmpty ||
          clusterName == null ||
          clusterName.isEmpty) {
        continue;
      }
      contexts.add(
        KubeconfigContextEntry(
          name: name,
          clusterName: clusterName,
          namespace: _string(context['namespace']),
          userName: _string(context['user']),
        ),
      );
    }

    final users = <KubeconfigUserEntry>[];
    for (final item in _entries(doc['users'])) {
      final name = _string(item['name']);
      if (name == null || name.isEmpty) continue;
      final user = _map(item['user']);
      users.add(
        KubeconfigUserEntry(
          name: name,
          token: _string(user['token']),
          tokenFile: _string(user['tokenFile']),
          username: _string(user['username']),
          password: _string(user['password']),
          clientCertificateData: _string(user['client-certificate-data']),
          clientCertificatePath: _string(user['client-certificate']),
          clientKeyData: _string(user['client-key-data']),
          clientKeyPath: _string(user['client-key']),
        ),
      );
    }

    return KubeconfigDocument(
      clusters: clusters,
      contexts: contexts,
      users: users,
      currentContext: _string(doc['current-context']),
    );
  }

  static Iterable<Map> _entries(Object? raw) =>
      raw is List ? raw.whereType<Map>() : const [];

  static Map _map(Object? raw) => raw is Map ? raw : const {};

  static String? _string(Object? raw) =>
      raw is String || raw is num || raw is bool ? '$raw' : null;
}

class KubeconfigClusterEntry {
  const KubeconfigClusterEntry({
    required this.name,
    required this.server,
    required this.certificateAuthorityData,
    required this.certificateAuthorityPath,
    required this.insecureSkipTlsVerify,
  });

  final String name;
  final String? server;
  final String? certificateAuthorityData;
  final String? certificateAuthorityPath;
  final bool insecureSkipTlsVerify;
}

class KubeconfigContextEntry {
  const KubeconfigContextEntry({
    required this.name,
    required this.clusterName,
    required this.namespace,
    required this.userName,
  });

  final String name;
  final String clusterName;
  final String? namespace;
  final String? userName;
}

class KubeconfigUserEntry {
  const KubeconfigUserEntry({
    required this.name,
    required this.token,
    required this.tokenFile,
    required this.username,
    required this.password,
    required this.clientCertificateData,
    required this.clientCertificatePath,
    required this.clientKeyData,
    required this.clientKeyPath,
  });

  final String name;
  final String? token;
  final String? tokenFile;
  final String? username;
  final String? password;
  final String? clientCertificateData;
  final String? clientCertificatePath;
  final String? clientKeyData;
  final String? clientKeyPath;
}
