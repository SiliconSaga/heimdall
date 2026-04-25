Feature: Observability stack deployment
  As a platform operator
  I want a single HeimdallStack claim to deploy the full LGTM observability suite
  So that I get metrics, logs, and traces without manual chart wiring

  Scenario: HeimdallStack claim reaches Ready state
    Given a Kubernetes cluster with Crossplane and Provider-Helm
    When I apply a HeimdallStack claim with environment "homelab"
    Then the HeimdallStack reaches Ready and Synced status
    And three Helm releases are deployed (kube-prometheus-stack, loki, tempo)

  Scenario: Grafana is reachable with configured data sources
    Given a Ready HeimdallStack
    When I query the Grafana health endpoint
    Then Grafana responds with status "ok"
    And Prometheus, Loki, and Tempo data sources are configured

  Scenario: Prometheus has active scrape targets
    Given a Ready HeimdallStack
    When I query the Prometheus targets API
    Then at least one scrape target reports health "up"

  Scenario: Logs are queryable via Loki
    Given a Ready HeimdallStack
    When I query Loki for recent logs
    Then Loki returns log entries from the cluster
