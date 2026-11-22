# Service level objectives

An SLO is a promise about reliability that is specific enough to be measured and cheap enough to keep. It replaces "it should never go down", which nobody can keep and everyone ignores, with a number that drives decisions.

## What users care about

Someone opens the resume. They need the page to load, and to load quickly. Those are the only two things measured.

| | SLI (what is measured) | SLO (the target) | Error budget (30 days) |
|---|---|---|---|
| **Availability** | Page requests that don't return 5xx ÷ all page requests | **99.9%** | 0.1%, about 43 minutes of total outage |
| **Latency** | Page requests served in ≤ 250 ms ÷ all page requests | **99%** | 1% of requests may be slower |

The SLI comes from `http_requests_total` and `http_request_duration_seconds` (see [`server.go`](../app/internal/server/server.go)). Health probes are excluded, because the kubelet isn't a user. 4xx responses count as successes, because a request for a missing page that gets a 404 was handled correctly.

**Why 99.9% and not 99.99%?** Each extra nine costs about ten times more effort, and users can't tell 99.9% from 99.99% on a resume. A 43-minute monthly budget is enough to ship often and roll back calmly.

**Why 250 ms?** The page is pre-rendered and served from memory in about a millisecond, so 250 ms leaves plenty of room for networks, cold starts and noisy neighbours while still feeling instant. The histogram has a bucket at exactly 0.25 s, so the SLI is an exact count, not an estimate.

## How the SLO is enforced

The same objective is checked in three places:

1. **Before release.** The [chaos drill](../scripts/drill.sh) measures availability and p99 latency from the client side while it kills pods, drains a node and rolls out a deploy. If it misses 99.9% / 99% under 250 ms, the release stops.
2. **In production.** [Burn-rate alerts](../deploy/helm/resume/files/slo-rules.yaml) watch the error budget continuously.
3. **In CI.** [Unit tests for the alerts](../observability/tests/slo-rules.test.yaml) replay synthetic outages and prove the right alert fires, and only the right one.

## Alerting: burn rates, not thresholds

A threshold alert like "error rate > 1% for 5 minutes" is either too twitchy, paging for a blip, or too slow, missing a steady leak. Burn-rate alerts instead ask how fast the budget is being spent:

| Alert | Fires when | Burn rate | Budget gone in | Response |
|---|---|---|---|---|
| `ResumeErrorBudgetBurnFast` | 1 h **and** 5 m windows both over 1.44% errors | 14.4× | ~2 days | page |
| | *or* 6 h **and** 30 m windows over 0.6% | 6× | ~5 days | page |
| `ResumeErrorBudgetBurnSlow` | 1 d **and** 2 h windows over 0.3% | 3× | ~10 days | ticket |
| | *or* 3 d **and** 6 h windows over 0.1% | 1× | 30 days | ticket |
| `ResumeLatencyBudgetBurnFast` | same structure against the 1% latency budget | 14.4× / 6× | ~2 / ~5 days | page |

The long window confirms the problem is real, and the short window confirms it is still happening, so an alert resets minutes after recovery instead of hours. This is the method from chapter 5 of Google's *Site Reliability Workbook*.

Two supporting alerts cover what the SLIs can't see: `ResumeAllReplicasDown` (no target to measure means silence, and silence isn't health) and `ResumeReplicasDegraded` (one failure away from an outage).

## Error budget policy

The budget is there to be spent on shipping. When it runs out, priorities change:

- **More than 50% of the budget left:** ship freely.
- **Under 50%:** every change needs a rollback plan in its PR description.
- **Exhausted:** feature work stops. The next changes must be reliability fixes or reverts, until the 30-day window recovers.
- **One incident ate more than 20% of the budget:** it gets a [postmortem](postmortems/README.md).
