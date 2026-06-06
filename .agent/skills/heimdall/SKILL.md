---
name: heimdall
description: "Use when wiring alerts for a new component, claiming a HeimdallStack, or asking 'why doesn't <X> live in Heimdall' about the observability composition. Captures the judgment calls and the one cross-component trap — severity → ntfy priority is in Nidavellir's ntfy template, NOT in Heimdall — that catches first-time alert-wirers."
---

# heimdall

Heimdall is a thin Crossplane composition wrapping kube-prometheus-stack + Loki + Tempo. Most of the deep wiring lives elsewhere; this skill captures the seams, judgment calls, and traps that aren't obvious from reading `crossplane/composition.yaml` alone.

## The "Wait, where does THAT live?" trap

**Severity → ntfy priority is NOT in Heimdall.** It's server-side in `components/nidavellir/ntfy/heimdall-template.yaml` (workspace path; from inside the heimdall repo alone it's at `../nidavellir/`). AlertManager just POSTs its default envelope to ntfy with `?template=heimdall`; the template renders the `priority` field server-side based on the `severity` label.

Why this matters: from inside this Heimdall repo, grepping `priority` under `crossplane/` (or anywhere else in-repo) returns nothing. First-time wirers waste ~20 min searching here before realizing the mapping is defined server-side in the sibling Nidavellir component's ntfy template. This skill exists largely to short-circuit that mistake.

## When to Use

- A new component needs alerts wired up (the answer is: PrometheusRule with `severity` label on your side, nothing to change in Heimdall).
- Adjusting severity → priority — jump straight to Nidavellir's `heimdall-template.yaml`.
- Enabling the Knarr SMS/call escalation seam (dormant by default).
- Understanding why per-environment differences are deliberately minimal.

NOT for AM routing-tree idioms / Watchdog / amtool — sibling skill [`alertmanager-config`](../alertmanager-config/SKILL.md). NOT for kube-prometheus-stack chart wiring / `release:` label gotcha / GKE dual-stack-cost — sibling skill [`kube-prometheus-stack`](../kube-prometheus-stack/SKILL.md).

## Cross-component Path Convention

`components/...` references are **workspace-relative** — they resolve in the yggdrasil checkout that hosts this component. From inside the heimdall repo alone they map to `../<name>/`. Run `ws clone <name>` from the workspace root to materialize a sibling.

## Judgment Calls Worth Knowing

Decisions baked into the current composition that aren't self-evident:

- **`retentionDays` defaults to 7 as a stopgap** — fallout from the 2026-05-15 Prometheus PVC crashloop. The proper fix is object-storage migration (Phase-2 `objectStoreBucket`). Don't bump the default blindly; longer retention on the current PVC layout risks re-hitting the crashloop.
- **Phase-2 design fields aren't in the XRD yet.** `oidcEnabled` and `objectStoreBucket` exist in design notes but not in `crossplane/xrd.yaml`'s schema. Setting them in a claim doesn't silently no-op at composition time — they get dropped by **schema pruning** before the composition ever sees them. Wire the XRD first.
- **Knarr seam is criticals-only by design.** The composition conditionally appends a second webhook to the critical receiver, gated on `knarrWebhookUrl`. Warnings deliberately don't escalate. To change that, edit the composition — not a values override. Knarr design: `realms/realm-siliconsaga/docs/plans/2026-04-02-knarr-design.md`.
- **Per-environment branching is replicas-only.** Homelab vs GKE varies one Helm value (Prometheus replicas). Everything else flows through `cluster-identity` EnvironmentConfig — read by the composition's `load-cluster-identity` step into `apiextensions.crossplane.io/environment`. Don't add env branches in the AM config block; push variability to the ntfy template (Nidavellir) or to the cluster-identity EnvironmentConfig instead.
- **AM config lives inline in the composition's Helm values**, not in a separate ConfigMap. The Prometheus Operator renders it into a Secret and reloads via `POST /-/reload`. Editing the rendered Secret directly gets overwritten on next reconcile — change the composition (or the claim's Helm-values override).

## Where to Read the Current State

In-repo (run from the heimdall checkout):

- `crossplane/xrd.yaml` — current claim parameter schema (defaults, types). Authoritative.
- `crossplane/claim.yaml` — example claim.
- `crossplane/composition.yaml` — the kube-prometheus-stack values, AM config, and Knarr conditional. Grep for `alertmanager:` to find the routing block; grep for `knarrWebhookUrl` to find the seam; grep for `prometheusSpec` to find the per-env branch.

Cross-repo (yggdrasil workspace — requires `ws clone`, or follow the GitHub links below):

- Sibling skills: [`alertmanager-config`](../alertmanager-config/SKILL.md), [`kube-prometheus-stack`](../kube-prometheus-stack/SKILL.md).
- [`SiliconSaga/nidavellir: ntfy/heimdall-template.yaml`](https://github.com/SiliconSaga/nidavellir/blob/main/ntfy/heimdall-template.yaml) — the severity → priority truth source (workspace path: `components/nidavellir/ntfy/heimdall-template.yaml`).
- Realm narrative: `docs/stack-tier-2.md` in [`SiliconSaga/realm-siliconsaga`](https://github.com/SiliconSaga/realm-siliconsaga) (the file lands on the realm's `main` branch when realm PR #9 merges; until then, view it on the open PR or `ws clone realm-siliconsaga`).
