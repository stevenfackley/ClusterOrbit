# ClusterOrbit

ClusterOrbit is a free, UI-first mobile tool for visualizing and operating Kubernetes clusters (including k3s) from phones and tablets. The product focus is fast topology rendering, machine-centric inspection, guarded administrative actions, and a serious operations-grade interface rather than a cramped mobile `kubectl`.

## Why It Exists

Most existing Kubernetes tools are desktop-first, list-heavy, or weak at showing how machines, workloads, and services relate spatially. ClusterOrbit is designed to make cluster state legible on modern mobile hardware without sacrificing operational usefulness.

## What Ships Today

**Mobile app (Flutter):**

- Adaptive shell — phone bottom-tabs, tablet side-rail + inspector, auto-switching at 960 px.
- Interactive cluster topology (pan/zoom, lane-based layout, curved links, entity detail panels).
- Phone-first list view with grouped nodes/workloads/services and toggle to the map.
- Alerts tab with detail sheet; resources tab with tabbed nodes/workloads/services; changes tab showing drift + unschedulable nodes.
- Swipe-to-refresh on every data screen; last-refreshed indicator + manual refresh in the app bar.
- First-run onboarding (sample, gateway, or direct/kubeconfig). Gateway form has connection test before save.
- Saved connection store (sqflite) with switch-active, delete, and most-recently-touched ordering.
- Workload scale mutation (sample + direct + gateway backed).
- Two connection modes:
  - **Direct** — kubeconfig parsed on-device; snapshot fetched straight from the API server.
  - **Gateway** — HTTP-backed, falls back to sample when URL is empty so the UI stays usable.
- SQLite snapshot cache with schema migrations.

**Go gateway (`app/gateway/`):**

- Endpoints: `GET /v1/clusters`, `GET /{id}/snapshot`, `GET /{id}/events`, `POST /{id}/workloads/{wid}/scale`.
- Shared-token auth via `X-ClusterOrbit-Token`, per-identity token-bucket rate limiting.
- TLS + optional mTLS, JSON-Lines audit log of every mutation, graceful shutdown.
- Sample or multi-context kubeconfig-backed data source.

## What's Not Built Yet

- Config viewing / editing / diffs / guarded apply.
- Node lifecycle actions (cordon, drain, label, taint, join).
- Approval or policy flows on the gateway (token + rate limit only).
- Real-time snapshot watch (currently polled on manual refresh).
- Retained-scene topology engine (filtering + LOD + force-directed layout); current topology is a view, not an engine.

## Architecture Snapshot

- **Mobile** — Flutter client. Direct-mode stays on-device; gateway-mode brokers the call.
- **Local cache** — sqflite (snapshots + saved connections).
- **Gateway** — Go 1.24, single external dep (`yaml.v3`), hand-rolled HTTP k8s client.

## Repository Layout

- [`app/mobile`](./app/mobile/) — Flutter client.
- [`app/gateway`](./app/gateway/) — Go gateway.
- [`docs/product`](./docs/product/vision.md) — product vision, roadmap, personas, naming.
- [`docs/architecture`](./docs/architecture/system-overview.md) — technical architecture.
- [`docs/design`](./docs/design/design-principles.md) — UI direction and topology UX.
- [`docs/engineering`](./docs/engineering/local-development.md) — setup, testing, release, standards.
- [`PROJECT_PLAN.md`](./PROJECT_PLAN.md) — full approved implementation plan.

## Getting Started

```bash
# mobile
cd app/mobile
cp .env.example .env          # first-time setup (Windows: Copy-Item .env.example .env)
flutter pub get
flutter run

# gateway (from repo root)
go run ./app/gateway/cmd/clusterorbit-gateway
go test ./...
```

The mobile app reads `app/mobile/.env` at startup. The real `.env` is gitignored; start from `.env.example`.

## Testing

```bash
# mobile
cd app/mobile
flutter test                         # full suite
dart format --output=none --set-exit-if-changed lib test
flutter analyze

# gateway (from repo root)
go test ./...
gofmt -l .
go vet ./...
```

## Screenshots

Screenshots and design mocks will be added as the tablet layout and topology UI stabilize.

## Contributing

See [CONTRIBUTING](./.github/CONTRIBUTING.md) for workflow expectations and [CODE_OF_CONDUCT](./CODE_OF_CONDUCT.md) for community standards.

## Security

See [SECURITY](./.github/SECURITY.md) for vulnerability reporting guidance.

## License

ClusterOrbit is licensed under the Apache License 2.0. See [LICENSE](./LICENSE).
