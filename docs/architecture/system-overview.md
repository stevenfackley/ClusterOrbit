# System Overview

ClusterOrbit has two operating modes.

## Direct Mode

The mobile app reads a user-provided `kubeconfig` and talks directly to the cluster API when reachable. Credentials remain on the device and the app uses SQLite plus secure storage for local state.

## Gateway Mode

The mobile app connects to a companion Go gateway that brokers cluster access, auth, audit, policy, and approvals. This mode supports team workflows and safer destructive operations.

## Major Components

- Flutter mobile client
- SQLite local cache
- native secure storage integration
- optional Go gateway
- Kubernetes APIs

## Data Flow

1. User selects a cluster profile.
2. App loads latest local snapshot.
3. App opens direct or gateway-backed live connection.
4. Topology engine hydrates and renders grouped scene data.
5. Detail, log, and edit flows operate against the same connection abstraction.
