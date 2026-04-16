# SQLite Snapshot Cache — Design Spec

## Goal

Cache `ClusterSnapshot` and `ClusterProfile` data in SQLite so the app loads instantly on cold start and remains usable when the cluster is unreachable.

## Architecture

One new module: `lib/core/sync_cache/`. Two tables in a single SQLite database. Serialization handled by `toJson`/`fromJson` methods added to the domain model classes in `cluster_models.dart`.

`OrbitShell` owns a `SnapshotStore` instance and drives the cache read/write flow. No other layer touches the store.

## New Files

| File | Responsibility |
|------|---------------|
| `lib/core/sync_cache/snapshot_store.dart` | Abstract `SnapshotStore` interface + `SqfliteSnapshotStore` implementation |

## Modified Files

| File | Change |
|------|--------|
| `lib/core/cluster_domain/cluster_models.dart` | Add `toJson()`/`fromJson()` to all serializable classes |
| `lib/shared/widgets/orbit_shell.dart` | Wire `SqfliteSnapshotStore` into `_bootstrap()` and `_cycleCluster()` |
| `pubspec.yaml` | Add `sqflite: ^2.3.0` and `path_provider: ^2.1.0` |

## Database Schema

Database file: `clusterorbit.db` in the app documents directory (via `path_provider`).

```sql
CREATE TABLE IF NOT EXISTS cluster_profiles (
  id        TEXT PRIMARY KEY,
  payload   TEXT NOT NULL,
  cached_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS cluster_snapshots (
  profile_id   TEXT PRIMARY KEY,
  payload      TEXT NOT NULL,
  generated_at INTEGER NOT NULL,
  cached_at    INTEGER NOT NULL
);
```

Both tables use `INSERT OR REPLACE` on every write. One row per cluster profile.

## SnapshotStore Interface

```dart
abstract interface class SnapshotStore {
  Future<List<ClusterProfile>> loadProfiles();
  Future<void> saveProfiles(List<ClusterProfile> profiles);
  Future<ClusterSnapshot?> loadSnapshot(String profileId);
  Future<void> saveSnapshot(ClusterSnapshot snapshot);
}
```

`SqfliteSnapshotStore` implements this interface. It holds a `Future<Database>? _dbFuture` field, initialised on first method call and reused for all subsequent calls (memoised async init, no race condition).

## Serialization

Add `toJson()` → `Map<String, dynamic>` and `fromJson(Map<String, dynamic>)` factory constructors to:

- `ClusterProfile`
- `ClusterNode`
- `ClusterWorkload`
- `ServicePort`
- `ClusterService`
- `ClusterAlert`
- `TopologyLink`
- `ClusterSnapshot`

Enums serialise as their `.name` string. `DateTime` serialises as UTC milliseconds since epoch (`millisecondsSinceEpoch`). Lists serialise as JSON arrays. Nullable fields encode as `null`.

The JSON blob stored in `payload` is the output of `jsonEncode(snapshot.toJson())` using `dart:convert`.

## OrbitShell Bootstrap Flow

```
_bootstrap():
  1. cachedProfiles = await store.loadProfiles()
  2. If cachedProfiles not empty:
       cachedSnapshot = await store.loadSnapshot(cachedProfiles.first.id)
       If cachedSnapshot not null:
         setState: _clusters, _selectedCluster, _snapshot = cached; _isLoading = false
  3. [background] fetch live clusters + snapshot from connection
  4. On success:
       await store.saveProfiles(clusters)
       await store.saveSnapshot(snapshot)
       setState: update all fields, _isLoading = false
  5. On error:
       If cache was shown: swallow error, keep cache visible
       If no cache: setState _loadError, _isLoading = false
```

`_cycleCluster()` follows the same pattern: show cached snapshot for the target profile immediately if available, then fetch live and replace silently.

## Error Handling

- DB open failure: propagate as `_loadError` (same as today's network failure path)
- Corrupt/undecodable JSON blob: treat as cache miss, log and continue
- Live fetch error when cache available: swallow silently, user sees last-good data

## Testing

- Unit tests for `SqfliteSnapshotStore` using `sqflite_common_ffi` (in-memory DB)
- Unit tests for all `toJson`/`fromJson` round-trips
- `OrbitShell` gets an optional `store` parameter (same pattern as the existing `connection` parameter) so tests can inject a no-op stub without touching the real DB

## What This Does Not Include

- Snapshot history (multiple rows per profile)
- Cache expiry / TTL enforcement
- Profile deletion or cache invalidation UI
- Encryption of the stored payload
