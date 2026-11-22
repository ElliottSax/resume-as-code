# 0004: Kyverno in CI, Pod Security Admission in the cluster

**Status:** accepted

## Context

Security rules for workloads (non-root, no privilege escalation, dropped capabilities, read-only filesystem, resource requests, pinned images, probes) need to hold in two places: in review, so a bad change never merges, and at the cluster door, so nothing bypasses review.

## Decision

- **In CI:** [Kyverno](https://kyverno.io/) `ValidatingPolicy` resources (CEL) run against the rendered Helm chart with `kyverno apply`. They are tested with `kyverno test` against a known-good and a known-bad manifest: every policy must pass the first and fail the second.
- **In the cluster:** the built-in [Pod Security Admission](https://kubernetes.io/docs/concepts/security/pod-security-admission/) controller enforces the `restricted` profile on the namespace. It needs no extra component.
- **The drill checks the door is shut.** It tries to create a privileged pod and requires a rejection.

## Consequences

- No admission webhook to run, upgrade or monitor. PSA is part of the API server.
- PSA's rules are fixed. Rules beyond `restricted`, such as pinned images and probes, are enforced only in CI. A cluster with several teams would also run Kyverno or Gatekeeper as an admission controller, with the same policy files.
- The policies have tests, and that caught a real bug: Kyverno 1.20 silently skipped five of seven policies when YAML anchors were shared across `---` documents. Without `kyverno test`, CI would have reported green while enforcing two rules.
