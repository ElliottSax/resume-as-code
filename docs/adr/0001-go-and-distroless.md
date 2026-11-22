# 0001: A Go service in a distroless image

**Status:** accepted

## Context

A resume could be a static HTML file. The point of this project is to show how a real service is built and run: health checks, metrics, graceful shutdown and a container to scan and sign. The service has to be small enough to read in one sitting, and hardened by default.

## Decision

- **Go**, standard library first: `net/http`, `log/slog`, `html/template`. Two dependencies: the Prometheus client and a YAML parser.
- **Pre-render at start-up.** The page is rendered once and served from memory. A request costs a memory copy, so latency SLOs are about the platform, not the code.
- **Static binary on `distroless/static`.** `CGO_ENABLED=0` gives a binary with no libc dependency. The runtime image has no shell, no package manager and no libc, and runs as UID 65532.
- **The binary checks itself.** With no shell or curl in the image, `resume healthcheck` is the Docker HEALTHCHECK, the `helm test` client and the drill's network probe.

## Consequences

- The image is a few MB compressed, and Trivy finds nothing to report in it. There is almost nothing to patch.
- You can't `kubectl exec` into a shell to debug. That is intended: debugging uses logs, metrics and `kubectl debug` with an ephemeral container, never a shell that would also be there for an attacker.
- Go is the language most Kubernetes tooling is written in, so the same skills transfer to operators and controllers.
