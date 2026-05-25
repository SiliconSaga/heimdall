# Heimdall — Architecture & Design

Deep architectural details for the Heimdall observability stack.
For quickstart and usage, see the [README](../README.md).

## Composition Pipeline

The Crossplane Composition (`crossplane/composition.yaml`) uses
`function-go-templating` to deploy and configure six steps:

1. **kube-prometheus-stack** (Provider-Helm Release) — Prometheus, Grafana,
   AlertManager, node-exporter, kube-state-metrics, default dashboards. AlertManager is configured with a severity-routing tree: `warning` alerts route to ntfy (quiet push), `critical` alerts route to ntfy with a 1 h repeat and optionally to Knarr (SMS/call escalation) when `knarrWebhookUrl` is set on the Claim — see [Alerting & Notification](#alerting--notification) below.
2. **Loki** (Provider-Helm Release) — Log aggregation in SingleBinary mode
   with filesystem storage and TSDB schema v13.
3. **Tempo** (Provider-Helm Release) — Distributed tracing with local storage,
   OTLP receivers on gRPC (4317) and HTTP (4318).
4. **Self-health PrometheusRules** (Provider-Kubernetes Object) — Heimdall-scoped
   alerts: PVC fill (warn at 80%, critical at 90%), Prometheus restart-storm,
   WAL corruption, TSDB compaction failures. Labelled with
   `release: <name>-kube-prometheus` so kube-prometheus-stack's default rule
   selector picks them up. Designed for the
   [2026-05-15 incident class](https://github.com/SiliconSaga/yggdrasil/blob/main/docs/plans/2026-05-19-heimdall-monitoring-design.md);
   AlertManager notification routing follows in a separate arc.
5. **Ingress Routes** (Provider-Kubernetes Objects) — Traefik IngressRoutes for
   Grafana and Prometheus. The base domain defaults to
   `EnvironmentConfig/cluster-identity` (loaded into the pipeline context by
   `function-environment-configs`); the Claim's `domain` parameter is an
   optional override.
6. **Auto-ready** — marks the composite resource Ready when all children are.

Grafana data sources are wired inline in the kube-prometheus-stack values:
- Prometheus (default, auto-discovered by sidecar)
- Loki (with trace-to-log derivedFields linking to Tempo)
- Tempo (with tracesToLogs and serviceMap linking back)

## Alerting & Notification

AlertManager routes firing alerts by severity to ntfy (in-cluster at `http://ntfy.ntfy.svc.cluster.local/heimdall-alerts`), with the `critical` route on a 1 h repeat interval. **Current limitation:** AlertManager's `webhook_configs` posts the raw webhook JSON *without* ntfy-specific headers (`Priority`/`Title`/`Tags`), so alerts arrive as raw JSON at default priority — `critical` does **not yet** pierce Do Not Disturb, and notifications aren't formatted. Severity→priority mapping + readable formatting (which enables the DND override and a quiet `warning` tier) is designed via ntfy server-side templating — see the [alert-formatting design](https://github.com/SiliconSaga/nidavellir/blob/main/docs/plans/2026-05-25-ntfy-alert-formatting-design.md). ntfy is deployed as a 0-replica standby in the homelab via Nidavellir — delivery only succeeds where ntfy is active, which is expected.

A dormant Knarr escalation seam is wired into the `ntfy-critical` receiver as a second `webhook_configs` entry. When the Claim's `knarrWebhookUrl` parameter is unset the seam emits nothing (gated by `{{- if }}` in the go-template, so no inert placeholder URL is rendered). When set, Knarr receives the standard AlertManager webhook v4 payload and handles SMS/call escalation for critical alerts. The full notification routing design is documented at https://github.com/SiliconSaga/nidavellir/blob/main/docs/plans/2026-05-21-alert-notification-routing-design.md.

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
- **AlertManager notification routing** — Severity routing to ntfy (warning: quiet push; critical: DND-override, 1 h repeat) is now implemented, with a dormant Knarr seam for SMS/call escalation when `knarrWebhookUrl` is set. Broader delivery channels (Slack, email) remain future work.
- **Broader alerting rules** — beyond the self-health set, app/runtime alerts
  (pod crashlooping, node pressure across non-heimdall namespaces). The chart's
  default rules cover much of this; this item tracks any heimdall-curated
  additions that emerge from incident patterns.
