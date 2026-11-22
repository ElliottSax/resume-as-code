# 0007: Gateway API instead of Ingress

**Status:** accepted

## Context

`Ingress` is frozen: it gets no new features, and annotations fill the gaps differently for each controller. The most widely used controller, ingress-nginx, was retired by the Kubernetes project in 2026. [Gateway API](https://gateway-api.sigs.k8s.io/) is the successor. It is role-oriented (platform teams own `Gateway`s, app teams own `HTTPRoute`s), portable across implementations, and expressive without annotations.

## Decision

The chart ships an optional `HTTPRoute` (`httpRoute.enabled`) that attaches to a `Gateway` the platform provides. There is no `Ingress` template.

## Consequences

- An app team only needs to know the name of the Gateway to attach to. TLS, listeners and load balancers belong to whoever runs the Gateway.
- The kind drill doesn't install a Gateway implementation. It tests the service through its ClusterIP from inside the cluster, which is where the SLO is judged. The `HTTPRoute` is checked against the Gateway API schema by kubeconform in CI.
