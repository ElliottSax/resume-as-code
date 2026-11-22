# Architecture decision records

Short notes on the decisions that shaped this repository: the context, what was chosen, and what that costs. Written so that "why is it like this?" has an answer that doesn't depend on anyone's memory.

| # | Decision |
|---|---|
| [0001](0001-go-and-distroless.md) | A Go service in a distroless image |
| [0002](0002-throwaway-cluster-per-release.md) | A throwaway cluster per release instead of a permanent one |
| [0003](0003-requests-without-cpu-limits.md) | CPU requests without CPU limits; memory limits with GOMEMLIMIT |
| [0004](0004-policy-in-ci-and-at-admission.md) | Kyverno in CI, Pod Security Admission in the cluster |
| [0005](0005-cloud-run-production.md) | Google Cloud Run as the production target |
| [0006](0006-pin-everything.md) | Pin every input by digest, SHA or checksum |
| [0007](0007-gateway-api.md) | Gateway API instead of Ingress |
