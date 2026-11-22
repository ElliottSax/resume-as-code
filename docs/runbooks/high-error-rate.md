# Runbook: error budget burning

**Alerts:** `ResumeErrorBudgetBurnFast` (page), `ResumeErrorBudgetBurnSlow` (ticket)
**SLO:** 99.9% of page requests succeed, measured over 30 days ([slo.md](../slo.md))

## What it means

More than the allowed share of requests is returning 5xx.

- **Fast burn** means more than 2% of the month's error budget is going per hour. At that rate the budget is gone in about two days. Act now.
- **Slow burn** means the budget will run out before the window ends if nothing changes. Fix it this week.

## First five minutes

1. **Is it real?** Open the SLO dashboard (`resume-as-code / SLOs`). Look at *Requests per second by status code*. Check whether the 5xx share is visible, and whether it's all routes or only `index`.
2. **Did something just change?** Most incidents follow a change.
   ```sh
   helm history resume -n resume
   kubectl -n resume rollout history deployment/resume
   ```
   If a deploy went out in the last hour, **roll back first and investigate second**:
   ```sh
   helm rollback resume -n resume        # previous revision
   kubectl -n resume rollout status deployment/resume
   ```
3. **Is fault injection on?** The demo switch can be left enabled by accident:
   ```sh
   kubectl -n resume get deployment resume -o jsonpath='{.spec.template.spec.containers[0].env}' | grep -i fault
   ```
   If it's set, remove it with `helm upgrade resume deploy/helm/resume -n resume --reuse-values --set env=null`.

## Diagnose

```sh
kubectl -n resume get pods -o wide                     # restarts? pending? all on one node?
kubectl -n resume get events --sort-by=.lastTimestamp | tail -20
kubectl -n resume logs -l app.kubernetes.io/name=resume --since=15m | jq -c 'select(.status >= 500)' | head
```

Every log line carries a `request_id`, and the same ID is returned to the client in `X-Request-ID`. Use it to follow one failing request through the logs.

| You see | Likely cause | Do |
|---|---|---|
| 5xx from one pod only | a bad node or a stuck process | `kubectl -n resume delete pod <pod>`; cordon the node if it repeats |
| 5xx on every pod, right after a deploy | a bad release | roll back (above) |
| `http_handler_panics_total` rising | a code bug | roll back, then fix forward with a test |
| 503s while pods restart | crash loop or OOM kill | check `kubectl describe pod` for `OOMKilled`; raise the memory limit with care |

## Afterwards

If the budget took a real hit, write a postmortem ([template](../postmortems/README.md)). The [error budget policy](../slo.md#error-budget-policy) decides whether feature work pauses.
