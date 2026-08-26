# How to run kdrill

A task-oriented walkthrough, from an empty cluster to a coverage report you can
hand to an auditor. Every command here was run against OpenShift 4.20.30 with
Kasten 9.0.4 unless it is marked otherwise.

On vanilla Kubernetes, substitute `kubectl` for `oc` throughout. kdrill detects
the platform itself, so nothing else changes. See the Platform section of the
README.

Read [scope.md](scope.md) first if you have not. It defines what a passing run
does and does not prove, and this guide assumes you already know the difference.

---

## Step 1: check the cluster can actually do this

Four things have to be true before kdrill can work. Check them, do not assume
them: a missing one produces a failure that looks like a backup problem but is
not.

**Kasten is installed and you know its namespace.**

```bash
oc get ns kasten-io
oc -n kasten-io get deployment gateway -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}{"\n"}'
```

**You have at least one S3 location profile, and you know its exact name.** That
name is the value of `EXPORT_MATCH`.

```bash
oc get profiles.config.kio.kasten.io -A
```

**Exported restore points actually exist.** kdrill restores from the export, not
from local snapshots. This is the check people skip:

```bash
oc get restorepoints.apps.kio.kasten.io -A -L k10.kasten.io/exportProfile
```

Rows with an empty `EXPORTPROFILE` column are local only and kdrill will ignore
them. If every row is empty, your policies are backing up but not exporting, and
there is nothing for kdrill to test yet.

**If your applications use PersistentVolumeClaims, a VolumeSnapshotClass carries
the Kasten annotation.** Without it Kasten refuses to snapshot a PVC at all and
the backup fails in the CSI precheck phase.

```bash
oc get volumesnapshotclass -o custom-columns=NAME:.metadata.name,DRIVER:.driver,K10:.metadata.annotations.k10\\.kasten\\.io/is-snapshot-class
```

If the `K10` column is empty, annotate one:

```bash
oc annotate volumesnapshotclass <name> k10.kasten.io/is-snapshot-class=true --overwrite
```

Be aware of the side effect: any existing policy that already backs up a
namespace holding PVCs will start snapshotting those volumes from its next run.

---

## Step 2: deploy the guardrail first

kdrill's ServiceAccount needs `delete` on namespaces cluster-wide, and Kubernetes
RBAC cannot narrow that by name. The admission guardrail is the mitigation and it
goes in **before** anything holds the permission.

```bash
oc apply -f examples/validatingadmissionpolicy-ns-delete-guardrail.yaml
```

Then prove it works. The negative case is the one that matters.

```bash
oc create namespace kdrill-guardrail-probe
oc --as=system:serviceaccount:k10-restore-test:k10-restore-test delete namespace kdrill-guardrail-probe
```

Expect a refusal quoting the policy message. If the deletion succeeds, stop: the
ServiceAccount can delete any namespace on the cluster. Then confirm the positive
case, because kdrill must still be able to clean up after itself:

```bash
oc label namespace kdrill-guardrail-probe k10.kasten.io/restore-test=true
oc --as=system:serviceaccount:k10-restore-test:k10-restore-test delete namespace kdrill-guardrail-probe
```

Expect a deletion.

---

## Step 3: pick a path

Three ways to run kdrill. They share the same script and the same behaviour; they
differ in what lives on the cluster and who owns the schedule.

| | Path A, CronJob | Path B, on-demand Job | Path C, standalone |
|---|---|---|---|
| Schedule owned by | Kubernetes | your orchestrator | your machine, cron, CI |
| Objects on the cluster | namespace, RBAC, 2 ConfigMaps, CronJob | same minus CronJob | none, only RBAC if you want a dedicated identity |
| Coverage ledger | ConfigMap | ConfigMap | a file you control |
| Runs as | ServiceAccount | ServiceAccount | your kubeconfig |
| Best when | you want it to just happen | change control gates each run | you want no cluster footprint |

### Path A: scheduled in-cluster

```bash
oc apply -f deploy/00-namespace.yaml
oc apply -f deploy/10-rbac.yaml
oc apply -f deploy/20-ledger.yaml
oc apply -f deploy/30-script-configmap.yaml
oc apply -f deploy/40-cronjob.yaml
```

Set the profile name before the first scheduled run:

```bash
oc -n k10-restore-test set env cronjob/k10-restore-test EXPORT_MATCH=YOUR_PROFILE_NAME
```

### Path B: on-demand in-cluster

Apply `deploy/00` through `deploy/30` as above, then skip `deploy/40` and use the
Job instead. It carries `generateName`, so `oc create`, never `oc apply`.

```bash
oc create -f examples/job-on-demand.yaml
```

Read the four consequences in the README section "Running without a CronJob"
before you rely on this, especially the one about `KdrillRunStale`.

### Path C: standalone, no Kubernetes objects

For clients who want kdrill without adopting anything Kubernetes-shaped: no
CronJob, no Job, no ConfigMap. One bash script, a kubeconfig, and whatever
already schedules things in your estate.

Requirements on the machine that runs it:

- `bash` 4 or later
- `oc` or `kubectl` on `PATH`
- a kubeconfig with the rights kdrill needs, `KUBECONFIG` or `~/.kube/config`
- `date`, either GNU or BSD. The script detects which and refuses to run with
  neither, because guessing wrong makes every namespace look never tested

Nothing else. Copy `src/restore-test.sh` wherever you like.

```bash
export KUBECONFIG=/path/to/kubeconfig
export EXPORT_MATCH=YOUR_PROFILE_NAME
export LEDGER_BACKEND=file
export LEDGER_FILE=/var/lib/kdrill/ledger
./restore-test.sh
```

The ledger file **is** the coverage record in this mode, and no Kubernetes object
holds it. Put it somewhere backed up, or in a git repository if you want the
history reviewable. It is TAB separated, one namespace per line, sorted, so it
diffs cleanly.

You still need the RBAC from `deploy/10-rbac.yaml` if you want kdrill to run as a
dedicated identity rather than as whoever owns the kubeconfig. Running it as a
cluster administrator works and needs no RBAC at all, but then the guardrail does
not apply to you either, since it is scoped to that one ServiceAccount.

Schedule it however you already schedule things. With cron, on a Sunday at 03:00:

```bash
0 3 * * 0 KUBECONFIG=/etc/kdrill/kubeconfig EXPORT_MATCH=my-profile LEDGER_BACKEND=file LEDGER_FILE=/var/lib/kdrill/ledger /opt/kdrill/restore-test.sh >> /var/log/kdrill.log 2>&1
```

Same for a systemd timer, a Jenkins job, a GitLab schedule, an Ansible playbook
or a Tekton pipeline. kdrill does not care, and exits non-zero on failure so any
of them can act on it.

---

## Step 4: the first run is always a dry run

`DRY_RUN=true` resolves the eligible pool, the priority order, the selected
restore points and their sizes, and performs no restore. Do this before any real
run, on every path.

Path A or B, in-cluster:

```bash
oc -n k10-restore-test set env cronjob/k10-restore-test DRY_RUN=true SELECTION_MODE=all
oc -n k10-restore-test create job --from=cronjob/k10-restore-test kdrill-dryrun
oc -n k10-restore-test logs -f job/kdrill-dryrun
```

Path C, standalone:

```bash
DRY_RUN=true SELECTION_MODE=all EXPORT_MATCH=YOUR_PROFILE_NAME ./restore-test.sh
```

`SELECTION_MODE=all` consults no label, which is what lets you see the whole
picture before committing to a labelling scheme.

### Reading the output

```
platform: OpenShift, cli: oc, dns namespace: openshift-dns
selection mode: all, restore point selection: latest
export label: k10.kasten.io/exportProfile=storj
ledger: configmap k10-restore-test/k10-restore-test-ledger
date: gnu
budgets: 2 namespaces, 200 GiB total, 100 GiB per namespace
eligible namespaces: 1
--- selection ---
selected  kdrill-demo  rp=scheduled-chsl44w9r8  size=0GiB  running_total=0GiB
--- 1 namespace(s) selected, 0 GiB total ---
```

Three lines to actually check:

- **`eligible namespaces: 0`** means nothing is in scope. That is not a pass, it
  is an empty pool. In opt-in mode the label is missing everywhere.
- **A `skipped, no exported restore point matching` warning** means that
  namespace has no export for your profile. Correct behaviour, but check the
  profile name is right before concluding.
- **`size=0GiB`** is expected, not a bug. Kasten 9.0.4 does not populate
  `logicalSizeBytes` on exported restore points, so the GiB budgets cannot
  constrain the run and the script says so. Cap the work with
  `MAX_NAMESPACES_PER_RUN`.

---

## Step 5: the first real run

Turn the dry run off and go. Start with `MAX_NAMESPACES_PER_RUN=1` on a namespace
you do not mind restoring.

```bash
oc -n k10-restore-test set env cronjob/k10-restore-test DRY_RUN=false MAX_NAMESPACES_PER_RUN=1
oc -n k10-restore-test create job --from=cronjob/k10-restore-test kdrill-first
oc -n k10-restore-test logs -f job/kdrill-first
```

A successful run looks like this, and takes a couple of minutes for a small
application:

```
target namespace kdrill-demo-restored ready, network isolation applied
BatchRestoreAction created: restoretest-q6w5b
state=Pending (%)
state=Running (8%)
state=Complete (100%)
--- subordinate actions ---
PASS  kdrill-demo
--- cleanup ---
deleting namespace kdrill-demo-restored
=== finished (rc=0) ===
```

On failure, `KEEP_ON_FAILURE=true` leaves the target namespace in place with a
dump of the pods that never became Ready. Investigate before deleting it. The
Troubleshooting table in the README maps symptoms to first checks.

---

## Step 6: turn coverage into a report

The run log proves one run. The report proves coverage, which is what anyone
auditing you will ask for.

```bash
src/kdrill-report.sh
```

```
NAMESPACE       TIER   CADENCE  LAST_PASSED            AGE    STATUS        EXPORT_RP
kdrill-demo     none   30d      2026-08-26T11:04:18Z   0      OK            yes

in scope 1   within cadence 1   overdue 0   never tested 0   worst age 0d
compliance 100% of namespaces in scope are within their cadence
```

It reads the ledger and writes nothing, so it is safe to run any time, and it
works against either ledger backend. Formats for different audiences:

```bash
src/kdrill-report.sh --format csv > coverage.csv
src/kdrill-report.sh --format markdown > coverage.md
```

It exits 1 if anything is overdue or never tested, so it doubles as a gate:

```bash
src/kdrill-report.sh --quiet || echo "coverage is not compliant"
```

Note what the report does **not** claim. A row marked `OK` means the application
restored from its export and became Ready within its cadence. It does not mean
the data was checked. Say that out loud when you hand the report over; see
[scope.md](scope.md).

---

## Routine operations

**Bring a namespace into scope** (opt-in mode, the default):

```bash
oc label namespace my-app k10.kasten.io/restore-test=enabled
oc label namespace my-app backup-tier=1
```

Tier drives the cadence: 7, 30 and 90 days for tiers 1, 2 and 3, and 30 days for
anything unlabelled. Use a flat label key. A key containing dots or a slash
cannot be read by the dotted jsonpath lookup, and every namespace would silently
fall back to the default cadence. The script warns if you set one.

**Take a namespace out of scope**: remove the label. Its ledger entry stays, so
history is not lost if you bring it back.

**Change a cadence**: set `TIER1_CADENCE_DAYS` and friends. Then check the
rotation still converges, because a cadence is a promise about elapsed time and
a daily budget that is too small makes it arithmetically impossible. The
arithmetic is in [sizing.md](sizing.md).

**Prove the export discriminator on your own cluster**, which is worth doing once
before you trust any of this:

```bash
hack/discover-export-artifacts.sh --list
hack/discover-export-artifacts.sh --local NAMESPACE/RESTOREPOINT --exported NAMESPACE/RESTOREPOINT
```

**Find namespaces retained after a failure**:

```bash
oc get ns -l k10.kasten.io/restore-test=true
```

---

## What to tell an auditor

Hand over three things, and be precise about the third.

1. The coverage report, `src/kdrill-report.sh --format markdown`. It states, per
   application, when its restore last succeeded and whether that is inside the
   committed cadence.
2. The ledger itself, either the ConfigMap or the file. It is the raw record the
   report is computed from, and it is append-only in practice.
3. The scope statement, [scope.md](scope.md). A passing run proves the exported
   data is readable and decryptable, that volumes provision and attach from it,
   and that the workloads start and pass their readiness probes. It does not
   prove data correctness, cross-application consistency, the ingress path, or
   recovery from cluster loss.

The third item is the one that protects you. kdrill is deliberately built so the
coverage claim is a guarantee over a known pool rather than a confidence
interval, which is why the rotation is deterministic. Do not let that precision
be mistaken for a broader claim than it is.
