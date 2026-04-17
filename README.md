# ClusterOrbit

ClusterOrbit is a free, UI-first mobile tool for visualizing and operating Kubernetes clusters, including k3s, from phones and tablets. The product focus is fast topology rendering, machine-centric inspection, guarded administrative actions, and a serious operations-grade interface rather than a cramped mobile `kubectl`.

## Why It Exists

Most existing Kubernetes tools are desktop-first, list-heavy, or weak at showing how machines, workloads, and services relate spatially. ClusterOrbit is designed to make cluster state legible on modern mobile hardware without sacrificing operational usefulness.

## Core Capabilities

- High-resolution cluster topology with smooth pan and zoom.
- Machine-first visualization for nodes, pools, workloads, and services.
- Direct `kubeconfig` access and an optional companion gateway.
- Config viewing and editing with diffs and guarded apply flows.
- Node lifecycle workflows such as cordon, drain, label, taint, and guided join.
- Strong local caching with SQLite for offline inspection and fast reloads.
- Phone and tablet layouts, with tablet as the primary large-cluster experience.

## Architecture Snapshot

- Mobile app: Flutter-first client with a custom topology rendering layer.
- Local data: SQLite cache for snapshots, drafts, and local action history.
- Optional backend: Go gateway for auth, audit, policy checks, topology aggregation, and approvals.
- Connection modes: direct cluster access or gateway-brokered access.

## Design Direction

ClusterOrbit uses a restrained galaxy-inspired visual language: deep graphite and midnight surfaces, cool orbital gradients, subtle luminous status cues, and motion that clarifies system state without looking gimmicky.

## Repository Layout

- [`app/mobile`](./app/mobile/README.md): Flutter mobile client (phone + tablet layouts, topology screen, sqflite cache).
- [`app/gateway`](./app/gateway/README.md): Go gateway (shared-token auth, rate limiting, mTLS, JSON-Lines audit, multi-cluster kube backend).
- [`docs/product`](./docs/product/vision.md): product vision, roadmap, personas, naming.
- [`docs/architecture`](./docs/architecture/system-overview.md): technical architecture.
- [`docs/design`](./docs/design/design-principles.md): UI direction and topology UX.
- [`docs/engineering`](./docs/engineering/local-development.md): setup, testing, release, standards.
- [`PROJECT_PLAN.md`](./PROJECT_PLAN.md): full approved implementation plan.

## Getting Started

```powershell
# mobile
cd app/mobile
Copy-Item .env.example .env     # only first time
flutter pub get
flutter run

# gateway (from repo root)
go run ./app/gateway/cmd/clusterorbit-gateway
# or: go test ./...
```

The mobile app expects a local `.env` file for startup configuration. Use `app/mobile/.env.example` as the template; the real `.env` is gitignored.

## Screenshots

Screenshots and design mocks will be added as the topology UI and tablet layouts become concrete.

## Contributing

See [CONTRIBUTING](./.github/CONTRIBUTING.md) for workflow expectations and [CODE_OF_CONDUCT](./CODE_OF_CONDUCT.md) for community standards.

## Security

See [SECURITY](./.github/SECURITY.md) for vulnerability reporting guidance.

## License

ClusterOrbit is licensed under the Apache License 2.0. See [LICENSE](./LICENSE).
