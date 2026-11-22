# 0003: CPU requests without CPU limits; memory limits with GOMEMLIMIT

**Status:** accepted

## Context

Kubernetes resource settings are easy to get subtly wrong:

- **CPU limits** are enforced by CFS quota. A container that uses its quota early in a 100 ms period is throttled for the rest of it, *even if the node has idle cores*. For a latency-sensitive service that shows up as tail latency for no visible reason.
- **Memory** is not compressible. A process over its limit is OOM-killed, and nothing smooths that out.

## Decision

- Set **CPU requests** (25m) so the scheduler places pods fairly and the HPA has a baseline. Set **no CPU limit**.
- Set a **memory request and limit** (32 Mi / 64 Mi).
- Pass the memory limit to the Go runtime as `GOMEMLIMIT` through the Downward API, so the garbage collector works harder as it nears the ceiling instead of being killed at it.
- Recent Go versions read the cgroup CPU limit for `GOMAXPROCS` automatically. With no CPU limit, Go uses the node's cores, which is fine for a service that is mostly idle.

## Consequences

- No CFS throttling, so p99 latency reflects real load.
- One pod could use more than its share of a node's CPU. The requests still guarantee every pod its fair share under contention, which is the property that matters.
- The Kyverno policy requires CPU *requests* and a memory *limit*, but deliberately not a CPU limit.
