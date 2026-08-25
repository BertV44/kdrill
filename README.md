# kdrill

Automated restore testing for Veeam Kasten on OpenShift.

kdrill periodically restores exported (S3) restore points into disposable
`<namespace>-restored` namespaces on the same cluster, verifies that workloads
reach Ready, records the outcome in a coverage ledger, and tears the namespaces
down. It answers one question on a schedule: can we actually get this
application back.

Target: Veeam Kasten 9.0.x on OpenShift 4.x.

---

## Scope: what a passing run proves

A namespace that passes has demonstrated, at the moment of the run:

- The exported data in object storage is **readable and decryptable**.
- Volumes **provision and attach** from that exported data.
- Containers **start and pass their readiness probes**. The
  BatchRestoreAction only reports Complete once Deployments, StatefulSets and
  DeploymentConfigs are Ready, because `skipWaitForWorkloadReady` is `false`.
  `[verified]` docs.kasten.io 9.0.3.
- The manifests in the restore point are **internally consistent** enough to
  apply as a set into a fresh namespace.

## Scope: what it does not prove

Read this before repeating a kdrill result to an auditor.

- **Not data correctness or completeness.** kdrill checks that the application
  starts, not that its data is right. A database that boots with an empty volume
  passes. Nothing reads a row and compares it to an expected value.
- **Not cross-application referential integrity.** Namespaces are restored
  independently, not to a mutually consistent point in time.
- **Not the ingress path.** OpenShift Routes are excluded on purpose, because
  restoring a Route with an explicit `spec.host` into a second namespace on the
  same cluster collides with the original (`HostAlreadyClaimed`). The router is
  never exercised.
- **Not cluster loss recovery.** kdrill needs a working cluster, a working
  Kasten install and a readable catalog. Recovering without those is the
  separate Kasten disaster recovery procedure.
- **Not any restore point other than the one selected.** With the default
  `RP_SELECTION=latest`, older restore points are never touched.
- **Not the namespaces outside the eligible pool.** Absence of failures is not
  coverage. A green board over zero selected namespaces is the failure mode this
  tool is built to expose.

Full detail, including failure modes that are not the restore's fault, in
[docs/scope.md](docs/scope.md).

---

## Read this before you deploy: it holds cluster-wide namespace delete

kdrill's ServiceAccount is granted `delete` on **namespaces, cluster-wide**.

This is not a design preference and it cannot be narrowed. Kubernetes RBAC
authorises verbs on resource types and has no way to restrict deletion to names
matching a pattern such as `*-restored`. There is no smaller RBAC grant that
still lets the tool clean up the namespaces it creates. So a CronJob on your
cluster holds a permission that, on its own, can delete any namespace.

**The mitigation is admission control, and it is not optional.** Deploy
[examples/kyverno-ns-delete-guardrail.yaml](examples/kyverno-ns-delete-guardrail.yaml),
or an equivalent `ValidatingAdmissionPolicy`, **before** you deploy the CronJob.
It denies this ServiceAccount the deletion of any namespace not labelled
`k10.kasten.io/restore-test=true`.

The guardrail's schema and pattern logic are verified against the Kyverno CLI
1.18.1. Whether Kyverno applies a `validate.pattern` to the existing object on a
DELETE admission request is **`[unverified]`** and is the load bearing assumption
of the entire policy. The file contains a two-step test, a negative case and a
positive case, to settle it on a lab cluster. Run it. A guardrail that silently
does not match is worse than no guardrail, because it produces false confidence.

### One label key, three meanings. Do not mistype it.

The key `k10.kasten.io/restore-test` is overloaded:

| Value | Meaning | Applied to |
|---|---|---|
| `enabled` | this namespace opts in to being tested | source namespace, production |
| `excluded` | this namespace opts out, in opt-out mode | source namespace, production |
| `true` | this is a disposable kdrill target, safe to delete | namespaces kdrill creates |

The guardrail keys on `=true`. Labelling a **production** namespace
`k10.kasten.io/restore-test=true`, which is the natural mistake when reaching for
a boolean opt-in, moves that namespace inside the deletable set and the guardrail
will permit its deletion. The opt-in value is `enabled`, not `true`.

---

## Status

The script has been extracted, is `shellcheck` clean, and its manifests are
structurally validated and cross-checked. **It has not yet completed a run on a
cluster.** Treat the first deployment as a lab exercise, not a production
rollout, and work through the open items below.

Manifests have not been validated with `oc apply --dry-run=server`, which the
project convention requires, because no cluster was reachable when they were
written. Do that first:

```bash
oc apply --dry-run=server -f deploy/
```

---

## How it works

1. **Eligibility.** Namespaces holding at least one restore point, minus system
   namespaces, minus anything already ending in `TARGET_SUFFIX`, filtered by the
   opt-in label (or the opt-out label in `opt-out` mode).
2. **Priority.** Ordered by how overdue each namespace is against its tier
   cadence, least recently tested first. Deterministic and reproducible, so the
   selection can be audited rather than explained as a sample.
3. **Selection.** The walk admits namespaces until a budget is reached:
   `MAX_NAMESPACES_PER_RUN`, `MAX_RESTORE_GIB` aggregate, `MAX_NAMESPACE_GIB`
   per namespace.
4. **Preparation.** kdrill creates each target namespace itself, copying the SCC
   `uid-range` and `supplemental-groups` annotations and the PSA `enforce` label
   from the source, then applies a NetworkPolicy that denies everything except
   intra-namespace traffic and DNS to `openshift-dns`. Doing this before the
   restore is why isolation is in place before the first pod starts.
5. **Restore.** One `BatchRestoreAction` in the Kasten namespace, with
   `targetNamespaceSuffix`, Routes excluded. One object to poll, one state.
6. **Outcome.** Per-namespace state read from the subordinate RestoreActions via
   the `k10.kasten.io/batchRestoreActionName` label. The coverage ledger is
   updated **on success only**.
7. **Cleanup.** Namespaces deleted. Namespaces stuck in `Terminating` are
   reported, never force deleted, because stripping finalizers can orphan
   operator-managed resources. On failure, `KEEP_ON_FAILURE=true` retains them
   and dumps the pods that never became Ready.

## Install

Apply in order. Read the RBAC section above first, and deploy the guardrail
before the CronJob.

```bash
oc apply -f deploy/00-namespace.yaml
oc apply -f deploy/10-rbac.yaml
oc apply -f deploy/20-ledger.yaml
oc apply -f deploy/30-script-configmap.yaml
oc apply -f deploy/40-cronjob.yaml
```

`deploy/20-ledger.yaml` is install-time only. Re-applying it over a populated
ledger has not been verified to preserve existing keys, so do not put it in a
routine redeploy path.

## Configure

Set `EXPORT_MATCH` in `deploy/40-cronjob.yaml` to the name of your S3 location
profile. The CronJob will not do anything useful until you do: the script treats
it as required.

```bash
oc get profiles.config.kio.kasten.io -A
```

Then label the source namespaces you want tested:

```bash
oc label namespace my-app k10.kasten.io/restore-test=enabled
oc label namespace my-app backup-tier=1
```

Tier drives the cadence target: 7, 30 and 90 days for tiers 1, 2 and 3, 30 days
for anything unlabelled. Every knob is an environment variable in
`deploy/40-cronjob.yaml`, and each one's default is in the script's
configuration block. The script itself is never edited to change behaviour.

Before you raise `MAX_NAMESPACES_PER_RUN`, check the rotation actually
converges. The arithmetic is in [docs/sizing.md](docs/sizing.md), and it is easy
to promise a cadence that the budget makes impossible.

## First run

Always dry run first. It resolves the eligible pool, the priority order, the
selected restore points and their sizes, and performs no restore.

A Job's pod template is immutable once created, so `DRY_RUN` has to be set on
the CronJob before the one-off Job is spawned from it:

```bash
oc -n k10-restore-test set env cronjob/k10-restore-test DRY_RUN=true
oc -n k10-restore-test create job --from=cronjob/k10-restore-test kdrill-dryrun
oc -n k10-restore-test logs -f job/kdrill-dryrun
```

Then put it back, so the next scheduled run is a real one:

```bash
oc -n k10-restore-test set env cronjob/k10-restore-test DRY_RUN=false
```

Setting `DRY_RUN=true` in `deploy/40-cronjob.yaml` and re-applying works equally
well, and leaves the intent in git rather than only in the live object.

Read the `--- selection ---` block in the log. If it selected nothing, the
reason is printed per namespace.

## Metrics

Pushed to a Pushgateway when `PUSHGATEWAY_URL` is set, and always written to the
job log. The names are a contract; changing them breaks downstream rules.

```
k10_restore_test_eligible_namespaces
k10_restore_test_selected_namespaces
k10_restore_test_succeeded_namespaces
k10_restore_test_failed_namespaces
k10_restore_test_untested_namespaces
k10_restore_test_max_staleness_days
k10_restore_test_last_run_timestamp
```

**Alert on staleness and untested count, not on pass rate.** A 100 percent pass
rate across zero selected namespaces is the silent failure mode this tool must
not have, and a ratio cannot see it.
[examples/prometheusrule.yaml](examples/prometheusrule.yaml) implements this,
including the two alerts for "ran, tested nothing, exited zero".

Note that `k10_restore_test_max_staleness_days` excludes namespaces that have
never been tested; those are counted in
`k10_restore_test_untested_namespaces`. Staleness can therefore look healthy
while namespaces have never been tested once, which is why both are alerted on
separately.

`[unverified]` `curl` availability in `registry.redhat.io/openshift4/ose-cli`,
which the Pushgateway push depends on. Push failures are logged and non
blocking, so an absent `curl` degrades to log-only metrics rather than a failed
run.

## Repository layout

```
src/restore-test.sh                     single source of truth
deploy/00-namespace.yaml
deploy/10-rbac.yaml                     all permissions, in one auditable file
deploy/20-ledger.yaml                   coverage ledger ConfigMap
deploy/30-script-configmap.yaml         GENERATED, never hand-edited
deploy/40-cronjob.yaml                  schedule and all configuration
hack/build-configmap.sh                 regenerates deploy/30 from src/
hack/discover-export-artifacts.sh       evidence for open item 1 below
examples/prometheusrule.yaml
examples/kyverno-ns-delete-guardrail.yaml
docs/scope.md                           the long form of the scope statement
docs/sizing.md                          budgets, cadence convergence, storage
```

`deploy/30-script-configmap.yaml` is generated from `src/restore-test.sh`. Edit
the script, then:

```bash
hack/build-configmap.sh
```

The generation is deterministic, so a rebuild with no source change produces no
git diff. To assert that in CI or a pre-commit hook:

```bash
hack/build-configmap.sh --check
```

## Open items

These are tracked in full in CLAUDE.md. The two that block a first production
deployment:

1. **Exported vs local restore point discrimination.** `[unverified]` No
   documented label distinguishes them as of 9.0.4. The script greps
   `EXPORT_MATCH` against the `restorepoints/{name}/details` payload, which is a
   substring match over a whole JSON document. If the profile name also appears
   in a local restore point's payload, kdrill will restore local restore points
   and silently stop testing the export path, while still reporting passes. Get
   the evidence:

   ```bash
   hack/discover-export-artifacts.sh --list
   hack/discover-export-artifacts.sh --local <ns>/<rp> --exported <ns>/<rp>
   ```

   It dumps the artifacts section for both side by side, reports every JSON path
   where the profile name appears, and states whether the grep discriminates. If
   it does, replace the grep with a jsonpath selector against the narrowest
   stable path.

2. **The admission guardrail's DELETE behaviour.** `[unverified]` See the RBAC
   section above and the test procedure in the policy file.

Also open, and worth knowing before you interpret a failure: cross-namespace
image pull, operator-managed applications, StorageClass reclaim policy, and the
Kasten concurrency limiter settings. See CLAUDE.md and
[docs/scope.md](docs/scope.md).

## Licence

Apache-2.0. See [LICENSE](LICENSE).
