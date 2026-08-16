---
name: heimdall
description: "Use when wiring alerts for a new component, claiming a HeimdallStack, or asking 'why doesn't <X> live in Heimdall' about the observability composition. Captures the judgment calls and the one cross-component trap — severity → ntfy priority is in Nidavellir's ntfy template, NOT in Heimdall — that catches first-time alert-wirers."
---

# heimdall

Heimdall is a thin Crossplane composition wrapping kube-prometheus-stack + Loki + Tempo. Most of the deep wiring lives elsewhere; this skill captures the seams, judgment calls, and traps that aren't obvious from reading `crossplane/composition.yaml` alone.

## The "Wait, where does THAT live?" trap

**Severity → ntfy priority is NOT in Heimdall.** It's server-side in `components/nidavellir/ntfy/heimdall-template.yaml` (workspace path; from inside the heimdall repo alone it's at `../nidavellir/`). AlertManager just POSTs its default envelope to ntfy with `?template=heimdall`; the template renders the `priority` field server-side based on the `severity` label.

Why this matters: from inside this Heimdall repo, grepping `priority` under `crossplane/` (or anywhere else in-repo) returns nothing. First-time wirers waste ~20 min searching here before realizing the mapping is defined server-side in the sibling Nidavellir component's ntfy template. This skill exists largely to short-circuit that mistake.

## The second trap: probes need no `release` label, rules do

Discovery scope differs by object type here, and the asymmetry is deliberate:

- **`ServiceMonitor` / `PodMonitor` / `Probe`** — discovered **cluster-wide**. No `release` label. All three `*SelectorNilUsesHelmValues` are `false`.
- **`PrometheusRule`** — still scoped by `release: heimdall-<xrsuffix>-kube-prometheus`, because rules are authored by this composition.

Older docs said ServiceMonitors needed the label; heimdall#11 changed that and the probe equivalent followed later. If something you authored is silently not discovered, check which of the three knobs is actually set — they're independent, and setting two of three is the easy mistake.

## Watching a service (the probe primitive)

"Attach a monitor to a service I care about" = commit a `Probe` pointing at `heimdall-blackbox.heimdall.svc:9115`. Full example in the [README](../../README.md#watching-a-service).

**`heimdall-blackbox` is a hand-written alias Service, not the chart's.** The chart's own Service carries the composite suffix (`heimdall-<xrsuffix>-blackbox`), random per cluster, so a probe authored in another repo could never name it. The alias is the whole reason the primitive works cross-repo. If you find yourself "fixing" a probe by pointing it at the suffixed name, you've broken portability — fix the alias instead.

Silent-failure shape: if the alias selector stops matching, every probe stops running while the exporter still reports healthy and its Deployment stays 1/1. `tests/e2e/blackbox-exporter-running` asserts the *endpoint list* is non-empty for exactly this reason.

**Severity judgment:** internal signals (crashloops, PVC fill) stay `warning`; black-box unreachability is `critical`. That split is what earns the DND bypass honestly — a crashlooping pod in a dead namespace is not worth waking someone, an unreachable public URL is. Don't promote internal alerts to critical without a matching probe.

## When to Use

- A new component needs alerts wired up (the answer is: PrometheusRule with `severity` label on your side, nothing to change in Heimdall).
- Someone wants a service *watched* — that's a `Probe`, see above, not a PrometheusRule.
- Adjusting severity → priority — jump straight to Nidavellir's `heimdall-template.yaml`.
- Enabling the Knarr SMS/call escalation seam (dormant by default).
- Understanding why per-environment differences are deliberately minimal.

NOT for AM routing-tree idioms / Watchdog / amtool — sibling skill [`alertmanager-config`](../alertmanager-config/SKILL.md). NOT for kube-prometheus-stack chart wiring / `release:` label gotcha / GKE dual-stack-cost — sibling skill [`kube-prometheus-stack`](../kube-prometheus-stack/SKILL.md).

## Cross-component Path Convention

`components/...` references are **workspace-relative** — they resolve in the yggdrasil checkout that hosts this component. From inside the heimdall repo alone they map to `../<name>/`. Run `ws clone <name>` from the workspace root to materialize a sibling.

## Judgment Calls Worth Knowing

Decisions baked into the current composition that aren't self-evident:

- **`retentionDays` defaults to 7 as a stopgap** — fallout from the 2026-05-15 Prometheus PVC crashloop. The proper fix is object-storage migration (Phase-2 `objectStoreBucket`). Don't bump the default blindly; longer retention on the current PVC layout risks re-hitting the crashloop. 7d is also the ceiling for any percentile-based right-sizing work — long-term trend belongs in a git-backed observations file, not in a bigger TSDB.
- **Control-plane `*Down` rules are disabled unconditionally, not per-environment.** They fire on rancher-desktop as well as GKE; neither exposes those components. `coreDns` *is* conditional, because k3s genuinely runs real CoreDNS on `:9153` and GKE's kube-dns does not. If you're tempted to make the `*Down` toggles conditional too, don't — that was checked.
- **Verify hygiene with `ALERTS{alertstate="firing", severity="critical"}`.** It should be empty. A permanent critical devalues the tier and eventually gets the phone channel muted, which is how the 2026-07-27 Artifactory outage went unnoticed for 14 hours while the pipeline delivered 92 notifications with zero failures.
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
