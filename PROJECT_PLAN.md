# ClusterOrbit Project Plan

## Summary

ClusterOrbit is a free, UI-first mobile application for visualizing and administering Kubernetes clusters, including k3s, from iPhone, iPad, Android phones, and Android tablets. The differentiator is fast, high-resolution, machine-first topology rendering combined with guarded administrative workflows and strong offline-aware local caching.

Chosen defaults:

- Product name: `ClusterOrbit`
- Client stack: Flutter-first
- Connection model: direct `kubeconfig` access and an optional companion gateway
- Audience: mixed power users, from homelab operators to professional platform teams
- Editing scope: broad admin capability with guardrails, not raw destructive freedom by default
- UX direction: subtle galaxy aesthetic with a cinematic operations map
- Local persistence: SQLite
- Optional backend: Go gateway

## Product Direction

ClusterOrbit should optimize for:

- understanding machine and workload placement quickly
- viewing and editing configs safely on mobile
- supporting large clusters on tablets
- handling risky actions with clear validation and approvals
- remaining useful in direct-connect mode without a mandatory hosted backend

The app should feel like a serious infrastructure cockpit, not a gimmicky space theme. Visual language should use deep graphite and midnight tones with restrained orbital gradients, layered surfaces, and purposeful motion.

## Architecture

### Mobile Client

Use Flutter for the cross-platform shell and adaptive layouts. Implement a custom topology rendering scene rather than a widget-per-node graph to preserve performance on medium and large cluster views.

Mobile modules:

- `cluster-domain`: resource models, health state, topology entities
- `connectivity`: direct cluster adapter and gateway adapter behind one interface
- `topology-engine`: scene graph, clustering, hit testing, LOD, animation
- `editor`: YAML and JSON viewing, diff preview, validation, patch and apply flows
- `sync-cache`: SQLite-backed local snapshots, drafts, and history
- `auth-secrets`: device secure storage references
- `ops-workflows`: node lifecycle and guarded resource mutations

Rendering expectations:

- 60 FPS target for medium topologies on current devices
- retained scene model instead of full rebuilds
- progressive detail at far, mid, and near zoom levels
- background work for layout and heavy parsing where possible

### Local Data

Use SQLite for:

- cluster profiles
- cached topology snapshots
- manifest drafts
- recent diffs
- local audit history
- offline inspection data

### Optional Gateway

The companion gateway should be a Go service that can run locally, self-hosted, or as a future hosted option. It should provide:

- OIDC and SSO-ready auth
- RBAC-aware action brokering
- policy checks for risky mutations
- audit logging
- topology aggregation and delta streaming
- approval workflows for destructive operations
- guided node join planning and status tracking

Recommended endpoints:

- `POST /sessions`
- `GET /clusters`
- `GET /clusters/{id}/topology`
- `GET /clusters/{id}/topology/stream`
- `GET /clusters/{id}/resources/{kind}/{namespace}/{name}`
- `POST /clusters/{id}/mutations/validate`
- `POST /clusters/{id}/mutations/apply`
- `POST /clusters/{id}/nodes/join-plan`
- `POST /clusters/{id}/approvals`
- `GET /clusters/{id}/audit`

## UI Design

### Core Navigation

Phone:

- bottom tabs for `Map`, `Resources`, `Changes`, `Alerts`, `Settings`
- cluster switcher in the top bar
- detail sheets instead of deep modal stacks

Tablet:

- left pane for filters and navigation
- center pane for topology map
- right pane for details, metrics, config editor, and actions

### Topology UX

Default topology view is machine-first. Grouping modes should include:

- cluster
- node pool or label
- physical or VM host
- namespace
- workload owner

Overlays should be able to show:

- pod placement
- service to workload links
- ingress flow
- volume attachment
- network relationships where practical

### Editing and Operations

Support:

- config viewing and editing
- diff before apply
- resource detail pages
- node label and taint changes
- cordon and uncordon
- drain
- delete and replace flows
- guided add-node workflow

Guardrails:

- resource diff preview
- validation before apply
- risk classification
- typed confirmation for destructive actions
- optional second approval in gateway mode

## Build Order

1. Define topology schema, core models, and connection abstraction.
2. Deliver read-only direct-connect flow.
3. Implement custom topology engine and adaptive shells.
4. Add local SQLite caching and snapshot restore.
5. Add resource detail, logs, events, and editor flows.
6. Add mutation validation and guarded apply actions.
7. Add node lifecycle workflows.
8. Add optional gateway, auth, audit, and approvals.
9. Tune tablet performance and large-cluster rendering.

## Inspiration Targets

- `kubenav`: closest mobile benchmark for Kubernetes operations
- `Headlamp`: resource actions and permission-aware workflows
- `KubeView`: relationship mapping patterns
- `OpenRCA`: topology plus operational telemetry concepts
- `PatternFly Topology`: graph interaction ideas

## Naming

`ClusterOrbit` is intended to imply:

- spatial understanding
- operational control
- moving around complex systems with clarity

The name matches the product focus on machine placement, cluster relationships, and deliberate navigation rather than raw command-line parity.

## Success Criteria

- topology is visibly smoother and clearer than list-first mobile tools
- tablet layouts remain usable for larger clusters
- direct-connect mode is viable without a mandatory backend
- risky actions are safer than ad hoc raw manifest edits
- the visual system feels premium, modern, and restrained
