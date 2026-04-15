# Gateway Architecture

The gateway is a Go service that is optional for single-user direct access but important for team and policy-heavy deployments.

## Responsibilities

- authenticate users
- broker cluster access
- project RBAC-aware capabilities
- validate and apply mutations
- stream topology deltas
- store audits and approvals

## Storage

- SQLite for self-hosted single-node setups
- Postgres as the scale-up path

## Interface Shape

- REST for inventory, mutation validation, approvals, and audit lookups
- streaming endpoint for topology updates, logs, and long-running workflows
