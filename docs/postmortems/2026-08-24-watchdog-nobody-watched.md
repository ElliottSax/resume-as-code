# The watchdog nobody watched

| | |
|---|---|
| **Date** | 2026-08-24 |
| **Duration** | 7 h 45 m |
| **Impact** | Self-hosted LLM API gateway completely down. Every automated job that depended on it failed. |
| **Detection** | Manual, the next morning. No alert existed. |
| **Status** | Closed |

## Summary

I run a self-hosted LLM API gateway ([LiteLLM](https://github.com/BerriAI/litellm)) that routes my automation jobs across providers. A watchdog process restarts the gateway if it dies. At 02:16 the host machine suspended, and the suspend killed the gateway *and* the watchdog together. The thing responsible for self-healing was itself dead, so nothing came back until I noticed hours later.

## Timeline

| Time | Event |
|---|---|
| 02:16 | Host suspends. Gateway and watchdog processes both die. |
| 02:16–10:01 | Every job that needs the gateway fails. Nothing restarts anything. |
| ~10:01 | Noticed by hand. Services restarted manually. |
| Same day | External supervisor added: an OS-level scheduled task, every 5 minutes. |

## What happened

The design had one layer of supervision: watchdog → gateway. That protects against the gateway crashing on its own. It does nothing about an event that takes out both, such as a suspend, a reboot or an out-of-memory sweep, because the watchdog runs in the same failure domain as what it watches.

## Contributing factors

- **Supervisor and supervised shared a failure domain.** Same host, same lifecycle, no independent restart.
- **No external health check.** Nothing outside the box ever asked "is the gateway answering?".
- **No alerting.** Even a dumb "no successful request in 30 minutes" alert would have cut the outage from hours to minutes.

## What went well / badly / lucky

- **Well:** once noticed, recovery was a restart. No data was lost.
- **Badly:** the watchdog gave a false sense of safety. It felt like the system self-healed.
- **Lucky:** it happened overnight, when little depended on it.

## Action items

| Action | Type | Status |
|---|---|---|
| OS scheduled task runs an idempotent start-up script every 5 minutes. It checks ports and PIDs and starts only what is dead, so running it often is safe. | prevent | done |
| A login trigger for the same script was tried and refused with "Access is denied" (it needs elevation). Recorded as a known gap. The 5-minute trigger covers it. | prevent | accepted |
| A credential health check that sends real requests. Configured-but-revoked keys looked healthy to a presence check, so they silently retried and fell through to a paid provider. | detect | done |

## The same pattern, three days later

A different system of mine, a 24/7 render pipeline, had a monitor that logged "Factory process is NOT running" **every hour for days** and never acted on it. Its alert was rate-limited into silence. It now restarts the process, and runs every 15 minutes instead of hourly. Same lesson, learned twice: **detection without action is not supervision.**

## What this changed in resume-as-code

- Kubernetes *is* the external supervisor: the kubelet restarts containers, the Deployment controller replaces pods, and a node drain moves them. None of it runs inside the thing it watches.
- Liveness and readiness are separate probes ([`server.go`](../../app/internal/server/server.go)). Liveness never checks dependencies, so a downstream blip can't make Kubernetes restart every pod at once.
- `ResumeAllReplicasDown` fires when the scrape target **disappears**, not only when it reports down. Silence is not health.
- The chaos drill kills pods on purpose on every release, so self-healing is shown working, not assumed.
