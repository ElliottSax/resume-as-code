# A stale build served in production

| | |
|---|---|
| **Date** | 2026-11-09 |
| **Duration** | About 2 h 40 m |
| **Impact** | A content site I run on Vercel served the 04:14 build instead of the 05:27 one. A batch of corrections that had "deployed successfully" was not actually live. |
| **Detection** | Manual, by checking the live page for a phrase that should have been there. |
| **Status** | Mitigated. The delayed-build trigger was never identified. |

## Summary

I pushed four commits within seven minutes, and one of them never built at the time. Over an hour later, a new push triggered **two** production builds: one for the new commit, and one for the old commit that had been skipped. The old one finished nine seconds later, and the hosting platform gives the production domain to *whichever build finishes last*. Production rolled back on its own, while GitHub showed a green check for the newest commit.

## Timeline

| Time | Event |
|---|---|
| around 04:14 | A burst of four pushes within seven minutes. The build for the 04:14 commit doesn't run. |
| 04:51 | Same pattern on another commit (built 33 minutes late). A later push happened to heal it. |
| 05:27:31 | New commit pushed. |
| 05:27:36 | Production build starts for the new commit. |
| 05:27:45 | A production build starts for the **04:14** commit. |
| shortly after | The old build finishes last and takes the production domain. The site now serves 04:14 content. |
| ~08:05 | Noticed: a phrase from the new content is missing on the live site. The deployment built from the newest commit is promoted to production by hand. |

## What happened

The platform assigns the production domain to the most recently *finished* production build. It does not use the most recent commit. Normally those match. When a build is delayed, they don't, and an old build can quietly overwrite a new one.

## Contributing factors

- **Concurrent deploys with no ordering.** Several pushes produced builds that raced each other.
- **"Success" meant "a build passed", not "the right build is live".** The commit status, the build log and the uptime check were all green.
- **Checks ran too early.** Verifying the live page right after a deploy finished passed. The stale build replaced it minutes later.

## What went well / badly / lucky

- **Well:** rolling back to the right build took seconds, because the platform keeps every build as an immutable deployment that can be promoted.
- **Badly:** the delayed build's trigger was never found.
- **Lucky:** the stale content was older, not wrong in a harmful way.

## Action items

| Action | Type | Status |
|---|---|---|
| After the last push of a batch, list recent deployments and confirm which commit production was built from | detect | done (documented check) |
| Re-check a marker phrase on the live site 10+ minutes after the last successful build, not only right after | detect | done |
| Batch commits into one push instead of several within minutes | prevent | done |
| Find what triggered the delayed builds | prevent | **open**: no webhook or local deployer found |

## What this changed in resume-as-code

- **Deploys are serialized.** [`delivery.yml`](../../.github/workflows/delivery.yml) uses a concurrency group with `cancel-in-progress: false`. Two deliveries never run at once, a newer one waits its turn, and the last thing deployed is always the newest commit.
- **Artifacts are immutable.** Releases are identified by image **digest**, not tag. The drill deploys the exact digest that was scanned and signed, and verifies the signature first.
- **You can ask production what it is running.** `GET /version` and the `resume_build_info` metric report the exact commit each pod was built from. "The pipeline is green" is a claim; `/version` is evidence.
