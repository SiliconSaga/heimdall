# Heimdall Design Document

## 1. Executive Summary

**Heimdall** is the centralized **Observability and Telemetry Platform** for the Yggdrasil
ecosystem. It provides metrics, logs, traces, and alerting via the Grafana LGTM stack
(Loki, Grafana, Tempo, Prometheus) with optional Thanos for long-term metric retention.

Deployed as a **Tier 2 (Nidavellir)** component via ArgoCD, Heimdall uses Crossplane to
offer self-service observability through a single Kubernetes Claim. It is intentionally
positioned as a late-phase component — everything will eventually feed into it, but nothing
requires it to provision.

## 2. Architecture Overview

### 2.1 Core Stack

Built on the Grafana observability ecosystem:

*   **Metrics**: kube-prometheus-stack (Prometheus Operator + Grafana + AlertManager).
*   **Logging**: Loki (with Alloy or Promtail for collection).
*   **Tracing**: Tempo.
*   **Long-term Metrics**: Thanos (optional — recommended for GKE, deferrable on homelab).
*   **Visualization**: Grafana (bundled with kube-prometheus-stack).

### 2.2 Storage Backend (Progressive)

Storage follows a progressive strategy, matching the overall deployment phases:

1.  **Phase 1** (initial homelab): Local filesystem with PVCs. Simpler to deploy, no
    dependency on Garage or S3 credentials. Suitable for single-node k3d/k3s clusters.
2.  **Phase 2** (production homelab): S3-compatible object storage via Garage (deployed
    by Nordri, Tier 1). Enables horizontal scaling and durable retention.
3.  **GKE**: Google Cloud Storage (GCS) with HMAC credentials or Workload Identity.

The Crossplane Composition can be extended to inject S3 endpoint, bucket name, and
credentials when transitioning to Phase 2. The `objectStoreBucket` and `oidcEnabled`
Claim parameters are deferred until those phases.

### 2.3 Authentication (Progressive)

Heimdall follows a progressive authentication strategy:

1.  **Phase 1** (initial deployment): Grafana uses built-in admin credentials. No SSO.
2.  **Phase 2** (after Keycloak is available): Grafana OIDC integration for single sign-on.

Grafana supports OIDC natively via `grafana.ini` configuration — no sidecar proxy is
required. The Crossplane Composition can conditionally patch OIDC settings when a
Keycloak endpoint is provided in the Claim parameters.

### 2.4 Orchestration

**Crossplane** serves as the unifying API. A Composition pipeline deploys the Helm charts
and wires object storage, Grafana data sources, and optional OIDC configuration.

## 3. Component Design

The platform implementation leverages Crossplane's Composite Resource Definition (XRD)
model to offer a clean API, consistent with Mimir's approach to data service provisioning.

### 3.1 The API: `HeimdallStack`

Teams request observability via a high-level Claim.

*   **API Group**: `heimdall.siliconsaga.org`
*   **Kind**: `HeimdallStack` (claim) / `XHeimdallStack` (composite)
*   **Version**: `v1alpha1`

#### Parameters

| Parameter | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `environment` | enum: homelab, gke | `homelab` | Target environment; controls storage backend and replica counts |
| `thanosEnabled` | boolean | `false` | Enable Thanos for long-term metric storage |
| `retentionDays` | integer | `15` | Log and trace retention period (days) |
| `storageSize` | string | `"10Gi"` | PVC size for Prometheus local storage |
| `lokiStorageSize` | string | `"5Gi"` | PVC size for Loki data |
| `tempoStorageSize` | string | `"5Gi"` | PVC size for Tempo data |

### 3.2 The Composition: Wiring It Together

The Composition uses `function-go-templating` to deploy and configure:

1.  **kube-prometheus-stack** (Helm): Prometheus, Grafana, AlertManager, default dashboards.
2.  **Loki** (Helm): Log aggregation with S3 backend.
3.  **Tempo** (Helm): Distributed tracing with S3 backend.
4.  **Thanos** (Helm, conditional): Long-term metric storage with S3 backend.

Each Helm release is wrapped in a `Provider-Helm` Release resource.

#### Object Storage Wiring

The Composition patches S3 endpoint, bucket name, and credentials into each component's
Helm values. On homelab this points to Garage's S3 API; on GKE to a GCS bucket with
HMAC credentials or Workload Identity.

#### Grafana Data Sources

The Composition auto-configures Grafana data sources for Prometheus, Loki, and Tempo so
that correlation between metrics, logs, and traces works out of the box. Exemplar links
from Prometheus to Tempo are configured for trace-to-metric correlation.

## 4. Service Consumption

### Scenario A: Full Platform Deployment

*   **User**: Platform Admin or SRE Team.
*   **Action**: Applies `Claim: HeimdallStack`.
*   **Result**: Full observability suite deployed and wired to object storage.

### Scenario B: Service-Level Monitoring

*   **User**: Application team deploying a new service.
*   **Action**: Adds standard Prometheus annotations or `ServiceMonitor` CRs to their
    deployment.
*   **Result**: Metrics automatically scraped by Prometheus; team creates Grafana dashboards
    against the shared instance.

### Scenario C: Distributed Tracing Integration

*   **User**: Microservice team.
*   **Action**: Instruments their app with the OpenTelemetry SDK, points the OTLP exporter
    to the Tempo endpoint (`tempo.heimdall.svc:4317`).
*   **Result**: Traces visible in Grafana via the Tempo data source, correlated with logs
    and metrics.

## 5. Technical Stack

| Category | Component | Source | Purpose |
| :--- | :--- | :--- | :--- |
| **Control Plane** | Crossplane | Nordri (Tier 1) | Orchestration & API |
| **Metrics** | kube-prometheus-stack | Heimdall | Prometheus + Grafana + AlertManager |
| **Logging** | Loki | Heimdall | Log aggregation |
| **Tracing** | Tempo | Heimdall | Distributed tracing (OTLP) |
| **Long-term Storage** | Thanos | Heimdall (optional) | Metric retention beyond Prometheus |
| **Object Storage** | Garage / GCS | Nordri / Cloud | S3 backend for Loki, Tempo, Thanos |

## 6. Deployment

### 6.1 Namespace

All Heimdall resources deploy to the `heimdall` namespace.

### 6.2 ArgoCD Application

Heimdall is deployed as a Nidavellir app-of-apps component via `heimdall-app.yaml` in
`nidavellir/apps/`.

*   **Sync wave**: `10` (after Vegvisir at wave 5; after Mimir when it is added).
*   **Source**: Internal Gitea during bootstrap; swap to GitHub when stable.
*   **Path**: `heimdall/crossplane/` (XRDs, Compositions, and the platform Claim).

### 6.3 Bootstrap Dependencies

| Dependency | Source | Required? |
| :--- | :--- | :--- |
| Crossplane + Provider-Helm + Provider-Kubernetes | Nordri (Tier 1) | Yes |
| `function-go-templating` + `function-auto-ready` | Nordri (Tier 1) | Yes |
| Object storage (Garage) | Nordri (Tier 1, homelab only) | Yes (homelab) |
| Keycloak | Nidavellir (Tier 2) | No (progressive OIDC) |

Heimdall has **no hard dependency on Mimir**. It can deploy independently once Crossplane
and object storage are available.

### 6.4 Environment Differences

| Aspect | Homelab (k3s) | GKE |
| :--- | :--- | :--- |
| Object storage | Garage S3 | GCS |
| Storage class | `local-path` / Longhorn | `standard-rwo` |
| Prometheus replicas | 1 | 2 |
| Thanos | Defer initially | Recommended |
| Loki mode | SingleBinary (monolithic) | SimpleScalable or distributed |
| Ingress | Traefik (k3s built-in) | Traefik (Nordri-installed) |

## 7. Testing Strategy

Heimdall uses **kuttl** for Kubernetes-native e2e testing, consistent with Mimir and
Vegvisir.

### Test Cases (kuttl)

| Test | Validates |
| :--- | :--- |
| `stack-deploys` | ArgoCD app Synced+Healthy, `HeimdallStack` claim Ready+Synced |
| `grafana-reachable` | Grafana health endpoint responds, Prometheus/Loki/Tempo data sources configured |
| `prometheus-targets` | Prometheus has at least one active scrape target |
| `loki-ingestion` | Loki labels API returns success (ingestion pipeline functional) |
| `tempo-traces` | Traces are queryable via the Tempo API (stretch goal — not yet implemented) |

Run tests:

```bash
kubectl kuttl test --config kuttl-test.yaml
```

### Manual Verification

After deploying Heimdall, use these commands to explore the stack interactively.

**Grafana** (dashboards, data source exploration):

```bash
kubectl port-forward -n heimdall svc/heimdall-5ljlr-kube-prometheus-grafana 3000:80
# Open http://localhost:3000 — login: admin / admin
# Check: Dashboards → Browse → default dashboards from kube-prometheus-stack
# Check: Connections → Data sources → Prometheus, Loki, Tempo should all be listed
```

**Prometheus** (metrics, targets, alerts):

```bash
kubectl port-forward -n heimdall svc/heimdall-5ljlr-kube-promet-prometheus 9090:9090
# Open http://localhost:9090
# Check: Status → Targets — should show active scrape targets
# Try:   Graph → query `up` — shows all monitored endpoints
```

**Loki** (log queries via Grafana):

```bash
# Use the Grafana port-forward above, then:
# Explore → select Loki data source → Label browser → pick a label
# Try: {namespace="heimdall"} to see Heimdall's own logs
```

**Tempo** (traces via Grafana):

```bash
# Use the Grafana port-forward above, then:
# Explore → select Tempo data source → Search tab
# Note: traces only appear if an instrumented application is sending OTLP data
# to heimdall-5ljlr-tempo.heimdall.svc:4317 (gRPC) or :4318 (HTTP)
```

## 8. Resource Estimates

Baseline homelab deployment (single replica, no Thanos):

| Component | CPU Request | Memory Request |
| :--- | :--- | :--- |
| Prometheus | 250m | 512Mi |
| Grafana | 100m | 128Mi |
| AlertManager | 50m | 64Mi |
| Loki (monolithic) | 250m | 256Mi |
| Tempo | 250m | 256Mi |
| Alloy / Promtail | 100m | 128Mi |
| **Total** | **~1000m** | **~1.3Gi** |

These are starting points for low-volume usage. Node pool assignment or resource limit
increases can be applied as volume grows.
