import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../cluster_domain/cluster_models.dart';
import '../cluster_domain/saved_connection.dart';

/// User-configured connection persistence. Distinct from [SnapshotStore]:
/// this is "what the user added", that is "what we cached from live".
abstract interface class SavedConnectionStore {
  Future<List<SavedConnection>> listConnections();
  Future<void> saveConnection(SavedConnection connection);
  Future<void> deleteConnection(String id);
}

abstract interface class SnapshotStore {
  /// Loads cached profiles. If [maxAge] is non-null, rows whose `cached_at`
  /// is older than `now - maxAge` are treated as missing.
  Future<List<ClusterProfile>> loadProfiles({Duration? maxAge});
  Future<void> saveProfiles(List<ClusterProfile> profiles);

  /// Loads the cached snapshot for [profileId]. If [maxAge] is non-null and
  /// the cached row is older than `now - maxAge`, returns null.
  Future<ClusterSnapshot?> loadSnapshot(String profileId, {Duration? maxAge});
  Future<void> saveSnapshot(ClusterSnapshot snapshot);

  /// Loads the cached event list for a single entity. Returns null when no
  /// row exists or when the cached row is older than [maxAge].
  Future<List<ClusterEvent>?> loadEvents({
    required String profileId,
    required TopologyEntityKind kind,
    required String objectName,
    String? namespace,
    Duration? maxAge,
  });

  Future<void> saveEvents({
    required String profileId,
    required TopologyEntityKind kind,
    required String objectName,
    String? namespace,
    required List<ClusterEvent> events,
  });
}

final class SqfliteSnapshotStore
    implements SnapshotStore, SavedConnectionStore {
  SqfliteSnapshotStore({this.dbPath});

  final String? dbPath;
  Future<Database>? _dbFuture;

  Future<Database> get _db => _dbFuture ??= _openDb();

  @visibleForTesting
  Future<Database> get dbForTest => _db;

  Future<Database> _openDb() async {
    final path = dbPath ??
        join(
            (await getApplicationDocumentsDirectory()).path, 'clusterorbit.db');
    return openDatabase(
      path,
      version: 3,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE cluster_profiles (
            id        TEXT PRIMARY KEY,
            payload   TEXT NOT NULL,
            cached_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE cluster_snapshots (
            profile_id   TEXT PRIMARY KEY,
            payload      TEXT NOT NULL,
            generated_at INTEGER NOT NULL,
            cached_at    INTEGER NOT NULL
          )
        ''');
        await db.execute(_createEventsTableSql);
        await db.execute(_createSavedConnectionsTableSql);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(_createEventsTableSql);
        }
        if (oldVersion < 3) {
          await db.execute(_createSavedConnectionsTableSql);
        }
      },
    );
  }

  static const _createEventsTableSql = '''
    CREATE TABLE cluster_events (
      profile_id  TEXT NOT NULL,
      kind        TEXT NOT NULL,
      namespace   TEXT NOT NULL,
      object_name TEXT NOT NULL,
      payload     TEXT NOT NULL,
      cached_at   INTEGER NOT NULL,
      PRIMARY KEY (profile_id, kind, namespace, object_name)
    )
  ''';

  static const _createSavedConnectionsTableSql = '''
    CREATE TABLE saved_connections (
      id         TEXT PRIMARY KEY,
      payload    TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )
  ''';

  static String _namespaceKey(String? namespace) => namespace ?? '';

  @override
  Future<List<ClusterProfile>> loadProfiles({Duration? maxAge}) async {
    final db = await _db;
    final rows = maxAge == null
        ? await db.query('cluster_profiles')
        : await db.query(
            'cluster_profiles',
            where: 'cached_at >= ?',
            whereArgs: [
              DateTime.now().millisecondsSinceEpoch - maxAge.inMilliseconds,
            ],
          );
    final profiles = <ClusterProfile>[];
    for (final row in rows) {
      try {
        final map =
            jsonDecode(row['payload'] as String) as Map<String, dynamic>;
        profiles.add(ClusterProfile.fromJson(map));
      } catch (_) {
        // Corrupt payload — treat as missing, skip this row.
      }
    }
    return profiles;
  }

  @override
  Future<void> saveProfiles(List<ClusterProfile> profiles) async {
    final db = await _db;
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = db.batch();
    for (final profile in profiles) {
      batch.insert(
        'cluster_profiles',
        {
          'id': profile.id,
          'payload': jsonEncode(profile.toJson()),
          'cached_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  @override
  Future<ClusterSnapshot?> loadSnapshot(
    String profileId, {
    Duration? maxAge,
  }) async {
    final db = await _db;
    final where =
        maxAge == null ? 'profile_id = ?' : 'profile_id = ? AND cached_at >= ?';
    final whereArgs = maxAge == null
        ? [profileId]
        : [
            profileId,
            DateTime.now().millisecondsSinceEpoch - maxAge.inMilliseconds,
          ];
    final rows = await db.query(
      'cluster_snapshots',
      where: where,
      whereArgs: whereArgs,
    );
    if (rows.isEmpty) return null;
    try {
      final map =
          jsonDecode(rows.first['payload'] as String) as Map<String, dynamic>;
      return ClusterSnapshot.fromJson(map);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> saveSnapshot(ClusterSnapshot snapshot) async {
    final db = await _db;
    await db.insert(
      'cluster_snapshots',
      {
        'profile_id': snapshot.profile.id,
        'payload': jsonEncode(snapshot.toJson()),
        'generated_at': snapshot.generatedAt.millisecondsSinceEpoch,
        'cached_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<List<ClusterEvent>?> loadEvents({
    required String profileId,
    required TopologyEntityKind kind,
    required String objectName,
    String? namespace,
    Duration? maxAge,
  }) async {
    final db = await _db;
    final where = maxAge == null
        ? 'profile_id = ? AND kind = ? AND namespace = ? AND object_name = ?'
        : 'profile_id = ? AND kind = ? AND namespace = ? AND object_name = ? AND cached_at >= ?';
    final whereArgs = <Object>[
      profileId,
      kind.name,
      _namespaceKey(namespace),
      objectName,
      if (maxAge != null)
        DateTime.now().millisecondsSinceEpoch - maxAge.inMilliseconds,
    ];
    final rows = await db.query(
      'cluster_events',
      where: where,
      whereArgs: whereArgs,
    );
    if (rows.isEmpty) return null;
    try {
      final list = jsonDecode(rows.first['payload'] as String) as List<dynamic>;
      return list
          .map((e) => ClusterEvent.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> saveEvents({
    required String profileId,
    required TopologyEntityKind kind,
    required String objectName,
    String? namespace,
    required List<ClusterEvent> events,
  }) async {
    final db = await _db;
    await db.insert(
      'cluster_events',
      {
        'profile_id': profileId,
        'kind': kind.name,
        'namespace': _namespaceKey(namespace),
        'object_name': objectName,
        'payload': jsonEncode(events.map((e) => e.toJson()).toList()),
        'cached_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<List<SavedConnection>> listConnections() async {
    final db = await _db;
    final rows = await db.query(
      'saved_connections',
      orderBy: 'created_at ASC',
    );
    final out = <SavedConnection>[];
    for (final row in rows) {
      try {
        final map =
            jsonDecode(row['payload'] as String) as Map<String, dynamic>;
        out.add(SavedConnection.fromJson(map));
      } catch (_) {
        // Corrupt payload — skip.
      }
    }
    return out;
  }

  @override
  Future<void> saveConnection(SavedConnection connection) async {
    final db = await _db;
    await db.insert(
      'saved_connections',
      {
        'id': connection.id,
        'payload': jsonEncode(connection.toJson()),
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> deleteConnection(String id) async {
    final db = await _db;
    await db.delete('saved_connections', where: 'id = ?', whereArgs: [id]);
  }
}
