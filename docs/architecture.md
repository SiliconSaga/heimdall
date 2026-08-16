# Heimdall — Architecture & Design

Deep architectural details for the Heimdall observability stack.
For quickstart and usage, see the [README](../README.md).

## Composition Pipeline

The Crossplane Composition (`crossplane/composition.yaml`) uses
`function-go-templating` to deploy and configure eight steps:

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
6. **Blackbox Exporter** (Provider-Helm Release + Provider-Kubernetes Objects) — black-box HTTP probing, plus a fixed-name `heimdall-blackbox` alias Service and a worked-example `Probe` for `artifactory.terasology.io`. See [Black-box Probing](#black-box-probing) below.
7. **Ingress Routes** (Provider-Kubernetes Objects) — Traefik IngressRoutes for
   Grafana and Prometheus. The base domain defaults to
   `EnvironmentConfig/cluster-identity` (loaded into the pipeline context by
   `function-environment-configs`); the Claim's `domain` parameter is an
   optional override.
8. **Auto-ready** — marks the composite resource Ready when all children are.

### Discovery selectors

This Prometheus discovers `ServiceMonitor`, `PodMonitor` and `Probe` resources **cluster-wide**, via `serviceMonitorSelectorNilUsesHelmValues`, `podMonitorSelectorNilUsesHelmValues` and `probeSelectorNilUsesHelmValues` all set to `false`. Consumers therefore need **no** `release` label — which matters because that label embeds a composite suffix that is random per cluster and unknowable to a resource authored in another repository.

The self-health `PrometheusRule` still carries `release: <name>-kube-prometheus`, because rule discovery (`ruleSelectorNilUsesHelmValues`) is deliberately left at its default: rules are authored by this composition, so scoping them is correct.

Grafana data sources are wired inline in the kube-prometheus-stack values:
- Prometheus (default, auto-discovered by sidecar)
- Loki (with trace-to-log derivedFields linking to Tempo)
- Tempo (with tracesToLogs and serviceMap linking back)

## Alerting & Notification

AlertManager routes firing alerts by severity to ntfy (in-cluster at `http://ntfy.ntfy.svc.cluster.local/heimdall-alerts?template=heimdall`), with the `critical` route on a 1 h repeat interval. The `?template=heimdall` query selects ntfy's server-side message template (shipped by Nidavellir), which maps `severity`→ntfy priority — `critical`→5 (pierces Do Not Disturb), `warning`→3 (quiet) — and formats a readable title/body from the webhook JSON. This sidesteps AlertManager's inability to set ntfy's `Priority`/`Title` headers on a `webhook_configs` post; see the [alert-formatting design](https://github.com/SiliconSaga/nidavellir/blob/main/docs/plans/2026-05-25-ntfy-alert-formatting-design.md). For flood control the route tree blackholes the default (a `null` receiver with no integrations); only `critical` and `warning` reach ntfy. ntfy is deployed as a 0-replica standby in the homelab via Nidavellir — delivery only succeeds where ntfy is active, which is expected.

A dormant Knarr escalation seam is wired into the `ntfy-critical` receiver as a second `webhook_configs` entry. When the Claim's `knarrWebhookUrl` parameter is unset the seam emits nothing (gated by `{{- if }}` in the go-template, so no inert placeholder URL is rendered). When set, Knarr receives the standard AlertManager webhook v4 payload and handles SMS/call escalation for critical alerts. The full notification routing design is documented at https://github.com/SiliconSaga/nidavellir/blob/main/docs/plans/2026-05-21-alert-notification-routing-design.md.

## Black-box Probing

Metrics, logs and traces all describe cluster internals. None of them answers "is the URL a user actually visits responding?" — the gap that let `artifactory.terasology.io` stay down for roughly fourteen hours on 2026-07-27 while `KubePodCrashLooping` fired correctly the whole time, at `warning`.

A `Probe` is the unit of "a service I care about". It names a target URL and the fixed prober address `heimdall-blackbox.heimdall.svc:9115`; the Prometheus Operator turns it into a scrape job against the Blackbox Exporter. Authoring one is documented in the [README](../README.md#watching-a-service).

**The alias Service is load-bearing.** Composition Helm releases are named from the composite (`heimdall-<xrsuffix>-…`) with a suffix that is random per cluster, so a `Probe` written elsewhere cannot name the generated Service. The `heimdall-blackbox` alias is identical on every cluster and exists solely so a probe stays a file someone writes without consulting a cluster. If its selector ever stops matching the exporter's pods, every probe silently stops running while the exporter itself still reports healthy — which is why `tests/e2e/blackbox-exporter-running` asserts the *endpoint* resolves rather than merely that the deployment is up.

### The severity model

Probing supplies the axis that makes severity principled rather than arbitrary:

| Signal | Severity | Reasoning |
|--------|----------|-----------|
| Internal state (crashloops, PVC fill, restarts) | `warning` | Informs diagnosis. Whether it matters depends entirely on *which* workload. |
| Black-box unreachability | `critical` | Unambiguous: users are affected right now. Earns priority 5 and the DND bypass. |

`HeimdallWatchedServiceDown` uses `for: 3m` — long enough to ride out a rolling restart or brief node blip, short enough to page within minutes.

### Alert hygiene

`kubeControllerManager`, `kubeScheduler`, `kubeProxy` and `kubeEtcd` are disabled at chart level. They are not scrape-exposed on **either** environment — GKE hides the managed control plane, and rancher-desktop k3s does not expose them either — so their rules fired permanently at `critical`, rendering as DND-piercing priority 5 on an hourly repeat. That noise is why the ntfy app was muted, and therefore why a genuine outage went unseen. Disabling at chart level removes rule and `ServiceMonitor` together; an inhibit rule would leave both evaluating and visible.

`coreDns` is environment-conditional rather than off, because the two clusters genuinely differ: k3s runs real CoreDNS exposing metrics on `:9153`, while GKE runs kube-dns, which does not.

The health of this is measurable: `ALERTS{alertstate="firing", severity="critical"}` should normally be empty. A permanently non-empty critical set means hygiene has regressed.

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
| CoreDNS scraping | enabled — real CoreDNS on `:9153` | disabled — kube-dns does not expose it |
| ntfy delivery | cold standby (`replicas: 0`), so AlertManager delivery fails by design | active |

## Resource Estimates

Baseline homelab (single replica, no Thanos):

| Component | CPU Request | Memory Request |
|-----------|-------------|----------------|
| Prometheus | 250m | 512Mi |
| Grafana | 100m | 128Mi |
| AlertManager | 50m | 64Mi |
| Loki (monolithic) | 250m | 256Mi |
| Tempo | 250m | 256Mi |
| Blackbox Exporter | 10m | 32Mi |
| **Total** | **~910m** | **~1.25Gi** |

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
- **Uptime Kuma** — click-to-add monitors and a shareable status page, layered
  on top of the `Probe` primitive rather than replacing it. The original
  cross-environment conception (each environment watching the other) is blocked
  on a 24/7 homelab box that does not exist; running it in GKE is the available
  option, with the caveat that it cannot detect the cluster it lives in failing.
- **Dead-man's-switch** — the `Watchdog` alert already fires continuously by
  design and is currently routed to the `null` receiver. Pointing it at an
  external heartbeat service makes total cluster loss detectable without a
  second site. Roughly ten lines of config, no new infrastructure.
- **Heimdall Overview dashboard** — one wall-readable dashboard leading with
  watched-service status, then requests-vs-usage, then top restarters. The 28
  bundled dashboards already cover the underlying panels; the gap is a single
  opinionated view.
- **Request right-sizing loop** — a weekly check writing p95/max per workload to
  a git-backed observations file, making aggressive request compression safe on
  a cluster whose node shape is fixed by a committed-use agreement.

  These four, plus the shipped probing and hygiene work, are specified in
  [`docs/plans/2026-07-27-alerting-hygiene-and-service-probes-design.md`](plans/2026-07-27-alerting-hygiene-and-service-probes-design.md).
- **Broader notification channels** — AlertManager→ntfy routing with severity→priority, server-side formatting, and flood-control filtering is **shipped** (see [Alerting & Notification](#alerting--notification)). Still future: additional delivery channels (Slack, email) and activating the wired-but-dormant Knarr SMS/call escalation seam.
- **Broader alerting rules** — beyond the self-health set, app/runtime alerts
  (pod crashlooping, node pressure across non-heimdall namespaces). The chart's
  default rules cover much of this; this item tracks any heimdall-curated
  additions that emerge from incident patterns.
