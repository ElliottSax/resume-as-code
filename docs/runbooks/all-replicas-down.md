# Runbook: no replica reachable

**Alerts:** `ResumeAllReplicasDown` (page). In production, also the Cloud Monitoring uptime check.

## What it means

Prometheus can't scrape a single replica. Either the service is down, or monitoring has lost sight of it. Both need a human, because a monitoring blind spot hides the next real outage.

## Is the service actually down?

Check from outside the cluster first. That is what users see.

```sh
curl -fsS -o /dev/null -w '%{http_code} %{time_total}s\n' https://elliottsax.github.io/resume-as-code/   # static site
kubectl -n resume port-forward svc/resume 8080:80 & curl -fsS localhost:8080/readyz                    # in-cluster
```

## If the service is down

```sh
kubectl -n resume get deploy,rs,pods -o wide
kubectl -n resume describe pods -l app.kubernetes.io/name=resume | grep -A5 -E 'State|Events'
```

| You see | Likely cause | Do |
|---|---|---|
| `ImagePullBackOff` | a bad tag or digest, or a registry outage | `helm rollback resume -n resume` |
| `CrashLoopBackOff` | the binary exits at start, for example on invalid resume content | `kubectl logs --previous`; roll back |
| Pods `Pending` | no node has room, or every node is cordoned | `kubectl describe pod`; `kubectl get nodes`; uncordon |
| Pods `Running` but not ready | readiness failing | `kubectl logs`; the app logs why it isn't ready |

## If the service is up but unscraped

- The ServiceMonitor still exists: `kubectl -n resume get servicemonitor`
- The NetworkPolicy still allows the monitoring namespace: `networkPolicy.monitoringNamespace` must match the namespace Prometheus runs in.
- Prometheus targets page: is the `resume` job listed, and what error does it show?
