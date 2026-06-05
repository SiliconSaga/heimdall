---
name: heimdall
description: Use when claiming a Heimdall observability instance from another component (`XHeimdallStack` claim parameters), wiring up severity→ntfy-priority for a new alert, configuring the dormant Knarr SMS/call escalation seam, or understanding why the Heimdall composition is so thin (most operational depth defers to sibling skills `alertmanager-config` + `kube-prometheus-stack`). Critical seam: **severity→priority mapping is in Nidavellir's ntfy template, NOT in Heimdall** — easy to chase the wrong file otherwise.
---

# heimdall

## Overview

Heimdall is the SiliconSaga observability composition: a Crossplane `XHeimdallStack` XR that decomposes into kube-prometheus-stack + Loki + Tempo, with AlertManager wired to ntfy for phone push. The composition is **deliberately thin** — most of what bites you on AlertManager routing or kube-prometheus-stack chart wiring lives in the two sibling component skills. This skill captures only what's *unique to Heimdall's instantiation*: the claim parameter set, where the AM config lives inside the composition, the dormant Knarr escalation seam, and the one seam that consistently catches first-time alert-wirers off-guard.

## The "Wait, where does THAT live?" Seam

**Severity → ntfy priority mapping is NOT in Heimdall.** It's server-side in `components/nidavellir/ntfy/heimdall-template.yaml`. Heimdall's AlertManager only routes by `severity` matcher to differently-named webhook receivers (`ntfy-warning`, `ntfy-critical`); both POST AM's default envelope to the *same* ntfy URL with `?template=heimdall`, and ntfy's template renders the `priority` field server-side based on `severity` label.

Why this matters: a first-time alert-wirer naturally grep `priority` inside `components/heimdall/` and finds nothing, then assumes the template lives in the Helm values somewhere. It doesn't. Cross-component into Nidavellir.

## When to Use

- A new component needs alerts wired up — what claim params to set, where the routing happens.
- Adjusting severity→priority mapping (jump straight to Nidavellir's `heimdall-template.yaml`, not Heimdall).
- Enabling the **Knarr seam** (SMS/call escalation for criticals — dormant by default).
- Looking up the kube-prometheus-stack Helm values for Heimdall (they're baked inline in the composition, not in a separate values file).
- Understanding the homelab vs GKE branching in the composition (spoiler: it's just replicas).

NOT for AlertManager routing-tree idioms, Watchdog dead-man's-switch, webhook payload templating — sibling skill [`alertmanager-config`](../alertmanager-config/SKILL.md). NOT for the kube-prometheus-stack chart wiring, `release:` label requirement, RWO+Recreate strategy, GKE dual-stack-cost recipe — sibling skill [`kube-prometheus-stack`](../kube-prometheus-stack/SKILL.md).

## XHeimdallStack Claim Parameters

XR: `apiVersion: heimdall.siliconsaga.org/v1alpha1`, `kind: HeimdallStack` (claim) / `XHeimdallStack` (composite). Defined in `crossplane/xrd.yaml`; example claim in `crossplane/claim.yaml`.

Parameters under `spec.parameters`:

| Param | Type | Default | Purpose |
|---|---|---|---|
| `environment` | enum `homelab` / `gke` | from `EnvironmentConfig/cluster-identity` | Drives the few env-aware branches (currently just replica count). Don't override unless testing. |
| `thanosEnabled` | bool | `false` | Phase-2 pipeline step — Thanos for long-term metric storage (Thanos, not Grafana Mimir). Not wired yet beyond the XRD field. |
| `retentionDays` | int | `7` | **Stopgap** from the 2026-05-15 Prometheus PVC crashloop — short retention until storage is solved properly via object storage. Bump deliberately, not blindly. |
| `storageSize` | string | env default | Prometheus PVC size. |
| `lokiStorageSize` / `tempoStorageSize` | string | env default | Loki + Tempo PVC sizes. |
| `domain` | string | env default | Override for the Grafana/Prometheus hostnames. |
| `knarrWebhookUrl` | string | unset (dormant) | The Knarr escalation seam — see below. |

Phase-2 params noted in the design but **not yet implemented**: `oidcEnabled` (Keycloak SSO for Grafana), `objectStoreBucket` (Garage/GCS for Loki/Tempo + Thanos). Don't set these in claims until they're wired through the composition.

## Where the AlertManager Config Lives

Inline in `crossplane/composition.yaml`, around lines 120-158, baked as kube-prometheus-stack Helm values:

```yaml
alertmanager:
  config:
    route:
      receiver: 'null'
      routes:
        - matchers: ['severity = "critical"']
          receiver: ntfy-critical
        - matchers: ['severity = "warning"']
          receiver: ntfy-warning
        # plus Watchdog route, see sibling alertmanager-config skill
    receivers:
      - name: ntfy-critical
        webhook_configs:
          - url: 'http://ntfy.ntfy.svc.cluster.local/heimdall-alerts?template=heimdall'
            send_resolved: true
          # Knarr seam — see below
      - name: ntfy-warning
        webhook_configs:
          - url: 'http://ntfy.ntfy.svc.cluster.local/heimdall-alerts?template=heimdall'
            send_resolved: true
```

The Prometheus Operator renders this into a Secret and reloads AlertManager via `POST /-/reload` on change. Editing the rendered Secret directly gets overwritten — change the composition (or the claim's Helm-values override if the composition exposes one) and re-hydrate seed-Gitea.

**Why both receivers POST to the same URL with the same template:** the differentiation happens in ntfy's template (priority + tags), not in the URL. Routing-by-receiver-name is a leftover seam that lets us add per-severity webhook bridges later (e.g. attaching a fan-out to Knarr only on criticals — see below).

## The Knarr Seam (Dormant by Default)

`crossplane/composition.yaml` lines 155-158 conditionally appends a second webhook to the `ntfy-critical` receiver:

```text
{{- if .observed.composite.resource.spec.parameters.knarrWebhookUrl }}
- url: "{{ .observed.composite.resource.spec.parameters.knarrWebhookUrl }}"
  send_resolved: true
{{- end }}
```

When `knarrWebhookUrl` is unset (default), only ntfy gets criticals. When set, criticals fan out to a second webhook — Knarr implements the standard AlertManager webhook v4 receiver shape and is meant to handle SMS / phone-call escalation when ntfy push isn't enough (sleeping, DND, dead phone, etc.).

Knarr lives in a different workspace today (the user's m1 Mac per cross-machine Thalami) — design at `realms/realm-siliconsaga/docs/plans/2026-04-02-knarr-design.md`. To activate the seam: set `knarrWebhookUrl` in your HeimdallStack claim once Knarr is reachable from the cluster (likely via Tailscale operator on GKE).

The seam is **only on criticals** by design — warnings don't escalate. If you want warnings to also fan out, edit the composition (don't try to do it from a Helm values override).

## Per-Environment Differences

The notification path is **identical** on homelab vs GKE: same routing tree, same in-cluster ntfy URL, same Knarr gating. The only env branch in the composition (`composition.yaml` line ~64) bumps `prometheus.prometheusSpec.replicas` from 1 (homelab) to 2 (GKE). Everything else that varies (storage class, domain) flows through `EnvironmentConfig/cluster-identity` — see sibling `crossplane-compositions` skill in Nordri.

If you're tempted to add another env branch in the AM config — don't. Add the variability to ntfy's template (Nidavellir) or to the cluster-identity EnvironmentConfig instead.

## Common Mistakes

- **Grepping `priority` inside `components/heimdall/`** when wiring a new alert — finds nothing, wastes ~20 minutes. The mapping is in `components/nidavellir/ntfy/heimdall-template.yaml`. (This skill exists largely to short-circuit that mistake.)
- **Setting `oidcEnabled` or `objectStoreBucket` in a claim** — those are Phase-2 XRD fields not yet wired through the composition. The claim accepts them but they no-op.
- **Bumping `retentionDays` to 30+ without checking storage** — the 7-day default is a stopgap from a real crashloop. Object storage migration (Phase 2) is the proper fix; until then, longer retention risks the PVC filling again.
- **Editing the rendered AlertManager Secret directly** — gets overwritten on next Operator reconcile. Change the composition (or the claim's Helm-values override).
- **Assuming the homelab/GKE difference matters for AM routing** — it doesn't. Don't add env branches in the AM config block. Replicas-only is the contract.

## Sources

- `crossplane/xrd.yaml` + `crossplane/claim.yaml` — claim parameter shape.
- `crossplane/composition.yaml` — the kube-prometheus-stack values, AM config, and Knarr seam. Lines 64 (env replica branch), 120-158 (AM config block), 155-158 (Knarr gating).
- Sibling skills: [`alertmanager-config`](../alertmanager-config/SKILL.md) for routing-tree idioms + Watchdog + amtool; [`kube-prometheus-stack`](../kube-prometheus-stack/SKILL.md) for chart wiring + `release:` label + GKE dual-stack-cost.
- Nidavellir's ntfy template: `components/nidavellir/ntfy/heimdall-template.yaml` (the severity→priority truth source).
- Knarr design: `realms/realm-siliconsaga/docs/plans/2026-04-02-knarr-design.md`.
- Realm context: `realms/realm-siliconsaga/docs/stack-tier-2.md` (narrative).
