# Runbook: fewer than two replicas ready

**Alert:** `ResumeReplicasDegraded` (ticket)

## What it means

The service is up, but one more failure takes it down. With `minReplicas: 3` and `maxUnavailable: 1`, normal rollouts and node drains never hold the service below two ready replicas for five minutes. So something is wrong, even though users aren't affected yet.

## Check

```sh
kubectl -n resume get pods -o wide
kubectl -n resume get pdb resume            # ALLOWED DISRUPTIONS should be 1 when healthy
kubectl -n resume get hpa resume
kubectl get nodes                            # cordoned (SchedulingDisabled) nodes left behind?
```

| You see | Likely cause | Do |
|---|---|---|
| A node `SchedulingDisabled` | a drain that never got uncordoned | `kubectl uncordon <node>` |
| Pods `Pending` with `Insufficient cpu/memory` | the cluster is full | add a node or lower requests |
| Pods restarting | crash loop or OOM | see [all-replicas-down.md](all-replicas-down.md) |
| HPA `minReplicas` lowered | a config change | revert it; 3 is the minimum that survives a node drain plus one crash |
