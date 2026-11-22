# 0006: Pin every input by digest, SHA or checksum

**Status:** accepted

## Context

A build is only as trustworthy as its least trustworthy input. Tags move: `actions/foo@v4`, `golang:1.27` and `kindest/node:latest` can point at different bytes tomorrow, by accident or because someone hijacked a release. Attacks that move GitHub Action tags to malicious commits have hit popular actions more than once.

## Decision

- GitHub Actions pinned to **full commit SHAs**, with the version in a comment.
- Container base images and drill images pinned by **`sha256` digest**.
- CLI tools pinned to **exact versions** in [`tools.env`](../../tools.env) and **checksum-verified** on download, by the same script on laptops and in CI.
- Go modules verified against `go.sum` during the image build.
- Terraform providers locked with hashes.
- **Dependabot** proposes every bump as a PR, and the PR runs the full pipeline, chaos drill included.

## Consequences

- Builds are reproducible, and an upstream change can't reach production without a reviewed, tested PR.
- Pins go stale unless updated. Dependabot plus the weekly scheduled rescan cover this: a new CVE in a pinned base image fails the Monday build.
- SHAs are unreadable, so every pin carries a version comment.
