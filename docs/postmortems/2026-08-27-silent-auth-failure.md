# Two days of success-shaped failure

| | |
|---|---|
| **Date** | Found 2026-08-27 |
| **Duration** | About two days. The exact start is unknown, and that is part of the lesson. |
| **Impact** | Of 203 automated coding jobs in the preceding ~48 hours, 3 succeeded. 176 (87%) failed within a second of starting. |
| **Detection** | Manual investigation into why throughput "looked low". No alert. |
| **Status** | Closed |

## Summary

My autonomous job runner sends work through a local proxy to the LLM gateway. A config change made the gateway require an API key, and it only took effect at the gateway's next restart. When that restart came, one of the proxy's two code paths had never been updated to send the key. Every request on that path got a 401, fell through to a fallback provider whose account was also out of credit, and the job ended in under a second, reporting "completed" with no error.

## Timeline

| When | Event |
|---|---|
| 2026-08-25 | Key enforcement added to the gateway config, noted as "not enforced until the router restarts". |
| 2026-08-27 03:09 | Gateway restarts. Enforcement goes live. |
| ~2 days before discovery | Job success rate collapses. Some earlier failures came from a separately exhausted provider quota, and with no metrics, the two causes can't be separated after the fact. |
| 2026-08-27 | Investigated: 176 of 203 jobs tagged `no-files-changed`, each lasting 300–700 ms. |
| 2026-08-27 | Fixed, deployed, verified with a real end-to-end request and two probe jobs that came back `DONE`. |

## What happened

The proxy had two near-identical functions about 900 lines apart, one for each API format the gateway accepts. When key enforcement was planned, the OpenAI-format path got the `Authorization` header. The Anthropic-format path, the one most jobs used, did not.

Four things then lined up:

1. **A delayed-action config change.** Enforcement switched on at a restart two days after the edit, so nobody connected the effect to the change.
2. **Duplicated code drifted.** A fix applied to one copy, not the other.
3. **A fallback that hid the failure.** The 401 was swallowed by a fallback that also failed, and the original error never surfaced.
4. **Failure that looked like success.** Each job exited cleanly as "completed" with no error, after doing nothing.

## Contributing factors

- No metric for *job success rate*, only "is the process running?", which stayed green the whole time.
- The only signal was a tag, `no-files-changed`, which nobody watched.
- Fallbacks were logged at a level nobody read.

## What went well / badly / lucky

- **Well:** once someone looked, the `no-files-changed` signature pointed straight at "dying before doing any work", which narrowed the search fast.
- **Badly:** two days of near-total failure with every health indicator green.
- **Lucky:** the jobs were idempotent, so failed work could simply be re-queued.

## Action items

| Action | Type | Status |
|---|---|---|
| Send the `Authorization` header on the Anthropic-format path | fix | done |
| Fix the start-up credential check, which scanned raw YAML including comments and reported placeholder names as missing credentials (false alarms train people to ignore alarms) | detect | done |
| Treat a rising `no-files-changed` rate as the first thing to check when throughput drops | detect | documented |

## What this changed in resume-as-code

- **SLIs are measured from the user's side.** The drill judges availability from k6's view of every request, not from whether pods are "Running". An 87% error rate is an 870× burn rate. `ResumeErrorBudgetBurnFast` would page within about two minutes.
- **The alerts are tested.** [`slo-rules.test.yaml`](../../observability/tests/slo-rules.test.yaml) replays a total outage and asserts the page fires. An untested alert is a hope, not a control.
- **Config takes effect when it ships.** The app reads configuration at start-up, and every Helm upgrade rolls the pods, so nothing waits for a future restart to become live.
- **Health is more than liveness.** `/readyz` and the SLIs answer "can it serve?", not "is the process alive?".
