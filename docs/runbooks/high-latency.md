# Runbook: latency budget burning

**Alert:** `ResumeLatencyBudgetBurnFast` (page)
**SLO:** 99% of page requests finish within 250 ms ([slo.md](../slo.md))

## What it means

Requests are succeeding but slowly. The page is pre-rendered and served from memory, so normal latency is around a millisecond. A latency problem almost always means the pods are starved, not that the code got slower.

## First five minutes

1. **Dashboard:** the *Latency percentiles* panel. Check whether p50 moved or only p99. A rise in p99 alone points to a few slow pods or a noisy neighbour.
2. **Fault injection:** check for `FAULT_DELAY` the same way as in [high-error-rate.md](high-error-rate.md#first-five-minutes).
3. **Saturation:**
   ```sh
   kubectl -n resume top pods
   kubectl -n resume get hpa resume          # pinned at maxReplicas?
   kubectl top nodes                          # a node near 100% CPU?
   ```

## Common causes

| You see | Likely cause | Do |
|---|---|---|
| HPA at `maxReplicas`, CPU high | more traffic than capacity | raise `autoscaling.maxReplicas`; check if the traffic is legitimate |
| One node hot, the others idle | pods packed onto one node | check topology spread; `kubectl drain` the hot node to rebalance |
| Memory near the 64 Mi limit | GC pressure (GOMEMLIMIT makes the GC work harder near the limit) | raise the memory limit and request together |
| Latency spike during a rollout | readiness passing before the pod is warm | check `startupProbe` and `readinessProbe` timings |

This service sets no CPU limit on purpose ([ADR 0003](../adr/0003-requests-without-cpu-limits.md)), so CFS throttling should not be the cause. Check that nobody added one.
