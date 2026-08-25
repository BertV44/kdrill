# Sizing

How to choose the budgets and cadences so the rotation actually converges, and
what the run costs while it is happening.

Applies to: kdrill against Veeam Kasten 9.0.x on OpenShift 4.x.

Everything in the first section is arithmetic and holds regardless of product
behaviour. Everything that depends on measured throughput or on Kasten internals
is called out as such, and is not guessed.

## Does the rotation converge?

This is the first question, and the one most easily got wrong. A cadence target
is a promise. If the daily budget is too small, the promise is arithmetically
impossible no matter how well the tool works, and the coverage metrics will
degrade forever without anything looking broken.

With the shipped daily schedule, the tool tests at most
`MAX_NAMESPACES_PER_RUN` namespaces per day. For a tier with `N` namespaces and
a cadence of `C` days, sustaining that cadence consumes `N / C` namespace slots
per day. Across all tiers:

```
required MAX_NAMESPACES_PER_RUN  >=  sum over tiers of ( N_tier / C_tier )
```

Worked example, using the shipped cadence defaults of 7, 30 and 90 days:

| Tier | Namespaces | Cadence (days) | Slots per day |
|------|-----------:|---------------:|--------------:|
| 1    | 10         | 7              | 1.43          |
| 2    | 30         | 30             | 1.00          |
| 3    | 60         | 90             | 0.67          |
| **Total** | **100** |              | **3.10**      |

That estate needs `MAX_NAMESPACES_PER_RUN` of at least 4. The shipped default is
2, which is deliberately conservative: it is sized for a first deployment, not
for an estate of 100 namespaces. At 2 per day this example converges to a
steady state where the tier-3 namespaces starve, because the priority ordering
is by overdue days and tier 1 keeps arriving.

Check the result rather than trusting the arithmetic. If
`k10_restore_test_untested_namespaces` never reaches zero, or
`k10_restore_test_max_staleness_days` climbs run after run, the budget is too
small for the pool. Both alerts in `examples/prometheusrule.yaml` fire on
exactly this.

Note that a namespace is not skipped for being recently tested. The pool is
ordered by how overdue each namespace is and then truncated by the budget, so
with a small pool and a large budget the same namespaces are retested well
inside their cadence. That is harmless, only wasteful.

## Data budgets

Two independent caps, both in GiB:

- `MAX_NAMESPACE_GIB`, default 100. A single namespace larger than this is
  skipped with a warning and needs a dedicated run. It is never partially
  restored.
- `MAX_RESTORE_GIB`, default 200. Aggregate across one run. A namespace that
  would push the running total over the cap is deferred to a later run, and the
  walk continues, so a large namespace does not block smaller ones behind it.

Sizes come from `RestorePoint.status.logicalSizeBytes`. `[verified]`
docs.kasten.io 9.0.3.

Two consequences of how the size is computed, both worth knowing before you set
the caps:

- The conversion is integer division by 1 GiB, so **any namespace under 1 GiB is
  counted as 0 GiB**. A pool of many small namespaces consumes namespace slots
  but effectively no data budget. This is why `MAX_NAMESPACES_PER_RUN` exists as
  a separate cap and is the one that actually limits such an estate.
- `logicalSizeBytes` is the logical size, not what crosses the network or lands
  on disk. Do not use these caps to predict storage consumption or transfer
  time. Measure those.

## Time budget

The two timeouts must stay ordered, and the CronJob one must be the larger:

```
TIMEOUT_SECONDS      3600   script gives up waiting on the BatchRestoreAction
activeDeadlineSeconds 4200   Kubernetes kills the Job
```

The 600 second gap is headroom for cleanup, which includes waiting up to 300
seconds per namespace for termination. If you raise `TIMEOUT_SECONDS`, raise
`activeDeadlineSeconds` by at least as much, or the Job is killed mid-restore
and the cleanup never runs, leaving namespaces behind.

Whether 3600 seconds is enough for `MAX_RESTORE_GIB` of data depends entirely on
your object storage throughput, your CSI driver and your cluster's spare
capacity. No figure is offered here, because a made up throughput number is
worse than none. Measure it: run once with a representative namespace, read the
elapsed time out of the job log, and derive your own GiB per hour.

## Concurrency

`[unverified]` The Kasten settings that govern how many volume restore
operations proceed in parallel were **not confirmed** for 9.0.x. See CLAUDE.md
known unverified item 2.

This matters because `MAX_NAMESPACES_PER_RUN` and the Kasten concurrency limit
interact: raising the kdrill budget above what Kasten will run in parallel does
not speed anything up, it just queues subordinate actions inside the same
`TIMEOUT_SECONDS` window and makes timeouts more likely.

No tuning guidance is given here until those settings are verified against the
deployed version. Until then, raise `MAX_NAMESPACES_PER_RUN` one step at a time
and watch for timeouts rather than reasoning from a documented limit.

## Storage side effects

The restore creates real PersistentVolumeClaims, sized as in the source
namespace. During a run, the cluster carries the selected namespaces' volumes in
addition to production. Peak additional provisioned capacity is bounded by
`MAX_RESTORE_GIB`, subject to the integer-division caveat above.

`[unverified]` If the StorageClass reclaim policy is `Retain`, deleting the test
namespace leaves the PersistentVolume behind in `Released`. Every cycle then
accumulates orphaned PVs until someone reclaims them. kdrill does not clean these
up, deliberately: automatically deleting PVs from a tool that already holds
cluster-wide namespace delete is not a trade worth making. See CLAUDE.md
unverified item 6.

Check for the accumulation, on a schedule:

```bash
oc get pv --sort-by=.metadata.creationTimestamp \
  -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,CLAIM:.spec.claimRef.name,SC:.spec.storageClassName \
  | grep -i released
```

If that list grows, either reclaim them as part of an operational routine, or
point kdrill's restores at a StorageClass whose reclaim policy is `Delete`.

## Namespace name length

Target namespaces are `<source><TARGET_SUFFIX>`, and RFC 1123 caps a namespace
name at 63 characters. With the default `-restored` suffix, which is 9
characters, any source namespace longer than **54 characters** cannot be tested.
The script detects this, reports it as a failure for that namespace and skips
it, rather than letting the API reject the create. Shorten the suffix if this
bites, but note that changing `TARGET_SUFFIX` changes which namespaces are
excluded from the eligible pool, since the pool skips anything already ending in
the suffix.
