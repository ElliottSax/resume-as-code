#!/usr/bin/env bash
# The chaos drill.
#
# Builds a throwaway three-node Kubernetes cluster from nothing, deploys the
# service with Helm, proves the guardrails work, then sends steady traffic
# while breaking things on purpose:
#
#   - kills pods outright (crashes, OOM kills, hardware faults)
#   - rolls out a new deploy (every release)
#   - drains a node (kernel patching, cluster upgrades, spot reclaims)
#
# The SLO is judged from the client's side: what fraction of requests
# succeeded and how fast. If the objective is missed, this script exits
# non-zero and the release pipeline stops. Results go to out/drill.json and
# end up on the published resume.
#
#   scripts/drill.sh                # full drill, cluster deleted afterwards
#   scripts/drill.sh --keep         # full drill, keep the cluster to poke at
#   scripts/drill.sh --deploy-only  # build + deploy only, for local demos
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=../tools.env
source tools.env

CLUSTER="${CLUSTER_NAME:-resume-drill}"
IMAGE="${IMAGE:-resume:local}"
NS=resume
DURATION="${DRILL_DURATION:-180}" # seconds of sustained load
RATE="${DRILL_RATE:-100}"         # requests per second
OUT_DIR="${DRILL_OUT_DIR:-$ROOT/out}"

# The production SLOs from docs/slo.md.
SLO_AVAILABILITY_PCT=99.9
SLO_LATENCY_PCT=99
SLO_LATENCY_MS=250

DEPLOY_ONLY=false
KEEP="${KEEP_CLUSTER:-false}"
for arg in "$@"; do
  case "$arg" in
    --deploy-only) DEPLOY_ONLY=true KEEP=true ;;
    --keep) KEEP=true ;;
    *) echo "usage: $0 [--keep] [--deploy-only]" >&2; exit 2 ;;
  esac
done

mkdir -p "$OUT_DIR"
EVENTS="$OUT_DIR/drill-events.log"
: >"$EVENTS"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
event() { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$EVENTS"; }
now() { date +%s.%N; }
since() { awk -v s="$1" -v e="$(now)" 'BEGIN { printf "%.1f", e - s }'; }
k() { kubectl -n "$NS" "$@"; }

# On failure, print what an on-call engineer would look at first, so a red CI
# run explains itself without anyone needing to reproduce it.
diagnose() {
  echo
  echo "---- diagnostics ----"
  kubectl get nodes -o wide 2>/dev/null || return 0
  kubectl get pods -A -o wide 2>/dev/null
  echo "---- recent events in $NS ----"
  kubectl -n "$NS" get events --sort-by=.lastTimestamp 2>/dev/null | tail -25
  for pod in $(kubectl -n "$NS" get pods --field-selector=status.phase=Failed -o name 2>/dev/null); do
    echo "---- logs: $pod ----"
    kubectl -n "$NS" logs "$pod" --tail=30 2>/dev/null
  done
}

cleanup() {
  local code=$?
  if [[ -n "${CHAOS_PID:-}" ]]; then kill "$CHAOS_PID" 2>/dev/null || true; fi
  if [[ "$code" -ne 0 ]]; then diagnose; fi
  if [[ "$KEEP" != true ]]; then
    step "Deleting the cluster"
    kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
  fi
  exit "$code"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
step "Building a 3-node Kubernetes cluster from scratch"
kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
t=$(now)
kind create cluster --name "$CLUSTER" --image "$KIND_NODE_IMAGE" --config deploy/kind/cluster.yaml --wait 180s
CLUSTER_SECONDS=$(since "$t")
K8S_VERSION=$(kubectl version -o json | jq -r .serverVersion.gitVersion)
NODES=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
event "cluster ready: $NODES nodes, Kubernetes $K8S_VERSION, ${CLUSTER_SECONDS}s"

step "Loading images into the nodes"
# Multi-arch images are an index that names every platform, but the host only
# downloaded its own platform's layers. kind imports with --all-platforms, so
# export just the host platform first or the import fails on missing layers.
PLATFORM="linux/$(docker version --format '{{.Server.Arch}}')"
side_load() {
  local archive
  archive="$OUT_DIR/$(tr -c 'a-zA-Z0-9' '_' <<<"$1").tar"
  docker save --platform "$PLATFORM" -o "$archive" "$1"
  kind load image-archive "$archive" --name "$CLUSTER"
  rm -f "$archive"
}
side_load "$IMAGE"
if [[ "$DEPLOY_ONLY" != true ]]; then
  # Pull the load generator by digest on the host, then side-load it, so the
  # drill never depends on Docker Hub's anonymous rate limit mid-run.
  docker pull -q --platform "$PLATFORM" "$K6_IMAGE" >/dev/null
  K6_LOCAL="${K6_IMAGE%@*}"
  docker tag "$K6_IMAGE" "$K6_LOCAL"
  side_load "$K6_LOCAL"
fi

step "Installing metrics-server so the autoscaler can see CPU"
helm upgrade --install metrics-server metrics-server \
  --repo https://kubernetes-sigs.github.io/metrics-server/ \
  --version "$METRICS_SERVER_CHART_VERSION" --namespace kube-system \
  --set 'args={--kubelet-insecure-tls}' --wait --timeout 180s >/dev/null

step "Creating namespace '$NS' with Pod Security 'restricted' enforced"
kubectl create namespace "$NS" >/dev/null
kubectl label namespace "$NS" >/dev/null \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest

step "Deploying with Helm"
t=$(now)
helm upgrade --install resume deploy/helm/resume --namespace "$NS" \
  --set image.repository="${IMAGE%:*}" --set image.tag="${IMAGE##*:}" --set image.pullPolicy=Never \
  --wait --timeout 180s >/dev/null
# Helm waits for the Deployment it created, which starts at one replica: with
# an autoscaler in charge the chart deliberately sets no replica count, so the
# HPA raises it to minReplicas. Wait for that before calling it deployed.
MIN_REPLICAS=$(helm get values resume --namespace "$NS" --all -o json | jq .autoscaling.minReplicas)
k wait --for=jsonpath='{.status.readyReplicas}'="$MIN_REPLICAS" deployment/resume --timeout=120s >/dev/null
DEPLOY_SECONDS=$(since "$t")
event "deployed: $MIN_REPLICAS replicas ready in ${DEPLOY_SECONDS}s"
helm test resume --namespace "$NS" --timeout 90s >/dev/null
event "helm test passed: the Service serves the page"
k get pods -o wide

if [[ "$DEPLOY_ONLY" == true ]]; then
  cat <<EOF

Cluster '$CLUSTER' is up. To see the site (refresh to watch the serving pod change):

  kubectl -n $NS port-forward svc/resume 8080:80
  open http://localhost:8080

Tear it down with: make down
EOF
  exit 0
fi

# ---------------------------------------------------------------------------
# Guardrails. Each check has a control, so a pass means the guard works, not
# that the probe was broken.

# probe NAMESPACE NAME URL [WAIT]: run the app's own healthcheck as a pod and
# print its final phase. WAIT lets it retry; the negative test uses none.
probe() {
  local ns=$1 name=$2 url=$3 wait=${4:-0s} phase=""
  kubectl -n "$ns" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $name
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: {runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: probe
      image: $IMAGE
      imagePullPolicy: Never
      args: [healthcheck, -wait, "$wait", -url, "$url"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        runAsUser: 65532
        capabilities: {drop: [ALL]}
      resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {memory: 32Mi}}
EOF
  for _ in $(seq 1 90); do
    phase=$(kubectl -n "$ns" get pod "$name" -o jsonpath='{.status.phase}')
    if [[ "$phase" == Succeeded || "$phase" == Failed ]]; then break; fi
    sleep 1
  done
  echo "$phase"
}

step "Guardrail: Pod Security must reject a privileged pod"
cat >"$OUT_DIR/privileged-pod.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: privileged-probe
spec:
  containers:
    - name: c
      image: $IMAGE
      securityContext: {privileged: true}
EOF
PSA_REJECTED=false
if out=$(kubectl -n "$NS" apply -f "$OUT_DIR/privileged-pod.yaml" 2>&1); then
  event "FAIL: a privileged pod was admitted"
  k delete pod privileged-probe --wait=false >/dev/null 2>&1 || true
elif grep -q "violates PodSecurity" <<<"$out"; then
  PSA_REJECTED=true
  event "privileged pod rejected at admission (PodSecurity restricted)"
else
  event "FAIL: privileged pod failed for an unexpected reason: $out"
fi

step "Guardrail: NetworkPolicy must block traffic from other namespaces"
kubectl create namespace intruder >/dev/null
URL="http://resume.$NS.svc.cluster.local/healthz"
inside=$(probe "$NS" np-inside "$URL" 20s)
outside=$(probe intruder np-outside "$URL")
NETPOL_BLOCKED=false
if [[ "$inside" == Succeeded && "$outside" == Failed ]]; then
  NETPOL_BLOCKED=true
  event "same-namespace request allowed, cross-namespace request blocked"
else
  event "FAIL: network policy check: inside=$inside outside=$outside (want Succeeded/Failed)"
fi
k delete pod np-inside --wait=false >/dev/null
kubectl delete namespace intruder --wait=false >/dev/null

# ---------------------------------------------------------------------------
step "Load test: $RATE req/s for ${DURATION}s while breaking things"
k create configmap k6-script --from-file=k6.js=loadtest/k6.js >/dev/null
k apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: loadtest
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      # The load generator lives on the control-plane node, so draining a
      # worker never takes out the thing measuring the damage.
      nodeSelector: {node-role.kubernetes.io/control-plane: ""}
      tolerations:
        - {key: node-role.kubernetes.io/control-plane, operator: Exists, effect: NoSchedule}
      securityContext: {runAsNonRoot: true, runAsUser: 12345, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: k6
          image: $K6_LOCAL
          imagePullPolicy: Never
          args: [run, --quiet, /scripts/k6.js]
          env:
            - {name: TARGET, value: "http://resume.$NS.svc.cluster.local"}
            - {name: RATE, value: "$RATE"}
            - {name: DURATION, value: "$DURATION"}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL]}
          resources: {requests: {cpu: 250m, memory: 128Mi}, limits: {memory: 512Mi}}
          volumeMounts:
            - {name: script, mountPath: /scripts, readOnly: true}
            - {name: tmp, mountPath: /tmp}
      volumes:
        - {name: script, configMap: {name: k6-script}}
        - {name: tmp, emptyDir: {}}
EOF
k wait --for=jsonpath='{.status.active}'=1 job/loadtest --timeout=120s >/dev/null
LOAD_START=$(now)
event "load started"

CHAOS_LOG="$OUT_DIR/chaos.tsv"
: >"$CHAOS_LOG"

# Sleep until a fraction of the load window has elapsed. Always printf in awk:
# plain `print` uses %.6g, which turns an epoch timestamp into 1.79539e+09.
at() {
  local target
  target=$(awk -v s="$LOAD_START" -v d="$DURATION" -v f="$1" 'BEGIN { printf "%.3f", s + d * f }')
  sleep "$(awk -v t="$target" -v n="$(now)" 'BEGIN { x = t - n; printf "%.3f", (x > 0 ? x : 0) }')"
}

app_pods() { k get pods -l app.kubernetes.io/name=resume --field-selector=status.phase=Running -o name; }

kill_pod() {
  local pod
  pod=$(app_pods | shuf -n 1)
  k delete "$pod" --wait=false >/dev/null
  printf 'kill\t%s\n' "${pod#pod/}" >>"$CHAOS_LOG"
  event "chaos: killed ${pod#pod/}"
}

rollout() {
  event "chaos: rolling restart (a deploy) started"
  k rollout restart deployment/resume >/dev/null
  k rollout status deployment/resume --timeout=150s >/dev/null
  printf 'rollout\tresume\n' >>"$CHAOS_LOG"
  event "chaos: rolling restart finished"
}

drain_node() {
  local node
  node=$(k get pods -l app.kubernetes.io/name=resume -o jsonpath='{.items[0].spec.nodeName}')
  event "chaos: draining node $node (evictions respect the PodDisruptionBudget)"
  kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --timeout=150s >/dev/null 2>&1
  printf 'drain\t%s\n' "$node" >>"$CHAOS_LOG"
  event "chaos: $node drained"
  sleep 10
  kubectl uncordon "$node" >/dev/null
  event "chaos: $node back in service"
}

chaos() {
  at 0.10; kill_pod
  at 0.20; kill_pod
  at 0.30; rollout
  at 0.50; drain_node
  at 0.75; kill_pod
  at 0.85; kill_pod
}
chaos &
CHAOS_PID=$!

# Watch replica count (the autoscaler may add pods) until k6 finishes.
MAX_REPLICAS=0
deadline=$(awk -v s="$LOAD_START" -v d="$DURATION" 'BEGIN { printf "%.3f", s + d + 120 }')
while :; do
  r=$(k get deployment resume -o jsonpath='{.status.replicas}')
  ((r > MAX_REPLICAS)) && MAX_REPLICAS=$r
  status=$(k get job loadtest -o jsonpath='{.status.succeeded}/{.status.failed}')
  [[ "$status" == 1/* || "$status" == */1 ]] && break
  if awk -v d="$deadline" -v n="$(now)" 'BEGIN { exit !(n > d) }'; then
    event "FAIL: load test did not finish in time"
    exit 1
  fi
  sleep 3
done
wait "$CHAOS_PID" || true
CHAOS_PID=""
event "load finished (job status succeeded/failed = $status)"

# ---------------------------------------------------------------------------
step "Judging the SLO"
SUMMARY="$OUT_DIR/k6-summary.json"
k logs job/loadtest | sed -n '/===K6_SUMMARY_BEGIN===/,/===K6_SUMMARY_END===/p' | sed '1d;$d' >"$SUMMARY"
if ! jq -e .metrics >/dev/null 2>&1 <"$SUMMARY"; then
  event "FAIL: could not read the k6 summary"
  k logs job/loadtest | tail -20
  exit 1
fi

PODS_KILLED=$(grep -c '^kill' "$CHAOS_LOG" || true)
ROLLOUTS=$(grep -c '^rollout' "$CHAOS_LOG" || true)
DRAINS=$(grep -c '^drain' "$CHAOS_LOG" || true)

jq -n \
  --slurpfile s "$SUMMARY" \
  --arg ran_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg k8s "$K8S_VERSION" \
  --argjson nodes "$NODES" \
  --argjson cluster_s "$CLUSTER_SECONDS" \
  --argjson deploy_s "$DEPLOY_SECONDS" \
  --argjson killed "$PODS_KILLED" \
  --argjson rollouts "$ROLLOUTS" \
  --argjson drains "$DRAINS" \
  --argjson max_replicas "$MAX_REPLICAS" \
  --argjson psa "$PSA_REJECTED" \
  --argjson netpol "$NETPOL_BLOCKED" \
  --argjson slo_avail "$SLO_AVAILABILITY_PCT" \
  --argjson slo_lat_pct "$SLO_LATENCY_PCT" \
  --argjson slo_lat_ms "$SLO_LATENCY_MS" '
  ($s[0].metrics) as $m
  | ($m.http_reqs.values.count) as $req
  | ($m.http_req_failed.values.passes) as $failed
  | (if $req > 0 then 100 * ($req - $failed) / $req else 0 end) as $success
  | ($m.http_req_duration.values["p(99)"]) as $p99
  | {
      ran_at: $ran_at, kubernetes: $k8s, nodes: $nodes,
      cluster_create_seconds: $cluster_s, deploy_seconds: $deploy_s,
      duration_seconds: (($s[0].state.testRunDurationMs // 0) / 1000),
      requests: $req, failed: $failed, success_pct: $success,
      p95_ms: $m.http_req_duration.values["p(95)"], p99_ms: $p99,
      pods_killed: $killed, rollouts: $rollouts, node_drains: $drains,
      max_replicas: $max_replicas,
      pod_security_rejected: $psa, network_policy_blocked: $netpol,
      slo: {
        availability_pct: $slo_avail, latency_pct: $slo_lat_pct, latency_ms: $slo_lat_ms,
        met: ($success >= $slo_avail and $p99 <= $slo_lat_ms)
      }
    }' >"$OUT_DIR/drill.json"

jq -r '
  "  cluster      \(.nodes) nodes, Kubernetes \(.kubernetes), built in \(.cluster_create_seconds)s, deployed in \(.deploy_seconds)s",
  "  traffic      \(.requests) requests over \(.duration_seconds | floor)s, \(.failed) failed",
  "  chaos        \(.pods_killed) pods killed, \(.rollouts) rolling deploy, \(.node_drains) node drained, up to \(.max_replicas) replicas",
  "  guardrails   privileged pod rejected: \(.pod_security_rejected), cross-namespace blocked: \(.network_policy_blocked)",
  "  result       \(.success_pct * 1000 | floor / 1000)% success, p95 \(.p95_ms * 10 | floor / 10) ms, p99 \(.p99_ms * 10 | floor / 10) ms",
  "  objective    \(.slo.availability_pct)% success and \(.slo.latency_pct)% under \(.slo.latency_ms) ms: \(if .slo.met then "MET" else "MISSED" end)"
' "$OUT_DIR/drill.json"

if ! jq -e '.slo.met and .pod_security_rejected and .network_policy_blocked' "$OUT_DIR/drill.json" >/dev/null; then
  echo
  echo "Drill FAILED. Events:" >&2
  cat "$EVENTS" >&2
  exit 1
fi
echo
echo "Drill passed. Results: $OUT_DIR/drill.json"
