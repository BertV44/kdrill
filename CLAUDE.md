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

- **CLI**: `oc` exclusively. Never `kubectl`, in code, docs, examples or commit
  messages. This is an OpenShift-first project.
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
- Standard RestorePoint labels are `k10.kasten.io/appName`,
  `k10.kasten.io/appNamespace`, `k10.kasten.io/appType`. There is no documented
  label distinguishing local from exported restore points.
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

1. **Exported vs local restore point discrimination.** `[unverified]` No documented
   label exposes this as of 9.0.4. Current approach greps `EXPORT_MATCH` (the S3
   location profile name) against the `restorepoints/{name}/details` subresource
   payload. This must be validated on a live cluster. If the artifacts structure
   supports a precise jsonpath selector, replace the grep. `hack/discover-export-artifacts.sh`
   exists to produce the evidence.
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
7. **Coverage ledger key lookup with hyphenated namespace names.** `[unverified]`
   `ledger_get` reads `-o "jsonpath={.data.$1}"` where `$1` is a namespace name,
   which normally contains hyphens. If the `oc` jsonpath parser does not resolve a
   hyphenated key in dotted notation, every lookup returns empty, every namespace
   looks never tested, and the rotation silently degenerates while
   `k10_restore_test_untested_namespaces` stays pinned at the pool size. Nothing
   in the logs looks wrong. The same trap applies to `TIER_LABEL` if it is ever
   set to a label containing dots or slashes, such as `k10.kasten.io/tier`, which
   would require bracket notation. Settle it with one `oc patch` and one `oc get`
   against the ledger ConfigMap on a live cluster.

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
