# kdrill

Automated restore testing for Veeam Kasten on OpenShift.

kdrill periodically restores exported (S3) restore points into disposable
`<namespace>-restored` namespaces on the same cluster, verifies that workloads
reach Ready, records the outcome in a coverage ledger, and tears the namespaces
down. It answers one question on a schedule: can we actually get this
application back.

Target: Veeam Kasten 9.0.x on OpenShift 4.x, or on vanilla Kubernetes 1.x.
OpenShift is the primary target and the reference lab. The platform is detected
at runtime, so the same script runs on both, and the OpenShift specifics are
switched off when they do not apply. See [Platform](#platform).

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
[examples/validatingadmissionpolicy-ns-delete-guardrail.yaml](examples/validatingadmissionpolicy-ns-delete-guardrail.yaml)
**before** you deploy the CronJob. It denies this ServiceAccount the deletion of
any namespace not labelled `k10.kasten.io/restore-test=true`.

```bash
oc apply -f examples/validatingadmissionpolicy-ns-delete-guardrail.yaml
```

That variant uses the `ValidatingAdmissionPolicy` built into Kubernetes 1.30 and
later, so there is nothing to install, and it behaves the same on OpenShift and
on vanilla Kubernetes. It is **verified end to end** on OpenShift 4.20.30 /
Kubernetes 1.33.13:

| Case | Result |
|---|---|
| Unlabelled namespace, deleted by the kdrill ServiceAccount | Denied, quoting the policy message |
| Namespace labelled `k10.kasten.io/restore-test=true`, same ServiceAccount | Deleted, so kdrill can still clean up |
| Any namespace, deleted by a cluster administrator | Unaffected, the `matchCondition` scopes the policy to that one ServiceAccount |

A [Kyverno variant](examples/kyverno-ns-delete-guardrail.yaml) is provided for
clusters already running Kyverno. It remains partially `[unverified]`: its schema
and pattern logic check out against the Kyverno CLI 1.18.1, but its DELETE-time
behaviour was never confirmed on a cluster. Both files carry the same three-step
test. Run it after applying, whichever you choose. A guardrail that silently does
not match is worse than no guardrail, because it produces false confidence.

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

Verified on a live cluster, OpenShift 4.20.30 / Kubernetes 1.33.13, Kasten 9.0.4:

- every manifest accepted by `oc apply --dry-run=server`
- the full selection path exercised end to end with `DRY_RUN=true`, on both the
  OpenShift and the forced-`kubectl` code paths
- the ServiceAccount permission matrix checked verb by verb, including negative
  controls confirming it cannot read secrets, delete pods, write outside its own
  namespace, or create a BatchRestoreAction outside the Kasten namespace
- the admission guardrail proven to deny and to allow the right things

- **a full restore cycle run to success in-cluster**, as a Job using the real
  ServiceAccount, image and mounted ConfigMap. 79 seconds end to end: exported
  restore point selected, target namespace created and isolated,
  BatchRestoreAction Complete at 100 percent, `PASS`, ledger written, target
  namespace deleted through the guardrail, source namespace untouched, `rc=0`

- **volume restore proven.** A later run restored a namespace holding a 1 GiB
  PVC. In the target namespace the PVC bound to a fresh PersistentVolume and the
  pod reached Running, then the namespace was torn down with no `Released` PV
  left behind

Separately, and going beyond what kdrill itself claims: a 32893 byte file written
to the volume and never touched by the workload came back with an **identical
sha256** after snapshot, export to Storj S3 and restore into a new namespace. The
data survives the round trip. That is not promoted into the scope statement, and
should not be: one file is not data correctness, and kdrill verifies nothing about
content.

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

## Platform

kdrill detects the platform at runtime and adapts. Nothing needs configuring for
the common cases.

| | OpenShift | Vanilla Kubernetes |
|---|---|---|
| CLI | `oc` | `kubectl` |
| SCC annotations copied to the target namespace | `uid-range`, `supplemental-groups` | none, there is no SCC admission plugin to satisfy |
| DNS namespace allowed by the NetworkPolicy | `openshift-dns` | `kube-system` |
| Route exclusion in the BatchRestoreAction | applied | omitted, the API group does not exist |
| PSA `enforce` label copied | yes | yes, Pod Security Admission is upstream |

Detection keys off the presence of the `security.openshift.io` API group, which
every OpenShift cluster has. Override any of it when detection is wrong or when
your cluster is unusual:

| Variable | Values | Default |
|---|---|---|
| `KDRILL_PLATFORM` | `auto`, `openshift`, `kubernetes` | `auto` |
| `KDRILL_CLI` | `oc`, `kubectl` | detected |
| `DNS_NAMESPACE` | any namespace | per platform, see table above |

`DNS_NAMESPACE` is the one worth checking on a non-default cluster. The
NetworkPolicy denies all egress except intra-namespace traffic and DNS, so if
CoreDNS does not live where kdrill expects, pods will not resolve names, will
never reach Ready, and every namespace will fail for a reason that has nothing
to do with the restore.

One caveat on portability, stated plainly: the **script** is platform agnostic,
the **shipped CronJob is not**. Its image is `registry.redhat.io/openshift4/ose-cli`,
which will not pull on a cluster without a Red Hat pull secret. On vanilla
Kubernetes, replace the image with one providing bash and kubectl, and set
`KDRILL_CLI=kubectl`. No specific image is recommended because none has been
tested. `[unverified]`

## Requirements

| Requirement | Detail |
|---|---|
| Veeam Kasten | 9.0.x, installed and healthy. Earlier and later minors are not verified. |
| Platform | OpenShift 4.x, or vanilla Kubernetes 1.x. Detected at runtime, see [Platform](#platform). On vanilla Kubernetes the CronJob image must be replaced. |
| Exported restore points | At least one S3 location profile, and export policies that have actually produced exported restore points. kdrill restores from the export, not from local snapshots. |
| Cluster privileges | `cluster-admin`, or enough to create a ClusterRole granting `delete` on namespaces, to apply `deploy/10-rbac.yaml`. |
| Admission control | `ValidatingAdmissionPolicy`, built in from Kubernetes 1.30, so normally nothing to install. Kyverno is an alternative if you already run it. Required for the guardrail above, not optional in practice. |
| Container image | `registry.redhat.io/openshift4/ose-cli`. The cluster needs a valid pull secret for `registry.redhat.io`, which OpenShift normally has as part of its global pull secret. |
| VolumeSnapshotClass | Required if your applications use PersistentVolumeClaims. Some VolumeSnapshotClass must carry the annotation `k10.kasten.io/is-snapshot-class: "true"`, or Kasten refuses to snapshot a PVC at all and the backup fails in the CSI precheck phase. Check with `oc get volumesnapshotclass -o yaml`. Note that annotating one also makes existing policies start snapshotting any PVCs in the namespaces they already back up. |
| Spare capacity | Enough headroom to provision the restored volumes alongside production. See [docs/sizing.md](docs/sizing.md). |
| Optional | Prometheus and a Pushgateway, if you want the metrics off-cluster. Without them, metrics are still written to the job log. |

## Install

Apply in order. The guardrail comes first, deliberately: it must be in place
before anything holds the delete permission.

```bash
oc apply -f examples/validatingadmissionpolicy-ns-delete-guardrail.yaml
oc apply -f deploy/00-namespace.yaml
oc apply -f deploy/10-rbac.yaml
oc apply -f deploy/20-ledger.yaml
oc apply -f deploy/30-script-configmap.yaml
oc apply -f deploy/40-cronjob.yaml
```

On vanilla Kubernetes the same order applies, with `kubectl`, and the CronJob
image must be replaced first. See [Platform](#platform).

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

Or skip labelling entirely for a first run. `SELECTION_MODE=all` consults no
label at all and makes every namespace holding a matching exported restore point
eligible:

```bash
oc -n k10-restore-test set env cronjob/k10-restore-test SELECTION_MODE=all
```

The three modes are `opt-in`, which requires `INCLUDE_LABEL` and is the default;
`opt-out`, eligible unless `EXCLUDE_LABEL` is present; and `all`, no label
consulted. Use `all` to see what kdrill would pick before committing to a
labelling scheme, then move to `opt-in` for steady state.

Tier drives the cadence target: 7, 30 and 90 days for tiers 1, 2 and 3, 30 days
for anything unlabelled. `TIER_LABEL` must be a flat key: a key containing dots
or a slash cannot be read by the dotted jsonpath lookup and every namespace would
silently fall back to the default cadence. The script warns at startup if you set
one. `[verified]` on OpenShift 4.20. Every knob is an environment variable in
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

## Teardown

Remove in reverse order. The CronJob first, so that no run can start midway
through the removal:

```bash
oc delete -f deploy/40-cronjob.yaml
oc delete -f deploy/30-script-configmap.yaml
oc delete -f deploy/10-rbac.yaml
oc delete -f deploy/00-namespace.yaml
```

Deliberately not in that list: `deploy/20-ledger.yaml`. Deleting the ledger
discards all coverage history, so every namespace looks untested on the next
install. Delete it only if that is what you want. Deleting the namespace in the
last step removes it anyway, so back it up first if the history matters:

```bash
oc -n k10-restore-test get configmap k10-restore-test-ledger -o yaml > ledger-backup.yaml
```

Two things the teardown does not clean up, both by design:

- Target namespaces left behind by a failed run, since `KEEP_ON_FAILURE=true`
  retains them for post-mortem. Find them with
  `oc get ns -l k10.kasten.io/restore-test=true`.
- `Released` PersistentVolumes, if the StorageClass reclaim policy is `Retain`.
  See [docs/sizing.md](docs/sizing.md).

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

`curl` is present at `/usr/bin/curl` in
`registry.redhat.io/openshift4/ose-cli`, so the Pushgateway push works.
`[verified]` by running the image on OpenShift 4.20.30. Push failures are logged
and non blocking in any case, so a missing `curl` would degrade to log-only
metrics rather than failing the run.

## Troubleshooting

The job log is the primary source. Start there:

```bash
oc -n k10-restore-test logs -l job-name --tail=200
```

| Symptom | First thing to check |
|---|---|
| `nothing selected, exiting` | The `--- selection ---` block names a reason per namespace. Most often no restore point matched `EXPORT_MATCH`, which is open item 1 below. |
| `eligible namespaces: 0` | In opt-in mode, no namespace carries `k10.kasten.io/restore-test=enabled`, or the namespaces that do hold no restore points. |
| `<ns>-restored already exists` | Leftover from an earlier failed run retained by `KEEP_ON_FAILURE`. Inspect it, then `oc delete ns <ns>-restored`. |
| Pods never reach Ready | Read the non-Ready pod dump at the end of the log. Expect `ImagePullBackOff` for applications pulling from another namespace's registry path, and startup failures for anything that needs egress the NetworkPolicy denies. Both are documented in [docs/scope.md](docs/scope.md) as failures that are not the restore's fault. |
| Namespace stuck `Terminating` | Reported, never force deleted, because stripping finalizers can orphan operator-managed resources. Inspect with `oc get ns <ns> -o jsonpath='{.spec.finalizers}'`. |
| Every namespace always looks untested | Suspect the ledger lookup. See open item 1's neighbour, unverified item 7 in CLAUDE.md, and check the ledger directly with `oc -n k10-restore-test get configmap k10-restore-test-ledger -o yaml`. |
| Timeout at `TIMEOUT_SECONDS` | The restore was still running. Either the data does not fit the window or Kasten is serialising the subordinate actions. See [docs/sizing.md](docs/sizing.md). |

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
examples/validatingadmissionpolicy-ns-delete-guardrail.yaml   the guardrail of record
examples/kyverno-ns-delete-guardrail.yaml                     alternative, if you run Kyverno
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

These are tracked in full in CLAUDE.md.

**Resolved on 2026-08-26**, recorded here because the first was a correctness bug
rather than a documentation gap:

- **Exported vs local restore point discrimination.** Exported restore points
  carry `k10.kasten.io/exportProfile`, so selection is now a server-side label
  selector. The previous approach grepped the profile name out of the
  `restorepoints/{name}/details` payload, and that was **measured to produce a
  false positive** on the reference cluster: a local restore point matched,
  because its payload carries
  `$.status.restorePointDetails.artifacts[0].meta.kanister.meta.profileRef.name`
  set to the profile name. kdrill would have restored local snapshots while
  reporting that it had tested the export path. Use
  `hack/discover-export-artifacts.sh` to confirm the same holds on your cluster
  before trusting the label.
- **The ledger's jsonpath lookup.** Hyphenated keys resolve correctly. Keys with
  dots or slashes do not, which is why `TIER_LABEL` is now checked at startup.

**Still open**, worth knowing before you interpret a failure:

1. **The GiB budgets do not work, and you should know why.** `[verified]` on
   Kasten 9.0.4: `.status.logicalSizeBytes` is populated on local restore points
   but **absent on exported ones**, which are exactly what kdrill selects. Every
   selection therefore sizes at 0 GiB and `MAX_RESTORE_GIB` and
   `MAX_NAMESPACE_GIB` constrain nothing. The script warns when this happens.
   Treat `MAX_NAMESPACES_PER_RUN` as the only cap that reliably bites. See
   [docs/sizing.md](docs/sizing.md).
2. **The CronJob image is not portable.** See [Platform](#platform).
3. **Cross-namespace image pull** and **operator-managed applications**, both
   `[unverified]`. These are the two most likely causes of a failure that is not
   the restore's fault. See [docs/scope.md](docs/scope.md).
4. **StorageClass reclaim policy.** `[unverified]` for `Retain`. On the reference
   cluster the class was `Delete` and no `Released` PV accumulated across runs.
   With `Retain`, expect one orphaned PV per volume per cycle. kdrill does not
   clean these up, deliberately.
5. **The Kyverno guardrail variant** remains untested, since no Kyverno cluster
   was available. Prefer the ValidatingAdmissionPolicy, which is verified.

## Licence

Apache-2.0. See [LICENSE](LICENSE).
