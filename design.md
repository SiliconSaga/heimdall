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

### 2.2 Object Storage Backend

Loki, Tempo, and Thanos all require S3-compatible object storage for their data backends:

*   **Homelab**: Garage (deployed by Nordri, Tier 1).
*   **GKE**: Google Cloud Storage (GCS).

The storage endpoint, bucket, and credentials are injected at deployment time via the
Crossplane Composition.

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
| `objectStoreBucket` | string | `"heimdall"` | S3 bucket name for Loki, Tempo, and Thanos |
| `oidcEnabled` | boolean | `false` | Enable Grafana OIDC (requires Keycloak endpoint) |

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

### Planned Test Cases

| Test | Validates |
| :--- | :--- |
| `stack-deploys` | `HeimdallStack` claim reaches `Ready` state |
| `grafana-reachable` | Grafana UI responds on expected endpoint |
| `prometheus-targets` | Prometheus has active scrape targets |
| `loki-ingestion` | Logs are queryable via the Loki API |
| `tempo-traces` | Traces are queryable via the Tempo API (stretch goal) |

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
