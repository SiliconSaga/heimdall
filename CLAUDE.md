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

Planned. No Crossplane resources, manifests, or ArgoCD Application yet.
`heimdall-app.yaml` is a TODO in `nidavellir/apps/kustomization.yaml`.
