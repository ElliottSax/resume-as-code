#!/usr/bin/env bash
# Add Prometheus, Alertmanager and Grafana (kube-prometheus-stack) to the
# local cluster from `make up`, then switch on the chart's ServiceMonitor,
# SLO alert rules and Grafana dashboard.
#
#   scripts/observe.sh           # monitoring on, dashboard wired up
#   scripts/observe.sh --break   # also fail 20% of requests under steady
#                                # traffic, and watch the burn-rate alert fire
#   scripts/observe.sh --fix     # turn the fault injection back off
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=../tools.env
source tools.env

CLUSTER="${CLUSTER_NAME:-resume-drill}"
NS=resume
MODE="${1:-}"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

kubectl config use-context "kind-$CLUSTER" >/dev/null
if ! helm status resume -n "$NS" >/dev/null 2>&1; then
  echo "No 'resume' release in cluster '$CLUSTER'. Run 'make up' first." >&2
  exit 1
fi

if [[ "$MODE" == --fix ]]; then
  step "Turning fault injection off"
  helm upgrade resume deploy/helm/resume -n "$NS" --reuse-values --set env=null --wait >/dev/null
  kubectl -n "$NS" delete job traffic --ignore-not-found >/dev/null
  echo "Done. The burn-rate alert resolves once the 5-minute window is clean."
  exit 0
fi

if ! helm status monitoring -n monitoring >/dev/null 2>&1; then
  step "Installing kube-prometheus-stack $KUBE_PROMETHEUS_STACK_VERSION (takes a few minutes)"
  GRAFANA_PASSWORD=$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
  helm upgrade --install monitoring kube-prometheus-stack \
    --repo https://prometheus-community.github.io/helm-charts \
    --version "$KUBE_PROMETHEUS_STACK_VERSION" \
    --namespace monitoring --create-namespace \
    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
    --set prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues=false \
    --set prometheus.prometheusSpec.evaluationInterval=30s \
    --set grafana.sidecar.dashboards.searchNamespace=ALL \
    --set grafana.adminPassword="$GRAFANA_PASSWORD" \
    --wait --timeout 10m >/dev/null
  echo "Grafana login: admin / $GRAFANA_PASSWORD"
fi

step "Switching on the ServiceMonitor, SLO rules and dashboard"
helm upgrade resume deploy/helm/resume -n "$NS" --reuse-values \
  --set metrics.serviceMonitor.enabled=true \
  --set metrics.prometheusRule.enabled=true \
  --set metrics.grafanaDashboard.enabled=true \
  --wait >/dev/null
kubectl -n "$NS" get servicemonitor,prometheusrule,configmap -l app.kubernetes.io/name=resume

if [[ "$MODE" == --break ]]; then
  step "Injecting faults: 20% of page requests will return 503"
  helm upgrade resume deploy/helm/resume -n "$NS" --reuse-values \
    --set env.FAULT_ERROR_RATIO=0.2 --wait >/dev/null

  step "Sending steady traffic for 20 minutes"
  kubectl -n "$NS" create configmap k6-script --from-file=k6.js=loadtest/k6.js \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "$NS" delete job traffic --ignore-not-found >/dev/null
  kubectl -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: traffic
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext: {runAsNonRoot: true, runAsUser: 12345, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: k6
          image: $K6_IMAGE
          # Thresholds will fail on purpose here; the point is the traffic.
          args: [run, --quiet, --no-thresholds, /scripts/k6.js]
          env:
            - {name: TARGET, value: "http://resume.$NS.svc.cluster.local"}
            - {name: RATE, value: "20"}
            - {name: DURATION, value: "1200"}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL]}
          resources: {requests: {cpu: 50m, memory: 64Mi}, limits: {memory: 256Mi}}
          volumeMounts:
            - {name: script, mountPath: /scripts, readOnly: true}
            - {name: tmp, mountPath: /tmp}
      volumes:
        - {name: script, configMap: {name: k6-script}}
        - {name: tmp, emptyDir: {}}
EOF
  cat <<EOF

Faults are on. In about 3 minutes, ResumeErrorBudgetBurnFast goes from
Pending to Firing (Prometheus → Alerts, or Alertmanager). The alert links to
docs/runbooks/high-error-rate.md, which explains how to find the cause.
Undo with: scripts/observe.sh --fix
EOF
fi

cat <<EOF

Open these in separate terminals:
  kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80                      # http://localhost:3000, dashboard "resume-as-code / SLOs"
  kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090      # http://localhost:9090/alerts
  kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-alertmanager 9093    # http://localhost:9093
EOF
