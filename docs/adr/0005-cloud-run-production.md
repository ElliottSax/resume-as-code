# 0005: Google Cloud Run as the production target

**Status:** accepted. The Terraform is validated in CI on every change but has **not been applied**: it needs a billing account, so turning it on is a deliberate step.

## Context

When a live service is worth having, it has to be cheap at idle, impossible to run up a surprise bill on, and deployable without long-lived credentials.

| Option | Idle cost | Notes |
|---|---|---|
| Managed Kubernetes (GKE, EKS, AKS) | ~$70+/month control plane, plus nodes | Overkill for one stateless service |
| A VM running k3s | ~$5–10/month, or a free tier | You patch the OS yourself |
| **Cloud Run** | **$0 when idle**, generous free tier | Same container, no cluster to run |

## Decision

[`infra/terraform/gcp-cloud-run`](../../infra/terraform/gcp-cloud-run/main.tf) defines:

- **Keyless deploys:** Workload Identity Federation trusts GitHub's OIDC issuer, limited to this repository's `main` branch. There are no service-account keys.
- **Least privilege:** the runtime identity has no roles. The deployer can push to one Artifact Registry repo and update one service.
- **A cost ceiling:** scale to zero, at most 2 instances, CPU billed only during requests, and an optional budget alert at 50/90/100% of $5.
- **Black-box monitoring:** an uptime check against `/healthz` from several regions, with an alert policy linked to the runbook.
- **Remote state** in a GCS bucket, so state is shared and locked.

## Consequences

- The same image runs on kind and Cloud Run, so the drill's results apply to it.
- Cloud Run has its own autoscaling, health checks and TLS. The Helm chart's HPA, PDB and NetworkPolicy don't apply there. Cloud Run's equivalents are concurrency-based scaling and IAM-gated ingress.
- Cloud Run can't pull from GHCR, so images are promoted to Artifact Registry by digest (`docker buildx imagetools create`), which keeps the signature valid.
