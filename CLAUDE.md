# Heimdall — Observability Stack (Tier 2 component)

Heimdall provides centralized observability (Prometheus, Grafana, Loki, Tempo, Thanos)
for the Yggdrasil ecosystem. Deployed by Nidavellir via ArgoCD.

**Full agent context:** [`yggdrasil/CLAUDE.md`](../yggdrasil/CLAUDE.md) and
[`yggdrasil/docs/ecosystem-architecture.md`](../yggdrasil/docs/ecosystem-architecture.md)

---

## Key Files

- `design.md` — Architecture and component design

## Dependencies

- **Crossplane** (Nordri, Tier 1) — orchestration engine
- **Object storage** (Garage on homelab, GCS on GKE) — backend for Loki, Tempo, Thanos
- **Keycloak** (optional) — OIDC for Grafana SSO when available

Heimdall has no hard dependency on Mimir (no Kafka or Redis needed).

## Status

Phase 1 (homelab, filesystem storage, no SSO). Crossplane resources exist:
- `crossplane/xrd.yaml` — `HeimdallStack` v1alpha1 XRD
- `crossplane/composition.yaml` — Pipeline composition (kube-prometheus-stack, Loki, Tempo)
- `crossplane/claim.yaml` — Homelab claim with defaults

`heimdall-app.yaml` exists in `nidavellir/apps/` but is commented out in
`kustomization.yaml` — uncomment to deploy.
