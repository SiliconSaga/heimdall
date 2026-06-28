# OTel Collector Log-Shipper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an OpenTelemetry Collector DaemonSet to heimdall that tails every node's pod stdout and ships it to the existing in-cluster Loki via native OTLP, closing the platform's missing-log-collector gap.

**Architecture:** heimdall is a single Crossplane Composition (`mode: Pipeline`, `function-go-templating`) with one step per concern. This plan adds a new `deploy-otel-collector` step — a `provider-helm` `Release` of the upstream `opentelemetry-collector` chart in `mode: daemonset` — placed after `deploy-loki` (so the log sink exists) and before `auto-ready` (which must stay last). The collector's `logsCollection` preset wires the filelog receiver over `/var/log/pods`, the `kubernetesAttributes` preset wires the k8sattributes processor plus its ClusterRole/ServiceAccount, and a `config:` override adds an `otlphttp` exporter pointed at Loki's `/otlp` ingest endpoint.

**Tech Stack:** Crossplane v2 Composition Pipeline, `function-go-templating` + `function-auto-ready`, `provider-helm` `Release`, the OpenTelemetry Collector Helm chart (`opentelemetry-collector` v0.159.0, k8s distro image `otel/opentelemetry-collector-k8s`), Loki (SingleBinary, native OTLP), ArgoCD (selfHeal), kuttl for e2e.

## Global Constraints

GitOps "test through Git": heimdall is deployed by an ArgoCD Application (`nidavellir/apps/heimdall-app.yaml`, sync-wave "10", source path `crossplane`, selfHeal=true) — never `kubectl edit`/`kubectl apply` a live heimdall resource to test a change; selfHeal will revert it. Make the change in `crossplane/composition.yaml`, commit, push, and let ArgoCD reconcile.
No nidavellir change is required: the heimdall app self-heals from the `crossplane/` directory, so adding a step to the Composition auto-reconciles once merged.
Every helm `Release` is rendered through `function-go-templating`; each rendered object MUST carry a unique `gotemplating.fn.crossplane.io/composition-resource-name:` annotation (this plan uses `otel-collector`) or Crossplane will collide resources.
`auto-ready` MUST remain the last pipeline step.
Pin the chart version explicitly — never a floating/`latest` version.
don't-wrap prose: write one paragraph per line in any new markdown; keep YAML inside fenced ```yaml blocks.
Use the workspace `ws commit` / `ws push` convention for commits, never raw `git add`/`git commit`/`git push`.
A future log/metric consumer's `ServiceMonitor` must carry the label `release: heimdall-kube-prometheus` to be discovered by the kube-prometheus-stack operator (heimdall fact, noted here for downstream consumers — no consumer work in this plan).

---

### Task 1: Pre-flight verification of the Loki sink and chart contract

**Files**

- Read-only: `crossplane/composition.yaml` (the `deploy-loki` step, lines ~163-234), `crossplane/xrd.yaml`, `crossplane/claim.yaml`.

**Interfaces**

- Loki OTLP sink (verified facts to confirm still hold): in-cluster Service `heimdall-loki`, namespace `heimdall`, port `3100`, native OTLP ingest path `/otlp`. The collector's `otlphttp` exporter appends `/v1/logs`, so it hits `/otlp/v1/logs`. `auth_enabled: false` in the Loki values (composition `deploy-loki` step) means NO `X-Scope-OrgID` header is required. The distribution is `SingleBinary` with `gateway.enabled: false`, so the Service is `heimdall-loki` directly (no gateway in front). Final exporter endpoint: `http://heimdall-loki.heimdall.svc.cluster.local:3100/otlp`.

**Steps**

- [ ] Confirm the running Loki Service name and port: `kubectl get svc -n heimdall -l app.kubernetes.io/name=loki -o wide`. Expect a Service named `heimdall-loki` exposing port `3100/TCP`.
- [ ] Confirm Loki has OTLP ingest reachable. Run a one-shot probe pod: `kubectl run loki-otlp-probe -n heimdall --rm -it --restart=Never --image=curlimages/curl:latest --command -- curl -s -o /dev/null -w '%{http_code}\n' -XPOST http://heimdall-loki.heimdall.svc.cluster.local:3100/otlp/v1/logs -H 'Content-Type: application/json' -d '{}'`. Expect an HTTP status in the `2xx`/`4xx` range (i.e. the endpoint exists and parses) — a `404` would mean the path is wrong and must be fixed before proceeding.
- [ ] Confirm `auth_enabled: false` in the live Loki config so no tenant header is needed: `kubectl get cm -n heimdall heimdall-loki -o jsonpath='{.data.config\.yaml}' | grep -A1 auth_enabled`. Expect `auth_enabled: false`.
- [ ] Confirm the chart version to pin still resolves: `helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts` then `helm search repo open-telemetry/opentelemetry-collector --versions --version 0.159.0`. Expect chart `0.159.0` listed. If it has been yanked, pick the nearest stable `0.159.x`/`0.15x` release and use that exact version everywhere below.
- [ ] Confirm the k8s distro image bundles the required components: `docker run --rm otel/opentelemetry-collector-k8s:latest components` (or inspect the chart's `otel/opentelemetry-collector-k8s` README). Expect `filelog` under receivers and `k8sattributes` under processors. These are what the `logsCollection` and `kubernetesAttributes` presets reference; the base `otel/opentelemetry-collector` (core) distro does NOT include `k8sattributes`, which is why the k8s distro is mandatory here.

---

### Task 2: Render-validate the collector Release before touching the Composition

**Files**

- Create (scratch, NOT committed): `.tmp/otel-values.yaml` — the exact Helm values the composition step will embed, used to dry-run the chart.

**Interfaces**

- This task proves the `presets:` + `config:` keys are real and merge as intended (the failing-test analogue for a non-unit-testable manifest): the rendered DaemonSet must contain a `filelog` receiver and a `k8sattributes` processor in its logs pipeline, plus an `otlphttp/loki` exporter pointed at Loki.

**Steps**

- [ ] Write the values file to `.tmp/otel-values.yaml`:

```yaml
mode: daemonset
image:
  repository: otel/opentelemetry-collector-k8s
presets:
  logsCollection:
    enabled: true
  kubernetesAttributes:
    enabled: true
config:
  exporters:
    otlphttp/loki:
      endpoint: http://heimdall-loki.heimdall.svc.cluster.local:3100/otlp
  service:
    pipelines:
      logs:
        exporters:
          - otlphttp/loki
resources:
  requests:
    cpu: 50m
    memory: 128Mi
  limits:
    cpu: 250m
    memory: 256Mi
```

- [ ] Render the chart with those values: `helm template heimdall-otel-collector open-telemetry/opentelemetry-collector --version 0.159.0 --namespace heimdall -f .tmp/otel-values.yaml > .tmp/otel-rendered.yaml`. Expect a successful render with no errors (`exit 0`).
- [ ] Assert the workload is a DaemonSet: `grep -E '^kind: DaemonSet' .tmp/otel-rendered.yaml`. Expect one match.
- [ ] Assert the presets wired the pipeline correctly. Inspect the rendered collector ConfigMap: `grep -E 'filelog|k8sattributes|otlphttp/loki|/otlp' .tmp/otel-rendered.yaml`. Expect to see a `filelog:` receiver, a `k8sattributes:` processor, an `otlphttp/loki:` exporter, and the endpoint ending in `:3100/otlp`. The `logs` pipeline under `service.pipelines` should list `filelog` (and `receiver_creator`/`k8sobjects` may also appear) under receivers, `k8sattributes` (alongside `memory_limiter`/`batch`) under processors, and `otlphttp/loki` under exporters. This confirms the chart deep-merges our `config:` override onto the preset-injected pipeline rather than replacing it.
- [ ] Assert the kubernetesAttributes preset created RBAC: `grep -E '^kind: ClusterRole$|^kind: ClusterRoleBinding$|^kind: ServiceAccount$' .tmp/otel-rendered.yaml`. Expect a ClusterRole, ClusterRoleBinding, and ServiceAccount (the k8sattributes processor needs cluster-wide read on pods/namespaces/nodes).
- [ ] Clean up scratch files: `rm -f .tmp/otel-values.yaml .tmp/otel-rendered.yaml` (they were only a render gate; the canonical values live in the Composition).

---

### Task 3: Add the `deploy-otel-collector` step to the Composition

**Files**

- Modify: `crossplane/composition.yaml` — insert a new pipeline step between the `deploy-tempo` step (ends ~line 288) and the `deploy-self-health-rules` step (begins ~line 304). Placement only needs to satisfy "after `deploy-loki`, before `auto-ready`"; inserting right after `deploy-tempo` keeps the Helm `Release` steps grouped. Do NOT reorder or modify `auto-ready` (the final step, ~line 460).

**Interfaces**

- The step mirrors the `deploy-loki` skeleton exactly: `functionRef.name: function-go-templating`, `input.kind: GoTemplate`, `source: Inline`, a single `helm.crossplane.io/v1beta1` `Release` whose name is `{{ .observed.composite.resource.metadata.name }}-otel-collector` and whose unique resource-name annotation is `otel-collector`. The Loki endpoint is templated off the same `.observed.composite.resource.metadata.name` so it tracks the claim name (`heimdall` → `heimdall-loki`).

**Steps**

- [ ] Open `crossplane/composition.yaml` and locate the end of the `deploy-tempo` step (the `resources:` block ending with the `memory: 1Gi` limit, ~line 288) and the start of the `deploy-self-health-rules` comment banner (~line 290).
- [ ] Insert the following step verbatim between them (full YAML, no placeholders):

```yaml
  # ──────────────────────────────────────────────────────────
  # Step 2.5: OpenTelemetry Collector (log-shipper DaemonSet)
  #
  # Closes the heimdall log-collector gap. Runs one collector per node
  # (DaemonSet) tailing /var/log/pods via the filelog receiver (wired by
  # the logsCollection preset), enriches each record with pod/namespace/
  # node metadata via the k8sattributes processor (wired by the
  # kubernetesAttributes preset, which also creates the ClusterRole +
  # ServiceAccount it needs), and ships to Loki's native OTLP ingest.
  #
  # Distro: image otel/opentelemetry-collector-k8s is the curated
  # Kubernetes distribution that bundles filelog + k8sattributes; the
  # core otel/opentelemetry-collector image does not include
  # k8sattributes, so the k8s distro is required.
  #
  # Loki sink: auth_enabled is false and there is no gateway in front of
  # the SingleBinary Loki, so no X-Scope-OrgID header is required. The
  # otlphttp exporter appends /v1/logs to the endpoint, hitting Loki's
  # /otlp/v1/logs. The chart deep-merges this config: block onto the
  # preset-injected logs pipeline, so filelog/k8sattributes survive.
  #
  # Placed after deploy-loki (sink must exist) and before auto-ready
  # (which must remain the final step).
  # ──────────────────────────────────────────────────────────
  - step: deploy-otel-collector
    functionRef:
      name: function-go-templating
    input:
      apiVersion: gotemplating.fn.crossplane.io/v1beta1
      kind: GoTemplate
      source: Inline
      inline:
        template: |
          apiVersion: helm.crossplane.io/v1beta1
          kind: Release
          metadata:
            name: {{ .observed.composite.resource.metadata.name }}-otel-collector
            annotations:
              gotemplating.fn.crossplane.io/composition-resource-name: otel-collector
          spec:
            forProvider:
              chart:
                name: opentelemetry-collector
                repository: https://open-telemetry.github.io/opentelemetry-helm-charts
                version: "0.159.0"
              namespace: heimdall
              values:
                mode: daemonset
                image:
                  repository: otel/opentelemetry-collector-k8s
                presets:
                  logsCollection:
                    enabled: true
                  kubernetesAttributes:
                    enabled: true
                config:
                  exporters:
                    otlphttp/loki:
                      endpoint: http://{{ .observed.composite.resource.metadata.name }}-loki.heimdall.svc.cluster.local:3100/otlp
                  service:
                    pipelines:
                      logs:
                        exporters:
                          - otlphttp/loki
                resources:
                  requests:
                    cpu: 50m
                    memory: 128Mi
                  limits:
                    cpu: 250m
                    memory: 256Mi
```

- [ ] Lint the edited file: `yamllint crossplane/composition.yaml` (or `python3 -c 'import yaml,sys; list(yaml.safe_load_all(open("crossplane/composition.yaml")))'`). Expect no parse errors. Note the inline `template:` is a multi-line string, so a structural YAML parse only validates the outer document — the inner template was already render-validated in Task 2.
- [ ] If `crossplane render` is available, dry-run the whole Composition against the claim: `crossplane render crossplane/claim.yaml crossplane/composition.yaml functions.yaml` (use the repo's functions manifest if present). Expect a `helm.crossplane.io/v1beta1 Release` named `heimdall-otel-collector` in the output with the `otel-collector` resource-name annotation. If `crossplane render` is not installed, skip — the live ArgoCD sync in Task 6 is the real gate.
- [ ] Verify `auto-ready` is still the final pipeline step: `grep -n 'step:' crossplane/composition.yaml`. Expect `deploy-otel-collector` to appear before `deploy-self-health-rules`, `deploy-ingress-routes`, and `auto-ready`, with `auto-ready` last.

---

### Task 4: Add the kuttl e2e assertion for the DaemonSet (write the failing check first)

**Files**

- Create: `tests/e2e/otel-collector-running/00-cmd.yaml` — a kuttl `TestStep` asserting the collector DaemonSet exists and is Ready on every node. Mirrors the style of `tests/e2e/loki-ingestion/00-cmd.yaml` (one-shot `script:` with `set -e`, dynamic label lookup, PASS/FAIL echoes).

**Interfaces**

- The collector DaemonSet carries the chart's standard labels: `app.kubernetes.io/name=opentelemetry-collector`. Readiness is `status.numberReady == status.desiredNumberScheduled` and `desiredNumberScheduled > 0`.

**Steps**

- [ ] Create `tests/e2e/otel-collector-running/00-cmd.yaml` with:

```yaml
# Assert the OpenTelemetry Collector DaemonSet is deployed and Ready on all nodes
apiVersion: kuttl.dev/v1beta1
kind: TestStep
commands:
  - script: |
      set -e

      # Find the collector DaemonSet by its chart label
      DS=$(kubectl get daemonset -n heimdall \
        -l app.kubernetes.io/name=opentelemetry-collector \
        -o jsonpath='{.items[0].metadata.name}')

      if [ -z "$DS" ]; then
        echo "FAIL: No opentelemetry-collector DaemonSet found in heimdall"
        exit 1
      fi

      echo "Found collector DaemonSet: $DS"

      DESIRED=$(kubectl get daemonset "$DS" -n heimdall \
        -o jsonpath='{.status.desiredNumberScheduled}')
      READY=$(kubectl get daemonset "$DS" -n heimdall \
        -o jsonpath='{.status.numberReady}')

      echo "DaemonSet $DS: ready=$READY desired=$DESIRED"

      if [ -z "$DESIRED" ] || [ "$DESIRED" -lt 1 ]; then
        echo "FAIL: DaemonSet has no desired pods scheduled"
        exit 1
      fi

      if [ "$READY" = "$DESIRED" ]; then
        echo "PASS: collector Ready on all $DESIRED node(s)"
      else
        echo "FAIL: only $READY/$DESIRED collector pods Ready"
        kubectl get pods -n heimdall -l app.kubernetes.io/name=opentelemetry-collector
        exit 1
      fi
```

- [ ] Run it against the current (pre-deploy) cluster to confirm it FAILS for the right reason: `bash test.sh --test otel-collector-running`. Expect `FAIL: No opentelemetry-collector DaemonSet found` (the collector is not deployed yet — this is the red state proving the assertion is real).

---

### Task 5: Add the kuttl e2e assertion that logs reach Loki via the collector

**Files**

- Create: `tests/e2e/otel-loki-logs/00-cmd.yaml` — a kuttl `TestStep` that queries Loki with LogQL and asserts log streams produced by the collector are present. Mirrors `tests/e2e/loki-ingestion/00-cmd.yaml` (one-shot `curlimages/curl` pod, poll for `Succeeded`, grep the response).

**Interfaces**

- The k8sattributes processor maps pod metadata to OTLP resource attributes; Loki's OTLP ingest promotes a curated subset to stream labels. Query for logs from the heimdall namespace, which the collector itself runs in (guaranteeing traffic). The OTLP-derived namespace label in Loki is `k8s_namespace_name` (Loki sanitizes the OTel `k8s.namespace.name` attribute by replacing dots with underscores). Use a `count_over_time` LogQL query over the last 5m and assert a non-empty result.

**Steps**

- [ ] Create `tests/e2e/otel-loki-logs/00-cmd.yaml` with:

```yaml
# Assert the OTel collector is actually shipping pod stdout into Loki:
# query Loki for log lines labelled with the heimdall namespace.
apiVersion: kuttl.dev/v1beta1
kind: TestStep
commands:
  - script: |
      set -e

      LOKI_SVC=$(kubectl get svc -n heimdall -l app.kubernetes.io/name=loki \
        -o jsonpath='{.items[0].metadata.name}')

      if [ -z "$LOKI_SVC" ]; then
        echo "FAIL: No Loki service found"
        exit 1
      fi
      echo "Found Loki service: $LOKI_SVC"

      kubectl delete pod loki-otel-client -n heimdall --ignore-not-found --wait=true

      # LogQL: count log lines from the heimdall namespace over the last 5m.
      # OTLP resource attribute k8s.namespace.name is stored by Loki as the
      # stream label k8s_namespace_name (dots -> underscores).
      QUERY='count_over_time({k8s_namespace_name="heimdall"}[5m])'
      URL="http://${LOKI_SVC}.heimdall.svc:3100/loki/api/v1/query?query=$(printf %s "$QUERY" | sed 's/ /%20/g;s/{/%7B/g;s/}/%7D/g;s/"/%22/g;s/\[/%5B/g;s/\]/%5D/g')"

      kubectl run loki-otel-client --namespace heimdall \
        --image=curlimages/curl:latest --restart=Never \
        --command -- curl -sf "$URL"

      DONE=0
      for i in $(seq 1 30); do
        PHASE=$(kubectl get pod loki-otel-client -n heimdall -o jsonpath='{.status.phase}' 2>/dev/null)
        if [ "$PHASE" = "Succeeded" ]; then DONE=1; break; fi
        if [ "$PHASE" = "Failed" ]; then
          echo "FAIL: Loki query pod failed"
          kubectl logs loki-otel-client -n heimdall
          kubectl delete pod loki-otel-client -n heimdall --ignore-not-found
          exit 1
        fi
        sleep 2
      done

      if [ "$DONE" -eq 0 ]; then
        echo "FAIL: Loki query pod did not complete within timeout"
        kubectl logs loki-otel-client -n heimdall 2>/dev/null || true
        kubectl delete pod loki-otel-client -n heimdall --ignore-not-found
        exit 1
      fi

      RESULT=$(kubectl logs loki-otel-client -n heimdall)
      echo "Loki query response: $RESULT"
      kubectl delete pod loki-otel-client -n heimdall --ignore-not-found

      # A non-empty "result" array means the collector has shipped logs that
      # Loki indexed under the heimdall namespace label.
      if echo "$RESULT" | grep -q '"status":"success"' && echo "$RESULT" | grep -q '"result":\['; then
        if echo "$RESULT" | grep -q '"result":\[\]'; then
          echo "FAIL: Loki returned an empty result — no heimdall logs ingested via OTLP yet"
          exit 1
        fi
        echo "PASS: Loki has heimdall-namespace logs shipped by the OTel collector"
      else
        echo "FAIL: Loki query did not return a successful non-empty result"
        exit 1
      fi
```

- [ ] Run it pre-deploy to confirm it FAILS for the right reason: `bash test.sh --test otel-loki-logs`. Expect either `empty result` or a query failure — both are the red state (no collector shipping logs yet).

---

### Task 6: Deploy via Git and assert the live observable outcome

**Files**

- No new files. This task commits Tasks 3-5 and lets ArgoCD reconcile (heimdall app has selfHeal=true, source path `crossplane`).

**Interfaces**

- ArgoCD Application `heimdall` in namespace `argocd`; HeimdallStack claim `heimdall` in namespace `heimdall`. After sync, a new `Release` resource `heimdall-otel-collector` and a DaemonSet labelled `app.kubernetes.io/name=opentelemetry-collector` appear in the `heimdall` namespace.

**Steps**

- [ ] Stage and commit the Composition change plus the two kuttl tests using the workspace convention: `ws commit` (message e.g. `feat(heimdall): add OTel Collector log-shipper DaemonSet to Loki`). Do NOT use raw `git add`/`git commit`.
- [ ] Push so ArgoCD can see it: `ws push`.
- [ ] Wait for ArgoCD to sync the heimdall app: `kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced application/heimdall --timeout=300s` then confirm health: `kubectl -n argocd get application heimdall -o jsonpath='{.status.health.status}{"\n"}'`. Expect `Synced` and `Healthy`. (If selfHeal/auto-sync is slow, `kubectl -n argocd annotate application heimdall argocd.argoproj.io/refresh=hard --overwrite` to nudge a refresh — this is a refresh trigger, not a manual resource edit, so it does not violate the test-through-Git rule.)
- [ ] Confirm Crossplane created and reconciled the Release: `kubectl get release heimdall-otel-collector -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'`. Expect `True`.
- [ ] Confirm the DaemonSet is Ready on all nodes: `kubectl rollout status daemonset -n heimdall -l app.kubernetes.io/name=opentelemetry-collector --timeout=180s` and `kubectl get daemonset -n heimdall -l app.kubernetes.io/name=opentelemetry-collector`. Expect `DESIRED == READY` and equal to the node count.
- [ ] Spot-check a collector pod started its pipeline without config errors: `kubectl logs -n heimdall -l app.kubernetes.io/name=opentelemetry-collector --tail=40`. Expect `Everything is ready. Begin running and processing data.` and an `otlphttp/loki` exporter starting — and NO `connection refused` / `404` errors against Loki.
- [ ] Run the live assertions added in Tasks 4 and 5 — they must now go green: `bash test.sh --test otel-collector-running` (expect `PASS: collector Ready on all N node(s)`) and `bash test.sh --test otel-loki-logs` (expect `PASS: Loki has heimdall-namespace logs shipped by the OTel collector`).
- [ ] Cross-check in Grafana Explore that logs are queryable end-to-end: the LogQL query `{k8s_namespace_name="heimdall"}` returns recent lines. (Optional manual confirmation; the kuttl test above is the gating check.)

---

### Task 7: Update component docs

**Files**

- Modify: `docs/architecture.md` — the "Composition Pipeline" list (currently "six steps") and the data-source/logs narrative.
- Modify: `README.md` — the "Sending data to Heimdall" → "Logs" line (lines ~76-78), which currently claims "Loki collects from the cluster automatically (via the canary/agent)" (inaccurate — there was no collector).

**Interfaces**

- Keep the docs' don't-wrap prose style (one paragraph per line). Reflect that there are now seven deploy concerns and that the OTel collector is the log path.

**Steps**

- [ ] In `docs/architecture.md`, update the intro line "deploy and configure six steps" to reflect the added step, and insert a list entry after the Tempo bullet (item 3) describing the OTel Collector: a DaemonSet (provider-helm Release) running the k8s-distro collector with the filelog receiver (logsCollection preset) and k8sattributes processor (kubernetesAttributes preset), exporting via otlphttp to Loki's native `/otlp` ingest (`auth_enabled: false`, no tenant header). Renumber the following list items.
- [ ] In `docs/architecture.md`, add a one-line note (e.g. under the new bullet or in the data-sources paragraph) that any consumer wanting metric scraping must label its `ServiceMonitor` `release: heimdall-kube-prometheus` to be discovered by the kube-prometheus-stack operator (mirrors the self-health-rules label fact already documented for PrometheusRules). No consumer manifests here.
- [ ] In `README.md`, replace the inaccurate "Logs" guidance with the accurate model: pod stdout is collected cluster-wide automatically by the OpenTelemetry Collector DaemonSet (deployed by the composition) and shipped to Loki via OTLP — workloads need to do nothing beyond logging to stdout; query in Grafana Explore with LogQL, e.g. `{k8s_namespace_name="your-namespace"}`.
- [ ] Lint/spell-check the prose edits visually (no wrapping introduced). Then commit the doc updates with `ws commit` and `ws push`. (Doc-only; ArgoCD ignores `docs/`.)

---

## Self-Review

Confirm before declaring done:

- [ ] **New step added, correctly placed:** `deploy-otel-collector` exists in `crossplane/composition.yaml` AFTER `deploy-loki` and BEFORE `auto-ready`; `auto-ready` is still the final step. (Task 3)
- [ ] **Mirrors the deploy-loki skeleton:** provider-helm `Release` via `function-go-templating`, `source: Inline`, Release name `{{ .metadata.name }}-otel-collector`, unique `gotemplating.fn.crossplane.io/composition-resource-name: otel-collector` annotation. (Task 3)
- [ ] **Chart pinned, not floating:** `opentelemetry-collector` from `https://open-telemetry.github.io/opentelemetry-helm-charts` at explicit version `0.159.0` (verified resolvable in Task 1). (Tasks 1, 3)
- [ ] **Values match the locked design and are real chart keys** (render-verified in Task 2): `mode: daemonset`; `image.repository: otel/opentelemetry-collector-k8s` (k8s distro confirmed to bundle filelog + k8sattributes); `presets.logsCollection.enabled: true`; `presets.kubernetesAttributes.enabled: true`; a `config:` override adding an `otlphttp/loki` exporter and a logs pipeline that keeps the preset-injected filelog/k8sattributes. (Tasks 1-3)
- [ ] **Loki target correct:** endpoint `http://heimdall-loki.heimdall.svc.cluster.local:3100/otlp` (exporter appends `/v1/logs`); `auth_enabled: false` so no `X-Scope-OrgID`; SingleBinary, no gateway. (Tasks 1, 3)
- [ ] **Namespace:** the Release deploys into `heimdall`; DaemonSet runs on all nodes via hostPath `/var/log/pods` mounts (logsCollection preset). (Task 3)
- [ ] **No nidavellir change:** deployed purely by committing to `crossplane/` and letting the selfHeal ArgoCD app reconcile. (Global Constraints, Task 6)
- [ ] **GitOps respected:** all changes landed via `ws commit`/`ws push` + ArgoCD sync; no `kubectl apply`/`edit` on live heimdall resources to effect the change. (Tasks 6, 7)
- [ ] **kuttl coverage mirrors existing style:** `tests/e2e/otel-collector-running/` asserts the DaemonSet is Ready on all nodes; `tests/e2e/otel-loki-logs/` asserts logs reach Loki via LogQL — both shown red pre-deploy and green post-deploy. (Tasks 4-6)
- [ ] **Docs updated** to reflect the new step and the accurate log-collection path; the `release: heimdall-kube-prometheus` ServiceMonitor-discovery fact is noted for future consumers. (Task 7)
- [ ] **Out of scope honored:** no Valheim ServiceMonitor, dashboard, or other kubicvalheim work appears in this plan.
