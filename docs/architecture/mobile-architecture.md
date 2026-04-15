# Mobile Architecture

## Layers

- `app`: shell, routing, adaptive navigation
- `core`: theme, layout tokens, utilities, interfaces
- `features`: vertical slices such as topology, resources, changes, alerts, settings
- `shared`: reusable widgets and domain-adjacent helpers

## Key Services

- `ClusterConnectionProvider`
- `TopologySnapshotService`
- `ResourceMutationService`
- `NodeLifecycleService`

## State Strategy

Start with a clear, testable application state boundary. Keep render state local to topology views and avoid coupling frame-sensitive behavior to high-level app navigation state.

## Offline Strategy

Use SQLite snapshots for recent cluster state and drafts. Live connections update the snapshot incrementally when online.
