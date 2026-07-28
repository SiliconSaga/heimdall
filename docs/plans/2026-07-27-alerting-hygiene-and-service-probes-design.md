# Alerting Hygiene and Service Probes — Design

**Date:** 2026-07-27
**Status:** Approved, not yet implemented
**Component:** heimdall

## Motivation

On 2026-07-27 the GKE node pool auto-rolled overnight and `artifactory.terasology.io` stayed down for roughly fourteen hours. Nobody was told.

The instinctive reading — the observability stack has not been wired up yet — turned out to be wrong. Investigation found the opposite: Prometheus rules, AlertManager routing, and ntfy delivery were all already deployed and working. AlertManager had made 92 webhook deliveries to ntfy in the preceding ten hours with **zero** failures, and the `KubePodCrashLooping` rule was firing correctly for the affected pod the whole time.

The pipeline worked. Its output was worthless, so the human muted the ntfy app on his phone, and the one real alert of the day landed in a muted channel as a low-priority notification.

This design is therefore mostly subtraction. The stack does not need building; it needs editing, plus one genuinely new primitive.

## Problem statement

Three defects, in order of severity.

**1. Permanent critical false positives train the operator to ignore alerts.** `KubeControllerManagerDown`, `KubeSchedulerDown`, and `KubeProxyDown` fire continuously and can never clear: GKE hides the managed control plane, so those components are not scrape-exposed. Each carries `severity: critical`, which nidavellir's ntfy template renders as priority 5 — the Do-Not-Disturb-piercing tier — on a one-hour repeat interval. The same three also fire on the homelab rancher-desktop cluster for the same structural reason (recorded 2026-05-26). Two further `TargetDown` warnings fire permanently: one for CoreDNS (the chart scrapes `:9153`, which GKE's kube-dns does not expose) and one for an orphaned `tera-prometheus-kube-prome-kubelet` Service left in `kube-system` when that stack was removed on 2026-05-15, whose Endpoints no operator maintains.

**2. The signal that mattered was the quietest thing in the system.** `KubePodCrashLooping` carries `severity: warning`, which renders as ntfy priority 3 — a silent push. A real fourteen-hour outage was strictly quieter than three alerts that mean nothing.

**3. Nothing observes the service the way a user does.** Every existing rule reasons about cluster internals. None of them answers "is the URL people actually visit responding?" That distinction matters beyond semantics: `KubePodCrashLooping` describes a symptom whose severity depends entirely on which pod is looping, and the stack has no way to express that a crashloop in a dead demo namespace is uninteresting while `artifactory.terasology.io` returning nothing is an emergency.

A related discovery constrains any pod-state-based approach: **pods in `CrashLoopBackOff` still report `phase: Running`.** During the outage, `kubectl get pods -A --field-selector=status.phase!=Running` returned nothing at all while the pod sat at 0/6 containers ready. Any detection built on pod phase is blind to exactly this failure mode.

## Design principles

**Criticality is defined by user-visible reachability, not by internal state.** This is the central decision. Internal signals stay at `warning` and inform diagnosis; black-box probe failure is what earns `critical` and the DND bypass. It gives the operator a principled answer to "should this wake me up" that the current severity assignment cannot express.

**Prefer deleting a rule over tuning it.** A rule that can never be true in a given environment is disabled at the chart level, which removes both the rule and its ServiceMonitor. Inhibition rules are a worse fix because the alert still exists, still evaluates, and still shows up in the UI.

**Curate the dashboards that already ship.** kube-prometheus-stack provides 28 dashboards, including full cluster/node/namespace/pod/workload resource views. The gap is a single opinionated overview, not the underlying panels.

## Architecture

Six sections. Sections 1 and 2 are the first implementable increment and together make the ntfy channel trustworthy enough to unmute.

### Section 1 — Alert hygiene

Add to the kube-prometheus-stack Helm values in `crossplane/composition.yaml` (the values block beginning at line 61):

```yaml
kubeControllerManager: {enabled: false}
kubeScheduler:         {enabled: false}
kubeProxy:             {enabled: false}
kubeEtcd:              {enabled: false}
coreDns:               {enabled: {{ ne $env "gke" }}}
```

The first four are unconditional: these components are not scrape-exposed on managed GKE **or** on rancher-desktop k3s, so the rules are false everywhere Heimdall runs. Disabling at the chart level removes the ServiceMonitor and the PrometheusRule together.

`coreDns` is environment-conditional because the two clusters genuinely differ. k3s runs real CoreDNS exposing metrics on `:9153`; GKE runs kube-dns, which does not. The composition already computes `$env` from the `cluster-identity` EnvironmentConfig, so this follows the existing pattern.

The orphaned Service is a one-time cluster cleanup, not an IaC change — it belongs to a stack that no longer exists in any repository:

```bash
kubectl delete service tera-prometheus-kube-prome-kubelet -n kube-system
```

Expected result: the firing set reduces to `Watchdog` plus conditions that are actually true.

### Section 2 — Blackbox Exporter and the Probe primitive

Add `prometheus-blackbox-exporter` as a new Helm release step in the composition, deployed into the `heimdall` namespace. The Prometheus Operator already understands the `Probe` CRD, and this Prometheus is configured with `serviceMonitorSelectorNilUsesHelmValues: false` (from heimdall#11), so probes declared anywhere in the cluster are discovered without a release-label match.

**The prober address must be stable.** Composition Helm releases are named from the composite (`heimdall-<xrsuffix>-…`) and that suffix is random per cluster, so a `Probe` authored in another repository cannot know the generated Service name at author time. This is the same trap heimdall#11 hit with the `release` label, and it must not be repeated: a probe is meant to be a file someone writes without consulting the cluster. The composition therefore also creates a **fixed-name `ExternalName`-free alias Service, `heimdall-blackbox`, in the `heimdall` namespace**, selecting the blackbox exporter pods directly. Every `Probe` references `heimdall-blackbox.heimdall.svc:9115`, which is identical on every cluster. The suffixed chart Service is left alone.

A monitor then becomes one committed file:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: Probe
metadata:
  name: artifactory
  namespace: heimdall
  labels:
    heimdall.siliconsaga.org/watched: "true"
spec:
  prober:
    url: heimdall-blackbox.heimdall.svc:9115
  module: http_2xx
  interval: 30s
  targets:
    staticConfig:
      static:
        - "https://artifactory.terasology.io/artifactory/api/system/ping"
```

The `/artifactory/api/system/ping` endpoint is used rather than the site root because it returns a plain `OK` only when Artifactory has fully started — the root serves a shell page earlier in the boot sequence, which would have reported healthy during part of today's outage.

The accompanying rule goes into the existing self-health PrometheusRule at composition Step 3.5:

```yaml
- alert: HeimdallWatchedServiceDown
  expr: probe_success == 0
  for: 3m
  labels:
    severity: critical
  annotations:
    summary: "{{ $labels.instance }} has been unreachable for 3 minutes"
```

Two supporting rules at `warning`, which are cheap once probing exists:

- `HeimdallWatchedServiceSlow` — `probe_duration_seconds > 5` for 10m.
- `HeimdallCertExpiringSoon` — `probe_ssl_earliest_cert_expiry - time() < 14 * 24 * 3600`.

`for: 3m` is chosen deliberately. It is long enough to ride out a rolling restart or a brief node blip, and short enough that a real outage pages within minutes rather than hours. Today's failure would have alerted at roughly the three-minute mark and stayed firing for fourteen hours.

### Section 3 — Heimdall Overview dashboard

One new dashboard, provisioned as a ConfigMap labelled `grafana_dashboard: "1"` alongside the bundled ones, designed to be read from across a room on a wall-mounted monitor. Four rows, ordered by what matters at a glance:

1. **Watched services** — one large stat tile per probe: up/down, current latency, days until TLS expiry. Green wall means the things people use are answering.
2. **Cluster resources** — CPU and memory, requested versus actually used, per node. The gap between those two lines is what concealed today's over-reservation, so it is shown explicitly rather than left to inference.
3. **Top restarters** — `changes(kube_pod_container_status_restarts_total[6h])`, top 10 descending. This realises the long-queued `HeimdallRestartAnomaly` idea from 2026-05-20. It is the panel that would have shown both Artifactory and ArgoCD lit up in the small hours, and it catches the "green but quietly crashing all along" class that readiness probes miss entirely.
4. **Alert inventory** — currently firing alerts grouped by severity. A permanently non-empty critical row is itself the signal that hygiene has regressed.

Existing bundled dashboards are kept and left untouched for drill-down.

### Section 4 — Uptime Kuma

A separate lightweight component in GKE, not part of the HeimdallStack composition, offering what a `Probe` CR cannot: click-to-add monitors without a commit, and a shareable public status page.

It complements Section 2 rather than replacing it. Probes stay the GitOps-managed, alert-generating path; Uptime Kuma serves ad-hoc checks and human-facing status. Because it runs in the cluster it watches, it cannot detect that cluster failing — Section 5 covers that gap.

Deferred to a later increment. The original conception (see the Thalamus backlog) was a cross-environment watchdog with each environment monitoring the other, but that requires a 24/7 homelab box which does not exist. Running it in GKE is the available option and is worth having for the status page alone.

### Section 5 — Dead-man's-switch

With every component in GKE, nothing in this design detects GKE itself going dark. kube-prometheus-stack already ships the answer: the `Watchdog` alert fires continuously by design and is currently routed to the `null` receiver.

Route it instead to an external heartbeat service (healthchecks.io free tier or equivalent) as an additional receiver:

```yaml
- matchers: ['alertname = "Watchdog"']
  receiver: external-heartbeat
  repeat_interval: 5m
```

While the cluster is healthy the heartbeat is pinged every five minutes. If the cluster, Prometheus, or AlertManager dies, the pings stop and the external service raises the alarm. This is the only element of the design that survives total cluster loss without a second site, and it costs one receiver plus a URL.

### Section 6 — Request right-sizing loop

The cluster runs under a committed-use agreement, so node shape and count are fixed. Packing density is the only capacity lever available, which makes compressing resource requests the whole game — and makes a feedback loop mandatory rather than optional.

The reason it is mandatory: **CPU requests only bite under contention.** On an idle cluster, cutting a request looks free and behaves identically. It stops behaving identically during the one hour a year that the node is busy, and the pod that lost the CFS share race is the one that fails. Artifactory requested `50m` for 605 days without incident and then could not boot at all. Compression without a watch loop does not avoid that outcome, it defers it.

**Tiered targets, not uniform compression.** Flattening everything to a floor is what produces the failure above.

| Tier | Workloads | Request target |
|---|---|---|
| Must-not-starve | User-facing and control plane — Artifactory, Gitea, ingress, ArgoCD | ≈ p95 observed |
| Idle controllers | Operators, webhooks, Crossplane functions | Floor, 25–50m |
| Hand-tuned | Jenkins | Excluded — spiky by nature, owner-managed |

**Contention signals.** All of these are already collected; none needs new instrumentation. Together they answer "which service is struggling under its new request":

- `rate(container_cpu_cfs_throttled_periods_total[…]) / rate(container_cpu_cfs_periods_total[…])` — throttling ratio. Note this is driven by *limits*, not requests, so it diagnoses a different axis than the compression itself.
- `changes(kube_pod_container_status_restarts_total[…])` — the restart-anomaly signal from Section 3.
- `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}` — the unambiguous marker of an under-set **memory** request.
- Probe failures from the kubelet `/metrics/probes` endpoint — the earliest warning, and the signal that would have caught both Artifactory and ArgoCD hours before anything else.
- `kube_pod_status_phase{phase="Pending"}` plus `FailedScheduling` events — over-compression surfacing as unschedulable pods rather than slow ones.

**Weekly check with a git-backed record.** A scheduled weekly run queries p95 and max CPU and memory per workload over the trailing 7 days, gathers the signals above, and appends a dated row per workload to a versioned file in this repo. Prometheus retains 7 days; the file is what turns that rolling window into months of trend.

Deliberately **not** Thanos, despite the `thanosEnabled` stub already in the XRD. Thanos requires an object-storage backend, which re-opens the parked garage-vs-seaweedfs evaluation, to answer a question amounting to roughly twenty numbers a week. A git-backed file is diffable, reviewable, survives cluster rebuilds, needs no new infrastructure, and lets a human read a month of drift in one screen. If long-range high-resolution history is later wanted for its own sake, Thanos remains available and this file does not conflict with it.

Run it as a scheduled agent rather than an in-cluster CronJob to begin with. The interesting output is not the numbers but the judgment about them — which workload changed shape, whether a spike was real load or a neighbour's noise, what to adjust next. That is prose a CronJob cannot write. Graduate it to a CronJob if it ever becomes purely mechanical.

## What this design does not do

- It does not add Thanos, object storage, OIDC, or Pyroscope. Those remain on the Heimdall buildout backlog and are independent of alert quality.
- It does not attempt to forecast failures. Section 6 observes and reacts on a weekly cadence; no predictive modelling or anomaly-detection rules are proposed. The immediate gap is detecting a total outage, not anticipating one.
- It does not automate request changes. Section 6 produces evidence and judgment; editing a chart value stays a human decision through the normal review flow. No VPA, no auto-apply.
- It does not fix the two hot-patches applied during the incident. Artifactory's CPU limit and startup probe thresholds are owned by the legacy ArgoCD, and the new ArgoCD's resource requests are owned by nordri's `bootstrap.sh`. Both will revert. They are tracked separately.

## Testing

Heimdall's kuttl suite (`tests/e2e/`) gains cases mirroring the existing style:

- `blackbox-exporter-running` — deployment becomes available and the fixed-name `heimdall-blackbox` Service resolves to a ready endpoint.
- `probe-discovered` — after applying a `Probe`, `probe_success` appears in Prometheus for that instance.
- `alert-rules-loaded` — `HeimdallWatchedServiceDown` is present in the Prometheus rules API.

Two checks are best done by hand because they assert absence and end-to-end delivery respectively:

- **Hygiene verification** — query `ALERTS{alertstate="firing", severity="critical"}` and confirm the result is empty. This is the acceptance test for Section 1.
- **Delivery verification** — point a probe at a deliberately unreachable URL, confirm the push arrives on the phone at priority 5 with DND active, then remove it. This exercises the full path and re-validates the Android channel override documented in nidavellir's ntfy README.

The delivery test is human-gated: it must reach a physical phone with Do Not Disturb enabled, so it needs the operator ready and watching rather than being run unattended.

## Implementation order

1. Section 1 hygiene, plus the orphan Service deletion. Verify the critical firing set is empty.
2. Section 2 Blackbox Exporter, the Artifactory probe, and `HeimdallWatchedServiceDown`. Verify with the deliberate-failure delivery test.
3. Unmute ntfy on the phone. This is the real acceptance gate for the whole increment.
4. Section 3 dashboard.
5. Section 6 right-sizing loop — start the weekly check early, even before the dashboard, so the observations file begins accumulating trend while the rest is built. Its value compounds with elapsed time, so it is the one section that is cheaper to start sooner.
6. Sections 4 and 5 as separate follow-on increments.
