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
| GET | `/v1/clusters/{id}/events?kind=&objectName=&namespace=&limit=` | Kubernetes events scoped to one object |
| POST | `/v1/clusters/{id}/workloads/{workloadId}/scale` | `{"replicas": N}` — mutation, audited |

All endpoints require `X-ClusterOrbit-Token: <token>` when any token is configured.

## Env

| Var | Purpose |
|-----|---------|
| `CLUSTERORBIT_GATEWAY_ADDR` | Listen address, default `:8080` |
| `CLUSTERORBIT_GATEWAY_MODE` | `sample` (default) or `kube` |
| `CLUSTERORBIT_GATEWAY_TOKEN` | Single shared token (legacy) |
| `CLUSTERORBIT_GATEWAY_TOKENS` | Comma-separated token set (rotation) |
| `CLUSTERORBIT_GATEWAY_TLS_CERT` / `_KEY` | Serve over HTTPS |
| `CLUSTERORBIT_GATEWAY_CLIENT_CA` | Enable mTLS — clients must present a cert signed by this CA |
| `CLUSTERORBIT_GATEWAY_RATE_LIMIT_RPS` / `_BURST` | Token-bucket config |
| `CLUSTERORBIT_GATEWAY_AUDIT_LOG` | Audit sink — unset=stdout, `off`=disabled, path=JSON-Lines file |
| `CLUSTERORBIT_GATEWAY_KUBECONFIG` / `KUBECONFIG` | Kubeconfig path (kube mode) |
| `CLUSTERORBIT_GATEWAY_KUBE_CONTEXT` | Pin to one context; unset = serve all resolvable contexts |

## Package layout

- `cmd/clusterorbit-gateway/` — entrypoint + env wiring
- `internal/api/` — HTTP handlers, rate limiter, sample backend
- `internal/kubebackend/` — real K8s backend (single + multi-cluster)
- `internal/kubeconfig/` — kubeconfig parser + resolver

## Not yet implemented

- Approval flows for destructive mutations
- Policy-aware validation beyond typed errors
- Streaming snapshot updates (current snapshots are pull-only)
