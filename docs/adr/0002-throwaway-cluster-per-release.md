# 0002: A throwaway cluster per release instead of a permanent one

**Status:** accepted

## Context

The usual portfolio move is a permanent managed Kubernetes cluster. That costs about $70+/month for the control plane alone, plus nodes, for a page that gets a few visits a day. A permanent cluster also proves less than it seems: it shows the platform worked once, when it was set up, not that it still builds from scratch today.

## Decision

Every release builds a fresh three-node [kind](https://kind.sigs.k8s.io/) cluster on the CI runner, deploys the signed image with Helm, attacks it under load, judges the SLO, publishes the results and deletes the cluster. The public site is static on GitHub Pages. [Cloud Run](0005-cloud-run-production.md) is the path to a live service when there is a reason to pay for one.

## Consequences

- **$0 to run.** Public-repo Actions minutes are free.
- **Reproducibility is proven, not claimed.** The cluster, chart and policies are rebuilt from nothing on every release. Anything that only worked because of state left on a long-lived cluster fails here.
- **The published numbers come from a real run**, linked to the Actions run that produced them.
- **Limits.** kind is not a cloud: there are no real load balancers, cloud disks or multi-zone failures. The drill tests the application and Kubernetes layers, not the cloud underneath. Node drains stand in for zone failures.
- **Shared runners are noisy.** Latency numbers vary between runs. The SLO thresholds (p99 < 250 ms) leave enough margin that only a real regression fails the gate.
