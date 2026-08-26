# Scope

What a kdrill run proves, and what it does not. Overclaiming here is the main
reputational risk of the project, so this page is deliberately blunt.

Applies to: kdrill against Veeam Kasten 9.0.x on OpenShift 4.x.

## The question kdrill answers

One question, on a schedule:

> Can we actually get this application back from its exported copy in object
> storage?

It answers it by doing the restore, into a disposable namespace on the same
cluster, and requiring the workloads to reach Ready.

## Proven by a passing run

A namespace that passes has demonstrated, at the moment of the run:

- The exported data in object storage is **readable and decryptable**. The
  restore read it back through the Kasten data path, so the location profile
  credentials, the bucket contents and the encryption keys all worked.
- Volumes **provision and attach** from that exported data. The StorageClass
  accepted the request, the PVs bound, and the volumes mounted.
- Containers **start and pass their readiness probes**. This is the strongest
  signal in the set, because `skipWaitForWorkloadReady` is `false`, so the
  BatchRestoreAction only reports Complete once Deployments, StatefulSets and
  DeploymentConfigs are Ready. `[verified]` docs.kasten.io 9.0.3.
- The manifests in the restore point are **internally consistent** enough to
  apply as a set into a fresh namespace.

That is a real recovery rehearsal, and it is more than most organisations can
evidence. It is not the same as a guarantee.

## Not proven

Be explicit about these, especially with auditors who may hear "restore test"
and infer more than is being claimed.

- **Data correctness or completeness.** kdrill checks that the application
  starts, not that its data is right. A database that boots with an empty or
  half-populated volume passes. Nothing reads a row and compares it to an
  expected value. For file-level verification of exported restore points,
  Kasten has a separate `ValidateAction` with `verifyFilesPercent`, which kdrill
  does not use. `[verified]` docs.kasten.io 9.0.3.
- **Cross-application referential integrity.** Each namespace is restored
  independently, from whatever restore point was selected for it. Two
  applications that share state are not restored to a consistent point in time
  relative to each other, and nothing checks that they could be.
- **The ingress path.** On OpenShift, Routes are excluded from the restore on
  purpose. Restoring a Route with an explicit `spec.host` into a second
  namespace on the same cluster collides with the original and fails with
  `HostAlreadyClaimed`. So the restored application is never reached through the
  router, and the ingress configuration is never exercised. If your recovery
  concern includes DNS and routing, this test does not cover it.

  On vanilla Kubernetes, `networking.k8s.io` Ingress objects are excluded
  instead, for a sharper reason. OpenShift refuses a duplicate `spec.host`
  outright, so the worst case there is a failed test. A typical ingress
  controller accepts two Ingresses claiming one host and resolves it by its own
  rules, so the worst case is production traffic reaching a restored copy. The
  filter removes that possibility rather than relying on the controller.

  One gap to know about: OpenShift also materialises Routes from Ingress
  objects, so an OpenShift application that uses Ingress rather than Route is
  not covered by the Route filter alone. Add `ingresses` to the OpenShift branch
  of `build_bra` if that is your case.
- **Cluster loss recovery.** kdrill restores onto a working cluster, using a
  working Kasten install, reading a working catalog. It says nothing about
  recovering when the cluster or Kasten itself is gone. That is the separate
  Kasten disaster recovery procedure, and it needs its own rehearsal.
- **Any restore point other than the one selected.** A pass covers exactly one
  restore point. With the default `RP_SELECTION=latest` that is always the most
  recent matching export, so older restore points are never touched. Setting
  `RP_SELECTION=random` trades determinism for depth coverage accumulated over
  many runs.
- **Namespaces outside the eligible pool.** In the default opt-in mode, a
  namespace with no `k10.kasten.io/restore-test=enabled` label is never
  considered. Absence of failures is not coverage. Read
  `k10_restore_test_eligible_namespaces` and
  `k10_restore_test_untested_namespaces` before drawing any estate-wide
  conclusion.

## Failure modes that are not the restore's fault

A namespace can fail for reasons that say nothing about backup quality. Read a
failure before believing it.

- **Cross-namespace image pull.** `[unverified]` An application pulling from the
  internal registry with a `<source-ns>/<image>` reference is expected to hit
  `ImagePullBackOff` in the restored namespace, because the restored
  ServiceAccounts have no `system:image-puller` on the source namespace. This
  fails the readiness criterion for a reason unrelated to the restore. Needs a
  lab reproduction, see CLAUDE.md unverified item 4.
- **Operator-managed applications.** `[unverified]` Operators such as
  CloudNativePG reconcile restored CRs in the new namespace with behaviour that
  has not been observed. Validate with a simple stateless application first.
- **Network isolation.** The target namespace denies all traffic except
  intra-namespace and DNS to `openshift-dns`. An application that needs to reach
  an external dependency at startup will not become Ready. That is a
  deliberate trade: isolation prevents a restored copy from writing to
  production endpoints, and it is worth more than the coverage it costs.

## Consequences to state out loud

- A green kdrill dashboard means "the applications we selected started from
  their exports". It does not mean "we can recover the platform".
- The staleness and untested metrics matter more than the pass rate. A perfect
  pass rate over zero selected namespaces is the failure mode this tool is
  built to make visible, not to hide. See `examples/prometheusrule.yaml`.
- Storage side effects are not cleaned up. With a StorageClass whose reclaim
  policy is `Retain`, every cycle leaves Released PVs behind. kdrill does not
  touch them, deliberately. See `docs/sizing.md`.
