import 'dart:convert';
import 'dart:io';

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

  static KubeconfigDocument parse(String content) {
    final lines = content.replaceAll('\r\n', '\n').split('\n');
    final clusters = <KubeconfigClusterEntry>[];
    final contexts = <KubeconfigContextEntry>[];
    final users = <KubeconfigUserEntry>[];
    String? currentContext;

    _ClusterDraft? activeCluster;
    _ContextDraft? activeContext;
    _UserDraft? activeUser;
    String? section;

    void flushCluster() {
      if (activeCluster != null &&
          activeCluster!.name != null &&
          activeCluster!.name!.isNotEmpty) {
        clusters.add(
          KubeconfigClusterEntry(
            name: activeCluster!.name!,
            server: activeCluster!.server,
            certificateAuthorityData: activeCluster!.certificateAuthorityData,
            certificateAuthorityPath: activeCluster!.certificateAuthorityPath,
            insecureSkipTlsVerify: activeCluster!.insecureSkipTlsVerify,
          ),
        );
      }
      activeCluster = null;
    }

    void flushContext() {
      if (activeContext != null &&
          activeContext!.name != null &&
          activeContext!.clusterName != null &&
          activeContext!.name!.isNotEmpty &&
          activeContext!.clusterName!.isNotEmpty) {
        contexts.add(
          KubeconfigContextEntry(
            name: activeContext!.name!,
            clusterName: activeContext!.clusterName!,
            namespace: activeContext!.namespace,
            userName: activeContext!.userName,
          ),
        );
      }
      activeContext = null;
    }

    void flushUser() {
      if (activeUser != null &&
          activeUser!.name != null &&
          activeUser!.name!.isNotEmpty) {
        users.add(
          KubeconfigUserEntry(
            name: activeUser!.name!,
            token: activeUser!.token,
            tokenFile: activeUser!.tokenFile,
            username: activeUser!.username,
            password: activeUser!.password,
            clientCertificateData: activeUser!.clientCertificateData,
            clientCertificatePath: activeUser!.clientCertificatePath,
            clientKeyData: activeUser!.clientKeyData,
            clientKeyPath: activeUser!.clientKeyPath,
          ),
        );
      }
      activeUser = null;
    }

    void flushAll() {
      flushCluster();
      flushContext();
      flushUser();
    }

    for (final rawLine in lines) {
      final line = rawLine.trimRight();
      if (line.trim().isEmpty || line.trimLeft().startsWith('#')) {
        continue;
      }

      final trimmed = line.trimLeft();
      final indent = line.length - trimmed.length;

      if (indent == 0) {
        flushAll();
        section = null;

        if (trimmed == 'clusters:') {
          section = 'clusters';
          continue;
        }
        if (trimmed == 'contexts:') {
          section = 'contexts';
          continue;
        }
        if (trimmed == 'users:') {
          section = 'users';
          continue;
        }
        if (trimmed.startsWith('current-context:')) {
          currentContext = _valueFor(trimmed);
        }
        continue;
      }

      switch (section) {
        case 'clusters':
          if (indent == 2 && trimmed.startsWith('- ')) {
            flushCluster();
            activeCluster = _ClusterDraft();
            final remainder = trimmed.substring(2).trimLeft();
            if (remainder.startsWith('name:')) {
              activeCluster!.name = _valueFor(remainder);
            }
            continue;
          }
          if (activeCluster == null) {
            continue;
          }
          if (indent == 4 && trimmed.startsWith('name:')) {
            activeCluster!.name = _valueFor(trimmed);
          } else if (indent >= 4 && trimmed.startsWith('server:')) {
            activeCluster!.server = _valueFor(trimmed);
          } else if (indent >= 4 &&
              trimmed.startsWith('certificate-authority-data:')) {
            activeCluster!.certificateAuthorityData = _valueFor(trimmed);
          } else if (indent >= 4 &&
              trimmed.startsWith('certificate-authority:')) {
            activeCluster!.certificateAuthorityPath = _valueFor(trimmed);
          } else if (indent >= 4 &&
              trimmed.startsWith('insecure-skip-tls-verify:')) {
            activeCluster!.insecureSkipTlsVerify =
                _valueFor(trimmed).toLowerCase() == 'true';
          }
          break;
        case 'contexts':
          if (indent == 2 && trimmed.startsWith('- ')) {
            flushContext();
            activeContext = _ContextDraft();
            final remainder = trimmed.substring(2).trimLeft();
            if (remainder.startsWith('name:')) {
              activeContext!.name = _valueFor(remainder);
            }
            continue;
          }
          if (activeContext == null) {
            continue;
          }
          if (indent == 4 && trimmed.startsWith('name:')) {
            activeContext!.name = _valueFor(trimmed);
          } else if (indent >= 4 && trimmed.startsWith('cluster:')) {
            activeContext!.clusterName = _valueFor(trimmed);
          } else if (indent >= 4 && trimmed.startsWith('namespace:')) {
            activeContext!.namespace = _valueFor(trimmed);
          } else if (indent >= 4 && trimmed.startsWith('user:')) {
            activeContext!.userName = _valueFor(trimmed);
          }
          break;
        case 'users':
          if (indent == 2 && trimmed.startsWith('- ')) {
            flushUser();
            activeUser = _UserDraft();
            final remainder = trimmed.substring(2).trimLeft();
            if (remainder.startsWith('name:')) {
              activeUser!.name = _valueFor(remainder);
            }
            continue;
          }
          if (activeUser == null) {
            continue;
          }
          if (indent == 4 && trimmed.startsWith('name:')) {
            activeUser!.name = _valueFor(trimmed);
          } else if (indent >= 4 && trimmed.startsWith('token:')) {
            activeUser!.token = _valueFor(trimmed);
          } else if (indent >= 4 && trimmed.startsWith('tokenFile:')) {
            activeUser!.tokenFile = _valueFor(trimmed);
          } else if (indent >= 4 && trimmed.startsWith('username:')) {
            activeUser!.username = _valueFor(trimmed);
          } else if (indent >= 4 && trimmed.startsWith('password:')) {
            activeUser!.password = _valueFor(trimmed);
          } else if (indent >= 4 &&
              trimmed.startsWith('client-certificate-data:')) {
            activeUser!.clientCertificateData = _valueFor(trimmed);
          } else if (indent >= 4 && trimmed.startsWith('client-certificate:')) {
            activeUser!.clientCertificatePath = _valueFor(trimmed);
          } else if (indent >= 4 && trimmed.startsWith('client-key-data:')) {
            activeUser!.clientKeyData = _valueFor(trimmed);
          } else if (indent >= 4 && trimmed.startsWith('client-key:')) {
            activeUser!.clientKeyPath = _valueFor(trimmed);
          }
          break;
      }
    }

    flushAll();

    return KubeconfigDocument(
      clusters: clusters,
      contexts: contexts,
      users: users,
      currentContext: currentContext,
    );
  }

  static String _valueFor(String line) {
    final separator = line.indexOf(':');
    if (separator < 0) {
      return '';
    }

    final value = line.substring(separator + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith('\'') && value.endsWith('\''))) {
      return value.substring(1, value.length - 1);
    }
    return value;
  }
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

class _ClusterDraft {
  String? name;
  String? server;
  String? certificateAuthorityData;
  String? certificateAuthorityPath;
  bool insecureSkipTlsVerify = false;
}

class _ContextDraft {
  String? name;
  String? clusterName;
  String? namespace;
  String? userName;
}

class _UserDraft {
  String? name;
  String? token;
  String? tokenFile;
  String? username;
  String? password;
  String? clientCertificateData;
  String? clientCertificatePath;
  String? clientKeyData;
  String? clientKeyPath;
}
