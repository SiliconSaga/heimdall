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
| `retentionDays` | `15` | Log and trace retention period |
| `storageSize` | `10Gi` | Prometheus PVC size |
| `lokiStorageSize` | `5Gi` | Loki PVC size |
| `tempoStorageSize` | `5Gi` | Tempo PVC size |
| `thanosEnabled` | `false` | Enable Thanos (not yet implemented) |

## Sending data to Heimdall

**Metrics:** Add standard Prometheus annotations or `ServiceMonitor` CRs to your
deployment. Prometheus auto-scrapes based on the operator's configuration.

**Logs:** Loki collects from the cluster automatically (via the canary/agent).
Query in Grafana Explore with LogQL, e.g. `{namespace="your-app"}`.

**Traces:** Point your app's OTLP exporter to:
- gRPC: `heimdall-<id>-tempo.heimdall.svc:4317`
- HTTP: `heimdall-<id>-tempo.heimdall.svc:4318`

## Current status

Phase 1 — homelab with filesystem storage, no SSO. See
[docs/architecture.md](docs/architecture.md) for the full phase roadmap
including S3/Garage backend, Thanos, and OIDC/Keycloak integration.
