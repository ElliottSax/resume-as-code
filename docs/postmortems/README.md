# Postmortems

These are real incidents from systems I run, written blameless: the question is always "what about the system let this happen?", never "who messed up?". Each one changed how this repository is built, and the last section of each says how.

| Date | Incident | Impact | The lesson this repo encodes |
|---|---|---|---|
| 2026-08-24 | [The watchdog nobody watched](2026-08-24-watchdog-nobody-watched.md) | 7 h 45 m full outage | Supervise the supervisor; detection without action isn't supervision |
| 2026-08-27 | [Two days of success-shaped failure](2026-08-27-silent-auth-failure.md) | 87% of jobs failed, unnoticed | Measure from the user's side and alert on burn rate, not on "is it running" |
| 2026-11-09 | [A stale build served in production](2026-11-09-stale-build-served-in-production.md) | Old content live for 2 h 40 m | Serialize deploys, deploy immutable digests, verify what is actually serving |

## Template

```markdown
# <Title: what users experienced, not the root cause>

| | |
|---|---|
| **Date** | YYYY-MM-DD |
| **Duration** | how long users were affected |
| **Impact** | who noticed what, in numbers |
| **Detection** | how we found out, and how long that took |
| **Status** | action items open / closed |

## Summary
Three sentences: what broke, why, how it was fixed.

## Timeline
All times local. Include when it started, when it was detected, when it was mitigated.

## What happened
The mechanism, step by step, in plain language.

## Contributing factors
Plural, always. "Root cause" is usually several things that lined up.

## What went well / what went badly / where we got lucky

## Action items
| Action | Type (prevent / detect / mitigate) | Status |

## What this changed in resume-as-code
```
