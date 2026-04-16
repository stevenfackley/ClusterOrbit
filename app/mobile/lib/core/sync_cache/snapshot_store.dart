import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../cluster_domain/cluster_models.dart';

abstract interface class SnapshotStore {
  Future<List<ClusterProfile>> loadProfiles();
  Future<void> saveProfiles(List<ClusterProfile> profiles);
  Future<ClusterSnapshot?> loadSnapshot(String profileId);
  Future<void> saveSnapshot(ClusterSnapshot snapshot);
}

final class SqfliteSnapshotStore implements SnapshotStore {
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
      version: 1,
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
      },
    );
  }

  @override
  Future<List<ClusterProfile>> loadProfiles() async {
    final db = await _db;
    final rows = await db.query('cluster_profiles');
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
  Future<ClusterSnapshot?> loadSnapshot(String profileId) async {
    final db = await _db;
    final rows = await db.query(
      'cluster_snapshots',
      where: 'profile_id = ?',
      whereArgs: [profileId],
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
}
