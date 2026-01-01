# Heimdall Design Document

## 1. Executive Summary

**Heimdall** is the centralized **Observability and Telemetry Platform** for the Yggdrasil ecosystem. It is designed as a "Platform-as-a-Product," offering self-service observability capabilities to other teams and services.

Ideally, Heimdall acts as the **vigilant guardian**: it sees everything (metrics, logs, traces) but relies on trusted partners for its data persistence and messaging needs.
Specifically, it delegates robust, high-availability data infrastructure (Kafka, Redis/Valkey) to the **Mimir** project.

## 2. Architecture Overview

The architecture follows a strictly layered approach to separate **application logic** (Observability) from **data infrastructure** (Storage/Queues) and **control plane** (Orchestration).

### 2.1 Core Stack (The Application)

The core of Heimdall is built upon the **Panoptes** stack configurations. It provides:

*   **Metrics**: Prometheus (via kube-prometheus-stack) & Thanos (Long-term storage).
*   **Visualization**: Grafana.
*   **Alerting**: AlertManager.
*   **Logging**: Loki.
*   **Tracing**: Jaeger.

### 2.2 Data Layer (The Dependency)

Heimdall **does not** own the lifecycle of its heavy data components. Instead, it consumes them as services from the **Mimir** project.

*   **Streaming/Queuing**: Uses **Kafka** (hosted by Mimir/Strimzi) for reliable metric and log ingestion pipelines.
*   **Caching**: Uses **Redis/Valkey** (hosted by Mimir) for caching query results and task queues (e.g., Celery).

### 2.3 Orchestration (The Control Plane)

**Crossplane** serves as the unifying API. It manages the detailed wiring between the Core Stack and the Data Layer, ensuring that secrets, endpoints, and configurations are injected securely at deployment time.

## 3. Component Design

The platform implementation leverages Crossplane's Composite Resource Definition (XRD) model to offer a clean API.

### 3.1 The API: `HeimdallTelemetryStack`

Teams request observability via a high-level Claim: `HeimdallTelemetryStack`.

This abstraction hides the complexity of:

*   Deploying Helm charts.
*   Provisioning topics.
*   configuring OIDC sidecars.

### 3.2 The Composition: Wiring It Together

The Composition acts as the glue code. Its responsibilities are:

1.  **Deployment**: Instantiates the Panoptes Helm Chart.
2.  **Discovery**: Locates the Mimir-provisioned resources (Kafka Clusters, Redis Clusters).
3.  **Binding**: Extracts connection details (Secrets, Hostnames) from Mimir resources.
4.  **Injection**: Patches these details into the Panoptes Helm `values.yaml` via `Provider-Helm`.

#### Secret Injection Pattern

Secure connection to Mimir services is handled via Crossplane `FromSecret` patches:

*   **Kafka**: The Composition finds the Strimzi User Secret (from Mimir) and injects the TLS certificates and Bootstrap Servers into the Panoptes configuration.
*   **Redis**: The Composition finds the Redis Operator Secret (from Mimir) and injects the Host, Port, and Password.

## 4. Service Consumption Models

Heimdall supports versatile consumption patterns thanks to its decoupled design:

### Scenario A: Full Platform Deployment

*   **User**: Platform Admin or SRE Team.
*   **Action**: Applies `Claim: HeimdallTelemetryStack`.
*   **Result**: Deploys the full observability suite (Prometheus, Grafana, etc.) wired to the shared Kafka and Redis backend.

### Scenario B: Shared Infrastructure Usage

*   **User**: "Demicracy" Team (Application Devs).
*   **Action**: Applies `Claim: KafkaTopic` (referencing the Mimir Kafka cluster).
*   **Result**: The team gets a dedicated, secure topic on the shared, high-availability Kafka cluster without needing to maintain their own Kafka infrastructure.

### Scenario C: App-Specific Caching

*   **User**: New Microservice Team.
*   **Action**: Applies `Claim: RedisCache`.
*   **Result**: Provisions a dedicated User/ACL on the shared Mimir Valkey cluster, providing a consistent caching layer without operational overhead.

## 5. Technical Stack

| Category | Component | Source/Manager | Purpose |
| :--- | :--- | :--- | :--- |
| **Control Plane** | Crossplane | Platform | Orchestration & API |
| **Metrics** | Prometheus Operator | Heimdall | Metric Collection |
| **Visualization** | Grafana | Heimdall | Dashboards |
| **Logging** | Loki | Heimdall | Log Aggregation |
| **Tracing** | Jaeger | Heimdall | Distributed Tracing |
| **Streaming** | **Kafka** | **Mimir** | Data Pipeline Backbone |
| **Caching** | **Valkey** (Redis) | **Mimir** | High-perf Caching |
| **Storage** | MinIO / Garage | Infrastructure | Object Storage (S3) |
