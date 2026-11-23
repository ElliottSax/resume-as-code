# Security policy

## Reporting a vulnerability

Please report security problems privately through GitHub's [private vulnerability reporting](https://github.com/ElliottSax/resume-as-code/security/advisories/new), not in a public issue. This is a one-person project: I'll acknowledge a report within a week and keep you posted until it's fixed.

## In scope

- The Go service and its container image
- The supply chain: signing, provenance, SBOM, pinned dependencies
- The Helm chart, Kyverno policies, Terraform and GitHub Actions workflows
- The published site: https://elliottsax.github.io/resume-as-code/

## Supported versions

Only the latest commit on `main`, which is what the pipeline deploys. The weekly rebuild rescans with a fresh vulnerability database, so a fix in a base image or dependency ships without waiting for a code change. [docs/supply-chain.md](docs/supply-chain.md) explains how to verify what's running.
