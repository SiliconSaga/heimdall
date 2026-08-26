#!/usr/bin/env bash
#
# Request right-sizing report (design §6).
#
# Queries Prometheus for per-pod p95 and max CPU/memory per workload over the
# trailing window, joins them against what each workload currently requests,
# and prints a dated Markdown section for appending to
# docs/observations/rightsizing.md.
#
# Prometheus retains one week, so this is the whole history that exists at any
# moment. The committed file is what turns that rolling window into months of
# trend — diffable, reviewable, and surviving cluster rebuilds, without the
# object-storage backend Thanos would need to answer ~20 numbers a week.
#
# Usage:
#   scripts/rightsize-report.sh [--window 7d] [--step 15m] [--top 40]
#
# Environment:
#   KUBE_CMD   command used to reach the cluster (default: kubectl). Inside the
#             GDD workspace pass KUBE_CMD="bash scripts/ws k8s" so the call goes
#             through the k8s guard rather than raw kubectl.
#   PROM_NS / PROM_SVC   override Prometheus service discovery.
#
# Reads only. Nothing here mutates the cluster.
set -euo pipefail

WINDOW="7d"
STEP="15m"
TOP="40"
# Design §6 excludes Jenkins: build agents are spiky by nature, owner-managed,
# and mostly ephemeral pods whose requests vanish with them — left in, they
# rank first on every measure and bury the platform signal this report is for.
EXCLUDE_NS="jenkins"
while [ $# -gt 0 ]; do
  case "$1" in
    --window)     WINDOW="$2";     shift 2 ;;
    --step)       STEP="$2";       shift 2 ;;
    --top)        TOP="$2";        shift 2 ;;
    --exclude-ns) EXCLUDE_NS="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

KUBE_CMD="${KUBE_CMD:-kubectl}"
PROM_NS="${PROM_NS:-heimdall}"

# The release name carries a random per-cluster suffix, so discover the service
# rather than hardcoding it. The selector is the chart's own `app` label —
# kube-prometheus-stack does NOT set `app.kubernetes.io/name` on this Service,
# and the `prometheus-operated` headless Service is a different resource.
if [ -z "${PROM_SVC:-}" ]; then
  PROM_SVC=$($KUBE_CMD get svc -n "$PROM_NS" \
    -l app=kube-prometheus-stack-prometheus -o jsonpath='{.items[0].metadata.name}')
fi
if [ -z "$PROM_SVC" ]; then
  echo "could not find the Prometheus Service in namespace $PROM_NS — set PROM_SVC" >&2
  exit 1
fi
BASE="/api/v1/namespaces/${PROM_NS}/services/${PROM_SVC}:9090/proxy/api/v1"

q() { $KUBE_CMD get --raw "${BASE}/query?query=$(printf '%s' "$1" | jq -sRr @uri)"; }

# Per-pod series joined to their owning workload. `max by` (not `sum by`) is
# deliberate: a request is set per pod, so the basis is the busiest pod of the
# workload at each step, not the workload's total across replicas.
pod_to_workload='* on(namespace, pod) group_left(workload) namespace_workload_pod:kube_pod_owner:relabel'

cpu_inner="max by (namespace, workload) (sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{container!=\"\", node!=\"\"}[5m])) ${pod_to_workload})"
mem_inner="max by (namespace, workload) (sum by (namespace, pod) (container_memory_working_set_bytes{container!=\"\", node!=\"\"}) ${pod_to_workload})"
cpu_req="max by (namespace, workload) (sum by (namespace, pod) (kube_pod_container_resource_requests{resource=\"cpu\", node!=\"\"}) ${pod_to_workload})"
mem_req="max by (namespace, workload) (sum by (namespace, pod) (kube_pod_container_resource_requests{resource=\"memory\", node!=\"\"}) ${pod_to_workload})"

# Check Prometheus reported success before reading rows. On an error response
# `.data.result[]?` yields nothing, so the report would be written with empty
# tables and read as "nothing to right-size" rather than as a failure — the
# worst outcome for a document whose whole purpose is to be believed later.
fetch() {
  local body status
  body="$(q "$1")" || { echo "query failed: $1" >&2; return 1; }
  status="$(printf '%s' "$body" | jq -r '.status // "unknown"')"
  if [ "$status" != "success" ]; then
    printf 'prometheus returned %s: %s\n' \
      "$status" "$(printf '%s' "$body" | jq -r '.error // "no error field"')" >&2
    return 1
  fi
  printf '%s' "$body" | jq -r '.data.result[]? | "\(.metric.namespace)/\(.metric.workload)\t\(.value[1])"'
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fetch "quantile_over_time(0.95, ${cpu_inner}[${WINDOW}:${STEP}])" > "$WORK/cpu_p95"
fetch "max_over_time(${cpu_inner}[${WINDOW}:${STEP}])"            > "$WORK/cpu_max"
fetch "quantile_over_time(0.95, ${mem_inner}[${WINDOW}:${STEP}])" > "$WORK/mem_p95"
fetch "max_over_time(${mem_inner}[${WINDOW}:${STEP}])"            > "$WORK/mem_max"
fetch "$cpu_req"                                                   > "$WORK/cpu_req"
fetch "$mem_req"                                                   > "$WORK/mem_req"

# Contention signals, per the design. All already collected; none needs new
# instrumentation. Throttling is driven by LIMITS, not requests, so it
# diagnoses a different axis than the compression itself — kept because it
# answers "is this workload struggling under its current shape".
fetch "max by (namespace, workload) (sum by (namespace, pod) (changes(kube_pod_container_status_restarts_total[${WINDOW}])) ${pod_to_workload})" > "$WORK/restarts"
fetch "max by (namespace, workload) (sum by (namespace, pod) (kube_pod_container_status_last_terminated_reason{reason=\"OOMKilled\"}) ${pod_to_workload})" > "$WORK/oom"
fetch "max by (namespace, workload) (
         (sum by (namespace, pod) (rate(container_cpu_cfs_throttled_periods_total{container!=\"\"}[1h]))
          / clamp_min(sum by (namespace, pod) (rate(container_cpu_cfs_periods_total{container!=\"\"}[1h])), 1))
         ${pod_to_workload})" > "$WORK/throttle"

DATE=$(date -u +%Y-%m-%d)

echo "## ${DATE} — window ${WINDOW}, step ${STEP}"
echo
echo "Tiers follow design §6: **must-not-starve** (user-facing + control plane) targets ≈ p95; **idle controllers** sit at a 25–50m floor; **Jenkins is excluded** and hand-tuned by its owner."
echo
echo "Two tables, because right-sizing runs in both directions. Compressing only the idle half is what produced the failure this loop exists to prevent: Artifactory sat at a 50m request for 605 days and then could not boot."
echo

awk -F'\t' -v top="$TOP" -v exclude_ns="$EXCLUDE_NS" '
  BEGIN { split(exclude_ns, x, ","); for (i in x) excl[x[i]] = 1 }
  function excluded(k,   ns) { ns = k; sub("/.*", "", ns); return (ns in excl) }
  function num(f, k) { return (k in f) ? f[k] : -1 }
  function cpu(v) { return (v < 0) ? "—" : sprintf("%dm", v * 1000 + 0.5) }
  function mem(v) { return (v < 0) ? "—" : sprintf("%dMi", v / 1048576 + 0.5) }
  function cnt(v) { return (v < 0) ? "—" : sprintf("%d", v) }
  function pct(v) { return (v < 0) ? "—" : sprintf("%.0f%%", v * 100) }
  FILENAME ~ /cpu_p95$/  { cp95[$1] = $2; seen[$1] = 1; next }
  FILENAME ~ /cpu_max$/  { cmax[$1] = $2; next }
  FILENAME ~ /mem_p95$/  { mp95[$1] = $2; next }
  FILENAME ~ /mem_max$/  { mmax[$1] = $2; next }
  FILENAME ~ /cpu_req$/  { creq[$1] = $2; next }
  FILENAME ~ /mem_req$/  { mreq[$1] = $2; next }
  FILENAME ~ /restarts$/ { rst[$1]  = $2; next }
  FILENAME ~ /oom$/      { oom[$1]  = $2; next }
  FILENAME ~ /throttle$/ { thr[$1]  = $2; next }
  function row(k) {
    printf "| `%s` | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", k,
      cpu(num(creq,k)), cpu(num(cp95,k)), cpu(num(cmax,k)),
      mem(num(mreq,k)), mem(num(mp95,k)), mem(num(mmax,k)),
      cnt(num(rst,k)), (num(oom,k) > 0 ? "**yes**" : "—"), pct(num(thr,k))
  }
  function header(title, why) {
    printf "### %s\n\n%s\n\n", title, why
    print "| Workload | CPU req | CPU p95 | CPU max | Mem req | Mem p95 | Mem max | Restarts | OOM | Throttle |"
    print "|---|---|---|---|---|---|---|---|---|---|"
  }
  END {
    for (k in seen) {
      if (excluded(k)) continue
      cwaste[k] = (num(creq, k) < 0) ? -1e9 : num(creq, k) - num(cp95, k)   # CPU reserved and idle
      # A workload with no request reading has no baseline to be short of —
      # scoring it as debt would rank every already-deleted pod at the top.
      mdebt[k]  = (num(mreq, k) < 0) ? -1e9 : num(mp95, k) - num(mreq, k)   # memory used beyond request
      order[++n] = k
    }

    # Table 1 — reserved but idle, ranked by CPU held without being used.
    for (i = 1; i < n; i++)
      for (j = i + 1; j <= n; j++)
        if (cwaste[order[j]] > cwaste[order[i]]) { t = order[i]; order[i] = order[j]; order[j] = t }
    header("Reserved but idle — candidates for compression", \
           "Ranked by CPU requested and not used. These hold schedulable capacity the scheduler believes is spoken for. Compress toward the tier target, never below it.")
    for (i = 1; i <= n && i <= top; i++) if (cwaste[order[i]] > 0.02) row(order[i])

    # Table 2 — under-requested, ranked by memory used beyond its request.
    # Memory leads here because it cannot be throttled: an under-set memory
    # request ends in OOMKilled, whereas an under-set CPU request only bites
    # under contention.
    printf "\n"
    for (i = 1; i < n; i++)
      for (j = i + 1; j <= n; j++)
        if (mdebt[order[j]] > mdebt[order[i]]) { t = order[i]; order[i] = order[j]; order[j] = t }
    header("Under-requested — starve and OOM risk", \
           "Ranked by memory used beyond what it requests. These schedule as if small and then behave as if large, which is the shape that fails during the one hour a year the node is busy.")
    for (i = 1; i <= n && i <= top; i++) if (mdebt[order[i]] > 16777216) row(order[i])
  }
' "$WORK/cpu_p95" "$WORK/cpu_max" "$WORK/mem_p95" "$WORK/mem_max" \
  "$WORK/cpu_req" "$WORK/mem_req" "$WORK/restarts" "$WORK/oom" "$WORK/throttle"
