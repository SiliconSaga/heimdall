# Heimdall — Architecture & Design

Deep architectural details for the Heimdall observability stack.
For quickstart and usage, see the [README](../README.md).

## Composition Pipeline

The Crossplane Composition (`crossplane/composition.yaml`) uses
`function-go-templating` to deploy and configure five steps:

1. **kube-prometheus-stack** (Provider-Helm Release) — Prometheus, Grafana,
   AlertManager, node-exporter, kube-state-metrics, default dashboards.
2. **Loki** (Provider-Helm Release) — Log aggregation in SingleBinary mode
   with filesystem storage and TSDB schema v13.
3. **Tempo** (Provider-Helm Release) — Distributed tracing with local storage,
   OTLP receivers on gRPC (4317) and HTTP (4318).
4. **Ingress Routes** (Provider-Kubernetes Objects) — Traefik IngressRoutes for
   Grafana and Prometheus. The base domain defaults to
   `EnvironmentConfig/cluster-identity` (loaded into the pipeline context by
   `function-environment-configs`); the Claim's `domain` parameter is an
   optional override.
5. **Auto-ready** — marks the composite resource Ready when all children are.

Grafana data sources are wired inline in the kube-prometheus-stack values:
- Prometheus (default, auto-discovered by sidecar)
- Loki (with trace-to-log derivedFields linking to Tempo)
- Tempo (with tracesToLogs and serviceMap linking back)

## Storage Strategy (Progressive)

| Phase | Backend | When |
|-------|---------|------|
| **Phase 1** (current) | Local filesystem PVCs | Initial homelab deployment |
| **Phase 2** | S3 via Garage (homelab) or GCS (GKE) | When Garage is stable and retention matters |

Phase 1 reads `storageClass` from `EnvironmentConfig/cluster-identity`
(loaded into the pipeline context by `function-environment-configs`)
and applies it as `storageClassName` on the rendered PVCs:
- `homelab` cluster identity → `local-path`
- `gke` cluster identity → `standard-rwo`

Phase 2 will add `objectStoreBucket` and S3 credential injection to the
Composition, switching Loki/Tempo from filesystem to S3 backends.

## Authentication Strategy (Progressive)

| Phase | Method | When |
|-------|--------|------|
| **Phase 1** (current) | Built-in Grafana admin (`admin`/`admin`) | Initial deployment |
| **Phase 2** | Grafana OIDC via Keycloak | After Keycloak is available in Nidavellir |

Grafana supports OIDC natively via `grafana.ini` — no sidecar proxy needed.
The Composition can conditionally patch OIDC settings when an `oidcEnabled`
parameter is added to the Claim.

## Environment Differences

| Aspect | Homelab (k3d/k3s) | GKE |
|--------|-------------------|-----|
| Storage class | `local-path` (from cluster-identity) | `standard-rwo` (from cluster-identity) |
| Prometheus replicas | 1 | 2 |
| Loki mode | SingleBinary | SingleBinary (Phase 2: SimpleScalable) |
| Ingress domain | `*.homelab.local` (from cluster-identity) | from cluster-identity (optional claim override per cluster) |

## Resource Estimates

Baseline homelab (single replica, no Thanos):

| Component | CPU Request | Memory Request |
|-----------|-------------|----------------|
| Prometheus | 250m | 512Mi |
| Grafana | 100m | 128Mi |
| AlertManager | 50m | 64Mi |
| Loki (monolithic) | 250m | 256Mi |
| Tempo | 250m | 256Mi |
| **Total** | **~900m** | **~1.2Gi** |

## Roadmap

Features planned but not yet implemented:

- **Thanos** — long-term metric retention beyond Prometheus's local storage.
  `thanosEnabled` parameter exists in the XRD but has no composition step yet.
  Recommended for GKE, deferrable on homelab.
- **Pyroscope** — continuous profiling (CPU, memory, goroutines) from Grafana.
  Would complete metrics/logs/traces/profiles. Integrates as a Grafana data
  source. See https://github.com/grafana/pyroscope.
- **Loki SimpleScalable** — horizontal scaling for GKE. Requires S3/GCS
  object storage (Phase 2 dependency). Different Helm values shape from
  SingleBinary — write/read/backend replicas instead of singleBinary.
- **OIDC/SSO** — Grafana single sign-on via Keycloak. Blocked on Keycloak
  deployment in Nidavellir.
- **Uptime Kuma** — cross-environment synthetic monitoring and status pages.
  Each environment runs an instance that monitors the other's endpoints,
  providing watchdog alerting when the main stack goes down.
- **Alerting rules** — Pre-configured PrometheusRules for common failure
  patterns (pod crashlooping, node pressure, PVC filling).
