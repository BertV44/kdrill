# kdrill

Automated restore testing for Veeam Kasten on OpenShift.

kdrill periodically restores exported (S3) restore points into disposable
`<namespace>-restored` namespaces on the same cluster, verifies that workloads
reach Ready, records the outcome, and tears the namespaces down. It answers one
question on a schedule: can we actually get this application back.

Author: Bertrand, EMEA Technical Account Manager, Veeam Software.
Reference lab cluster: `oc02.home`.

---

## Non-negotiable conventions

- **CLI**: OpenShift-first, but no longer OpenShift-only. The script resolves a
  CLI at runtime into `$CLI` and never hardcodes a binary: `oc` when OpenShift is
  detected and `oc` is present, `kubectl` otherwise. Both are overridable with
  `KDRILL_CLI`. In prose and examples, prefer `oc`, because OpenShift remains the
  primary target and the reference lab; mention `kubectl` where a vanilla
  Kubernetes reader would otherwise be stuck. Never reintroduce a bare `oc` call
  in `src/restore-test.sh`. Reversed 2026-08-26, previously `oc` exclusively.
- **Language**: all repository content in English.
- **Style**: no em dashes. No emojis in code, manifests or documentation.
- **Verification discipline**: never state a Veeam product behaviour, field name,
  metric, default value or figure from memory. Either verify it against
  `docs.kasten.io` for the matching version and cite it, or tag it explicitly.
  Use three tags consistently:
  - `[verified]` documented, with the doc version it was checked against
  - `[unverified]` plausible but not confirmed, must be validated on a cluster
  - `[roadmap]` announced but not shipped
- **Version pinning**: every technical statement names the version it applies to
  (Kasten 9.0.x, OpenShift 4.x, Kubernetes 1.x). Flag behaviour that differs
  between versions rather than glossing over it.
- **Corrections over rewrites**: when revising an existing file, produce targeted
  edits, not a wholesale regeneration, unless explicitly asked.

---

## Architecture decisions already taken

These were reasoned through and should not be re-litigated without a concrete new
constraint. If one is challenged, say why and ask before changing it.

1. **BatchRestoreAction, not per-namespace RestoreAction.** One object, one state
   to poll, native `targetNamespaceSuffix`. `[verified]` against docs 9.0.3.
2. **Target namespaces are pre-created by the tool**, not left to Kasten. This is
   what makes it possible to apply network isolation before the first pod starts,
   and to copy the SCC uid-range and supplemental-groups annotations plus the PSA
   enforce label from the source namespace.
3. **NetworkPolicy denies everything except intra-namespace traffic and DNS to
   `openshift-dns`.** The DNS exception is mandatory: without it, pods that
   resolve names at startup never reach Ready, which would invalidate the success
   criterion the whole tool is built on.
4. **OpenShift Routes are excluded from the restore.** Restoring a Route with an
   explicit `spec.host` into a second namespace on the same cluster collides with
   the original (`HostAlreadyClaimed`). Consequence to state honestly in docs: the
   ingress path is not covered by this test.
5. **Deterministic rotation, not random sampling.** Least-recently-tested first,
   weighted by a per-tier cadence. This yields a coverage guarantee ("every tier-1
   app tested within 7 days, here is the ledger") rather than a confidence
   interval. Auditors want the former.
6. **Coverage ledger is a ConfigMap in the tool namespace**, not annotations on
   the source namespaces. Production namespaces are never mutated.
7. **`backoffLimit: 0`.** A failed restore test is the signal the tool exists to
   produce. Automatic retries would mask it.
8. **`KEEP_ON_FAILURE=true` by default.** Namespaces are retained for post-mortem
   on failure, with a dump of non-Ready pods.
9. **Namespaces stuck in Terminating are reported, never force deleted.** Stripping
   finalizers can orphan operator-managed resources.
10. **Platform is detected at runtime, not configured.** `detect_platform` keys off
   the presence of the `security.openshift.io` API group, which every OpenShift
   cluster has. Exactly four things vary, each gated on `IS_OPENSHIFT`: the CLI
   binary, the SCC annotations copied to the target namespace, the DNS namespace
   the NetworkPolicy allows, and the Route exclusion in the BatchRestoreAction.
   `KDRILL_PLATFORM` forces the answer when detection is wrong. Adding a fifth
   divergence is a decision to take deliberately, not to slip in.
12. **The ingress path is excluded on both platforms**, by whichever resource owns
   it there: Routes on OpenShift, Ingress on vanilla Kubernetes. The reasons
   differ in severity. On OpenShift a duplicate `spec.host` is refused outright,
   so the worst case is a failed test. On Kubernetes a typical controller accepts
   two Ingresses claiming one host, so the worst case is production traffic
   reaching a restored copy. Note that OpenShift also materialises Routes from
   Ingress objects, so an OpenShift application that uses Ingress rather than
   Route is not covered by the Route filter alone. Decided 2026-08-26.
11. **The guardrail of record is a ValidatingAdmissionPolicy**, not Kyverno. It is
   native from Kubernetes 1.30, needs nothing installed, and behaves identically
   on both platforms. The Kyverno variant is kept for clusters already running it.
   `[verified]` end to end on OpenShift 4.20.30 / Kubernetes 1.33.13.

---

## Verified API facts

Checked against docs.kasten.io 9.0.3 and 9.0.4. Re-verify if the project targets a
different version.

- `BatchRestoreAction` can only be created in the Kasten install namespace.
- `targetNamespacePrefix` / `targetNamespaceSuffix` create the target namespace if
  it does not exist; this requires `create` on namespaces.
- Omitting `restorePointName` selects the latest restore point for the namespace
  and requires `list` on the RestorePoint API in that namespace.
- `skipWaitForWorkloadReady` defaults to `false`, so the action waits for
  Deployments, StatefulSets and DeploymentConfigs to be Ready before reporting
  Complete. This is the source of the "Pods Ready" success criterion.
- Subordinate RestoreActions carry the label
  `k10.kasten.io/batchRestoreActionName`.
- `RestorePoint.status` exposes `logicalSizeBytes`, `physicalSizeBytes`,
  `actionTime`, `scheduledTime`.
- RestorePoint labels observed on 9.0.4 are `k10.kasten.io/appName`,
  `k10.kasten.io/appNamespace`, `k10.kasten.io/appType`,
  `k10.kasten.io/policyName`, `k10.kasten.io/policyNamespace`,
  `k10.kasten.io/runActionName`, `k10.kasten.io/runActionNamespace`.
- **Exported restore points carry `k10.kasten.io/exportProfile=<profile name>`
  and `k10.kasten.io/exportType`.** Local restore points carry neither, even when
  the policy that produced them names an export profile in its own spec.
  `[verified]` on Kasten 9.0.4, OpenShift 4.20.30, 2026-08-26. This is the
  discriminator, and it supersedes the earlier statement that no such label
  existed. `exportType` was `appConfigOnly` for every exported restore point on
  the reference cluster, because those namespaces hold no PVCs. The value for a
  restore point exported with volume data is `[unverified]`.
- `.status.logicalSizeBytes` **can be absent**. It was empty on every
  namespace-scoped restore point on the reference cluster, so `rp_size_gib`
  returns 0 and the GiB budgets do not bite. Do not assume the budgets are
  protecting you without checking that the field is populated.
- `RestoreAction.spec.targetNamespace` is documented as being removed; the target
  is `metadata.namespace`.
- `ValidateAction` validates exported restore points in filesystem mode, with
  `verifyFilesPercent` and `failFast`. Metadata-only mode is
  `verifyFilesPercent: 0`.
- Action states: Pending, Running, AttemptFailed, Failed, Complete, Skipped,
  Deleting.
- API groups: `actions.kio.kasten.io/v1alpha1` for actions,
  `apps.kio.kasten.io/v1alpha1` for restore points.

---

## Known unverified items

These are the open risks. Do not silently resolve them by guessing.

1. **RESOLVED 2026-08-26. Exported vs local restore point discrimination.**
   Settled on the reference cluster. Exported restore points carry
   `k10.kasten.io/exportProfile`, so selection is now a server-side label
   selector, `EXPORT_LABEL=EXPORT_MATCH`. The previous grep over the
   `restorepoints/{name}/details` payload was **measured to produce false
   positives**: a local restore point from a backup-only policy matched, because
   its payload contains
   `$.status.restorePointDetails.artifacts[0].meta.kanister.meta.profileRef.name`
   set to the profile name. kdrill would have restored local snapshots while
   reporting that it had tested the export path. Do not go back to payload
   matching. `restorepoints/details` was removed from the RBAC as a result.
2. **Kasten concurrency limiter settings for 9.0.x.** `[unverified]` The Helm keys
   governing parallel volume restore operations were not confirmed. Verify before
   documenting any guidance on raising `MAX_NAMESPACES_PER_RUN`.
3. **`curl` availability in `registry.redhat.io/openshift4/ose-cli`.** `[unverified]`
   Only relevant when `PUSHGATEWAY_URL` is set.
4. **Cross-namespace image pull.** `[unverified]` Applications pulling from the
   internal OpenShift registry with a `<source-ns>/<image>` reference will hit
   ImagePullBackOff in the restored namespace, because its ServiceAccounts lack
   `system:image-puller` on the source namespace. This would fail the readiness
   criterion for reasons unrelated to the restore itself. Needs a lab reproduction
   and a documented decision on whether to automate the role binding.
5. **Operator-managed applications.** `[unverified]` CloudNativePG and similar
   operators reconcile restored CRs in the new namespace with behaviour that has
   not been observed. Validate with a simple stateless app first.
6. **StorageClass reclaim policy.** With `Retain`, every cycle leaves Released PVs
   behind. Deliberately not automated. Document it, do not silently clean up.
7. **RESOLVED 2026-08-26, with a caveat that became a real guard. Ledger key
   lookup.** Hyphenated keys resolve correctly in dotted jsonpath:
   `{.data.my-app-namespace}` returns the value, and an absent key returns empty
   as the never-tested path expects. `ledger_get` is sound and the rotation does
   not degenerate. The secondary concern is **confirmed real**: a key containing
   dots or a slash returns empty in dotted notation, verified with
   `{.metadata.labels.k10.kasten.io/tier}` returning nothing while the bracket
   form returned the value. Setting `TIER_LABEL` to such a key would silently
   send every namespace to `DEFAULT_CADENCE_DAYS`. `check_tier_label` now warns
   at startup. `[verified]` on OpenShift 4.20.30 / Kubernetes 1.33.13.
8. **The Kyverno guardrail variant.** `[unverified]` Its schema and pattern logic
   check out against the Kyverno CLI 1.18.1, but no Kyverno cluster was available,
   so DELETE-time behaviour and subject matching remain unconfirmed for it. The
   ValidatingAdmissionPolicy variant is verified end to end and is the one to
   deploy unless Kyverno is already running.
9. **The container image on vanilla Kubernetes.** `[unverified]`
   `registry.redhat.io/openshift4/ose-cli` will not pull without a Red Hat pull
   secret, which a vanilla cluster does not have. A replacement providing bash
   plus kubectl is needed and none has been tested. This is the main remaining gap
   in the agnostic claim: the script is portable, the shipped CronJob is not.
10. **RESOLVED 2026-08-26 by decision.** Ingress on vanilla Kubernetes is now
   excluded symmetrically with Routes. See architecture decision 12. The
   behaviour of a duplicate Ingress host on a specific controller remains
   `[unverified]`, but it no longer matters, because the object is filtered out
   before it can be created.
11. **PARTLY RESOLVED 2026-08-26. End-to-end restore.** A full cycle ran to
   success in-cluster, as a Job using the real ServiceAccount, image and mounted
   ConfigMap: 1 namespace eligible, the exported restore point selected, target
   namespace created with network isolation, BatchRestoreAction Pending then
   Complete at 100 percent, `PASS kdrill-demo`, ledger written, target namespace
   deleted through the guardrail, BatchRestoreAction cleaned up, source namespace
   untouched, `rc=0`. Total elapsed 79 seconds.
   **Still not proven: volume restore.** The test application was switched to
   `emptyDir` because the lab has no VolumeSnapshotClass carrying
   `k10.kasten.io/is-snapshot-class: "true"`, so `exportType` was
   `appConfigOnly` and no PersistentVolume was provisioned or attached. The
   headline claim in the scope statement, that volumes provision and attach from
   exported data, is therefore still `[unverified]`. Re-run with a PVC once a
   snapshot class is annotated.
12. **Volume backup prerequisite, discovered 2026-08-26.** `[verified]` Kasten
   cannot snapshot a PVC unless some VolumeSnapshotClass carries the annotation
   `k10.kasten.io/is-snapshot-class: "true"`. Without it a backup of a namespace
   holding a PVC fails in the CSI precheck phase with "Failed to find
   VolumeSnapshotClass with annotation in the cluster". The reference lab has a
   `lvms-vg1` VolumeSnapshotClass for driver `topolvm.io` but it is unannotated,
   which is why no volume backup had ever succeeded there. Annotating it also
   changes existing policies: `k10-disaster-recovery-policy` backs up `kasten-io`,
   which does hold PVCs, so it would begin snapshotting them. Not done, it is a
   cluster-wide decision.

---

## Working agreements

- `src/restore-test.sh` is the single source of truth. `deploy/30-script-configmap.yaml`
  is generated by `hack/build-configmap.sh` and must never be hand-edited.
- The script must pass `shellcheck` cleanly.
- **No heredocs inside the ConfigMap block scalar.** Bash will not match an
  indented `EOF` terminator, and the block scalar forces indentation. Embedded
  YAML is generated line by line with `echo`. This defect was already found and
  fixed once; do not reintroduce it.
- **No trailing `[ -n "$x" ] && echo` as the last command of a group piped to
  `oc`.** With `set -o pipefail`, a failing test in that position makes the whole
  pipeline fail, and `set -e` then kills the script. In `prepare_target_ns` this
  killed the run after the target namespace was created but before the
  NetworkPolicy was applied, leaking an unisolated namespace, whenever the source
  namespace carried an `openshift.io/sa.scc.uid-range` annotation but no
  `supplemental-groups`. Use `if` blocks, which exit 0 when the condition is
  false. Found and fixed 2026-08-25; do not reintroduce it.
- Validate manifests with `oc apply --dry-run=server` before proposing them.
- Always exercise `DRY_RUN=true` first. It resolves the eligible pool, priority
  order, selected restore points and their sizes without performing any restore.
- The RBAC grants `delete` on namespaces cluster-wide, because Kubernetes RBAC
  cannot restrict deletion by name pattern. The admission guardrail in
  `examples/` is the mitigation and should be prominent in the README, not buried.

---

## Scope statement

Keep this accurate in `docs/scope.md` and in the README. Overclaiming here is the
main reputational risk of the project.

**Proven by a passing run**: exported data in object storage is readable and
decryptable; volumes provision and attach from it; containers start and pass
readiness probes; the manifests in the restore point are internally consistent.

**Not proven**: data correctness or completeness; cross-application referential
integrity; the ingress path (Routes are excluded); cluster loss recovery, which
requires the separate Kasten disaster recovery procedure; anything about restore
points other than the one selected, unless `RP_SELECTION=random` is used to add
depth coverage over time.

---

## Metrics contract

Exposed via Pushgateway when `PUSHGATEWAY_URL` is set. Changing these names is a
breaking change for downstream PrometheusRules.

```
k10_restore_test_eligible_namespaces
k10_restore_test_selected_namespaces
k10_restore_test_succeeded_namespaces
k10_restore_test_failed_namespaces
k10_restore_test_untested_namespaces
k10_restore_test_max_staleness_days
k10_restore_test_last_run_timestamp
```

The alerting signal is staleness and untested count, not pass rate. A 100 percent
pass rate across zero selected namespaces is the silent failure mode this tool
must not have.
