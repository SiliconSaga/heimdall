# Heimdall — Architecture & Design

Deep architectural details for the Heimdall observability stack.
For quickstart and usage, see the [README](../README.md).

## Composition Pipeline

The Crossplane Composition (`crossplane/composition.yaml`) uses
`function-go-templating` to deploy and configure seven steps:

1. **kube-prometheus-stack** (Provider-Helm Release) — Prometheus, Grafana,
   AlertManager, node-exporter, kube-state-metrics, default dashboards. AlertManager is configured with a severity-routing tree: the default route is blackholed (a `null` receiver), `severity = "warning"` routes to `ntfy-warning`, and `severity = "critical"` routes to `ntfy-critical` (1 h repeat) plus, optionally, Knarr (SMS/call escalation) when `knarrWebhookUrl` is set on the Claim. Delivery posts to ntfy with `?template=heimdall`, which maps severity→priority (DND override for `critical`, quiet `warning`) and formats the body server-side; see [Alerting & Notification](#alerting--notification) below.
2. **Loki** (Provider-Helm Release) — Log aggregation in SingleBinary mode
   with filesystem storage and TSDB schema v13.
3. **Tempo** (Provider-Helm Release) — Distributed tracing with local storage,
   OTLP receivers on gRPC (4317) and HTTP (4318).
4. **OpenTelemetry Collector** (Provider-Helm Release) — log-shipper DaemonSet (one collector per node) from the `otel/opentelemetry-collector-k8s` distro. The `logsCollection` preset wires the filelog receiver tailing `/var/log/pods`, the `kubernetesAttributes` preset wires the k8sattributes processor (plus the ClusterRole/ServiceAccount it needs) to enrich each record with pod/namespace/node metadata, and a `config:` override adds an `otlphttp` exporter to Loki's native `/otlp` ingest (`auth_enabled: false`, no `X-Scope-OrgID` tenant header — SingleBinary Loki, no gateway). This is the log-collection path: workloads need only log to stdout.
5. **Self-health PrometheusRules** (Provider-Kubernetes Object) — Heimdall-scoped
   alerts: PVC fill (warn at 80%, critical at 90%), Prometheus restart-storm,
   WAL corruption, TSDB compaction failures. Labelled with
   `release: <name>-kube-prometheus` so kube-prometheus-stack's default rule
   selector picks them up. Designed for the
   [2026-05-15 incident class](https://github.com/SiliconSaga/yggdrasil/blob/main/docs/plans/2026-05-19-heimdall-monitoring-design.md);
   AlertManager notification routing follows in a separate arc.
6. **Ingress Routes** (Provider-Kubernetes Objects) — Traefik IngressRoutes for
   Grafana and Prometheus. The base domain defaults to
   `EnvironmentConfig/cluster-identity` (loaded into the pipeline context by
   `function-environment-configs`); the Claim's `domain` parameter is an
   optional override.
7. **Auto-ready** — marks the composite resource Ready when all children are.

Any future consumer that wants its metrics scraped must label its `ServiceMonitor` `release: <name>-kube-prometheus` (e.g. `heimdall-<id>-kube-prometheus`) so the kube-prometheus-stack operator's default selector discovers it — the same label fact documented above for the self-health PrometheusRules. No such consumer ships in this composition.

Grafana data sources are wired inline in the kube-prometheus-stack values:
- Prometheus (default, auto-discovered by sidecar)
- Loki (with trace-to-log derivedFields linking to Tempo)
- Tempo (with tracesToLogs and serviceMap linking back)

## Alerting & Notification

AlertManager routes firing alerts by severity to ntfy (in-cluster at `http://ntfy.ntfy.svc.cluster.local/heimdall-alerts?template=heimdall`), with the `critical` route on a 1 h repeat interval. The `?template=heimdall` query selects ntfy's server-side message template (shipped by Nidavellir), which maps `severity`→ntfy priority — `critical`→5 (pierces Do Not Disturb), `warning`→3 (quiet) — and formats a readable title/body from the webhook JSON. This sidesteps AlertManager's inability to set ntfy's `Priority`/`Title` headers on a `webhook_configs` post; see the [alert-formatting design](https://github.com/SiliconSaga/nidavellir/blob/main/docs/plans/2026-05-25-ntfy-alert-formatting-design.md). For flood control the route tree blackholes the default (a `null` receiver with no integrations); only `critical` and `warning` reach ntfy. ntfy is deployed as a 0-replica standby in the homelab via Nidavellir — delivery only succeeds where ntfy is active, which is expected.

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
- **Broader notification channels** — AlertManager→ntfy routing with severity→priority, server-side formatting, and flood-control filtering is **shipped** (see [Alerting & Notification](#alerting--notification)). Still future: additional delivery channels (Slack, email) and activating the wired-but-dormant Knarr SMS/call escalation seam.
- **Broader alerting rules** — beyond the self-health set, app/runtime alerts
  (pod crashlooping, node pressure across non-heimdall namespaces). The chart's
  default rules cover much of this; this item tracks any heimdall-curated
  additions that emerge from incident patterns.
