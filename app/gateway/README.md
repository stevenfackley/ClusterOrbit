# ClusterOrbit Gateway

Optional Go companion gateway for ClusterOrbit. Brokers mobile-client access to one or many Kubernetes clusters, enforces shared-token auth + per-caller rate limiting, and writes an append-only audit trail for every mutation.

## Run

```bash
# Sample data, open auth (for local demos)
go run ./cmd/clusterorbit-gateway

# Real kubeconfig, one context pinned
CLUSTERORBIT_GATEWAY_MODE=kube \
CLUSTERORBIT_GATEWAY_TOKEN=dev-token \
CLUSTERORBIT_GATEWAY_KUBE_CONTEXT=my-cluster \
  go run ./cmd/clusterorbit-gateway
```

## Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/v1/clusters` | List clusters the gateway serves |
| GET | `/v1/clusters/{id}/snapshot` | Nodes / workloads / services / alerts snapshot |
| GET | `/v1/clusters/{id}/events?kind=&objectName=&namespace=&limit=` | Kubernetes events scoped to one object (`kind`: node, workload, service, pod, deployment, daemonSet, statefulSet, job) |
| POST | `/v1/clusters/{id}/workloads/{workloadId}/scale` | `{"replicas": N}` — mutation, audited |
| POST | `/v1/clusters/{id}/workloads/{workloadId}/restart` | Rollout restart — mutation, audited |
| POST | `/v1/clusters/{id}/nodes/{node}/cordon` / `uncordon` | Mutation, audited |
| POST | `/v1/clusters/{id}/nodes/{node}/drain` | `202` + `DrainJob`; refuses nodes running unmanaged pods |
| GET | `/v1/clusters/{id}/nodes/{node}/drain/{jobId}` | Poll a drain job |
| GET | `/v1/clusters/{id}/approvals[/{rid}]` | Parked requests (two-person approval) |
| POST | `/v1/clusters/{id}/approvals/{rid}/approve` / `reject` | Approve needs a different token than the requester |

All endpoints require `X-ClusterOrbit-Token: <token>` when any token is configured. Workload IDs are `kind:namespace/name` (escape the `/` as `%2F` in paths); invalid names get `400`. A cluster ID containing `/` is passed `%2F`-escaped. A mutation gated by approval returns `202` with the `PendingRequest` body and a `Location` header pointing at it.

## Env

| Var | Purpose |
|-----|---------|
| `CLUSTERORBIT_GATEWAY_ADDR` | Listen address, default `:8080` |
| `CLUSTERORBIT_GATEWAY_MODE` | `sample` (default) or `kube` |
| `CLUSTERORBIT_GATEWAY_TOKEN` | Single shared token (legacy) |
| `CLUSTERORBIT_GATEWAY_TOKENS` | Comma-separated token set (rotation) |
| `CLUSTERORBIT_GATEWAY_TLS_CERT` / `_KEY` | Serve over HTTPS |
| `CLUSTERORBIT_GATEWAY_CLIENT_CA` | Enable mTLS — clients must present a cert signed by this CA |
| `CLUSTERORBIT_GATEWAY_RATE_LIMIT_RPS` / `_BURST` | Token-bucket config (set both or neither) |
| `CLUSTERORBIT_GATEWAY_TRUST_PROXY` | `true` = with auth off, take the client IP from the last `X-Forwarded-For` entry. Default off |
| `CLUSTERORBIT_GATEWAY_AUDIT_LOG` | Audit sink — unset=stdout, `off`=disabled, path=JSON-Lines file |
| `CLUSTERORBIT_GATEWAY_KUBECONFIG` / `KUBECONFIG` | Kubeconfig path (kube mode). Token and client-cert users supported; exec/auth-provider users are skipped |
| `CLUSTERORBIT_GATEWAY_KUBE_CONTEXT` | Pin to one context; unset = serve all resolvable contexts |
| `CLUSTERORBIT_GATEWAY_POLICY_*` | Scale/node policy gates and two-person approval — see the repo `CLAUDE.md` |

Invalid values (unparsable numbers/durations/bools, unknown approval ops, approval with fewer than 2 distinct tokens) stop the gateway at boot.

## Package layout

- `cmd/clusterorbit-gateway/` — entrypoint + env wiring
- `internal/api/` — HTTP handlers, validation, policy + approval gates, rate limiter, sample backend
- `internal/kubebackend/` — real K8s backend (single + multi-cluster), async drain
- `internal/kubeconfig/` — kubeconfig parser + resolver

## Not yet implemented

- Durable approval store (pending requests are in-memory and dropped on restart)
- Streaming snapshot updates (current snapshots are pull-only)
