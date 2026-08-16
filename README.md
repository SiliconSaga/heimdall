# Heimdall

Centralized observability for the Yggdrasil ecosystem. Deploys the Grafana
LGTM stack (Loki, Grafana, Tempo, Prometheus) via a single Crossplane Claim.

## What you get

| Signal | Tool | Access |
|--------|------|--------|
| Metrics | Prometheus + AlertManager | http://prometheus.localhost |
| Logs | Loki (SingleBinary) | via Grafana Explore |
| Traces | Tempo (OTLP) | via Grafana Explore |
| Dashboards | Grafana | http://grafana.localhost |

Grafana comes pre-configured with all data sources wired, including
trace-to-log correlation (Tempo → Loki) and exemplar links (Prometheus → Tempo).

## Deploy

Heimdall is deployed automatically by ArgoCD as part of the Nidavellir
app-of-apps (sync wave 10). Prerequisites:

- Crossplane + Provider-Helm + Provider-Kubernetes (Nordri, Tier 1)
- `function-go-templating` + `function-auto-ready` (Nordri, Tier 1)

Once those are present, ArgoCD syncs `crossplane/` which applies the XRD,
Composition, and Claim. The Claim triggers Crossplane to install three Helm
charts (kube-prometheus-stack, Loki, Tempo) and create Traefik IngressRoutes.

## Structure

```
crossplane/
  xrd.yaml           HeimdallStack v1alpha1 API definition
  composition.yaml   Pipeline: Helm releases + ingress routes + auto-ready
  claim.yaml         Homelab instance (defaults from EnvironmentConfig/cluster-identity)
docs/
  architecture.md    Deep design — phases, storage strategy, GKE differences
tests/
  e2e/               kuttl test cases (stack-deploys, grafana, prometheus, loki)
  features/          BDD scenarios (Gherkin)
test.sh              Docker-based kuttl runner for Windows
```

## Run tests

```bash
bash test.sh                       # all tests
bash test.sh --test stack-deploys  # one suite
```

Requires Docker and a running cluster with Heimdall deployed.

## Claim parameters

`environment`, `storageClass`, and `domain` are sourced from
`EnvironmentConfig/cluster-identity` (provisioned by Nordri per environment) and
do not need to be set on the claim. The composition reads them from the pipeline
context via `function-environment-configs`. Set `environment` or `domain` on the
claim only when overriding the cluster default.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `environment` | from cluster-identity | Optional override. `homelab` or `gke` — controls Prometheus replicas |
| `domain` | from cluster-identity | Optional override. Base domain for ingress hosts |
| `retentionDays` | `7` | Log and trace retention period (days). Stopgap default until the S3/Garage backend lands |
| `storageSize` | `10Gi` | Prometheus PVC size |
| `lokiStorageSize` | `5Gi` | Loki PVC size |
| `tempoStorageSize` | `5Gi` | Tempo PVC size |
| `thanosEnabled` | `false` | Enable Thanos (not yet implemented) |

## Sending data to Heimdall

**Metrics:** Add standard Prometheus annotations or `ServiceMonitor` CRs to your
deployment. Prometheus auto-scrapes based on the operator's configuration.

**Logs:** Nothing to wire up. The OpenTelemetry Collector DaemonSet (deployed by the composition) tails every pod's stdout cluster-wide from `/var/log/pods` and ships it to Loki via OTLP — your workloads just need to log to stdout. Query in Grafana Explore with LogQL using the OTLP-derived labels, e.g. `{k8s_namespace_name="your-app"}` (Loki stores the OTel `k8s.namespace.name` attribute with dots replaced by underscores).

**Traces:** Point your app's OTLP exporter to:
- gRPC: `heimdall-<id>-tempo.heimdall.svc:4317`
- HTTP: `heimdall-<id>-tempo.heimdall.svc:4318`

## Watching a service

Metrics, logs and traces all describe what is happening *inside* the cluster. To
answer "is the URL people actually visit responding?", add a `Probe`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: Probe
metadata:
  name: my-service
  namespace: heimdall
spec:
  prober:
    url: heimdall-blackbox.heimdall.svc:9115
  module: http_2xx
  interval: 30s
  targets:
    staticConfig:
      static:
        - https://my-service.example.org/healthz
```

`heimdall-blackbox.heimdall.svc:9115` is a fixed name on every cluster — use it
verbatim. (The Blackbox Exporter's own Service carries the random per-cluster
composite suffix, so it can't be referenced from another repo; this alias exists
precisely so a probe is a file you write without consulting the cluster.)

Alerts come with it automatically, no extra wiring:

| Alert | Fires when | Severity |
|-------|-----------|----------|
| `HeimdallProbedServiceDown` | Probe fails for 3 minutes | warning → quiet push |
| `HeimdallWatchedServiceDown` | Same, but only for opted-in probes | **critical** → priority 5 |
| `HeimdallWatchedServiceSlow` | Response exceeds 5s for 10 minutes | warning |
| `HeimdallCertExpiringSoon` | TLS cert expires within 14 days | warning |
| `HeimdallProbeScrapeFailing` | Prometheus can't reach the exporter | **critical** |
| `HeimdallProbePipelineDown` | No probe series exist at all | **critical** |

### Opting in to critical

A probe added with the snippet above notifies **quietly**. To promote it to the
Do-Not-Disturb-piercing tier, add a `watched` label to its `staticConfig`:

```yaml
  targets:
    staticConfig:
      static:
        - https://my-service.example.org/healthz
      labels:
        watched: "true"
```

Critical is opt-in rather than default because probe discovery is cluster-wide:
without this, any probe anyone adds would page everybody at maximum priority,
which is precisely how an alerting channel becomes noise and then gets muted.

Note this label goes in **`spec.targets.staticConfig.labels`**, not the CR's
`metadata.labels` — only the former lands on the resulting metric series, which
is what the alert rules select on. A label in the wrong place fails silently: the
probe still works, it just never reaches critical.

The last two alerts exist because `probe_success == 0` cannot fire if the series
stops existing at all. They cover the exporter going unscrapeable and the whole
probe pipeline vanishing — the failure modes that would otherwise look like
silence.

Point the probe at a *readiness* endpoint rather than the site root where one
exists. Many applications serve a shell page early in startup, which would
report healthy while the service is still unusable.

**Why probe failure is the critical tier.** Internal signals stay at `warning`
and inform diagnosis; black-box unreachability is what earns `critical` and the
Do-Not-Disturb bypass. That split is deliberate — it is the difference between
"a pod is restarting" (often uninteresting) and "users are affected right now".

## Current status

Phase 1 — homelab with filesystem storage, no SSO. See
[docs/architecture.md](docs/architecture.md) for the full phase roadmap
including S3/Garage backend, Thanos, and OIDC/Keycloak integration.
