#!/usr/bin/env bash
#
# Generates examples/job-on-demand.yaml from deploy/40-cronjob.yaml.
#
# Why generated rather than written by hand: the Job and the CronJob share the
# entire pod specification, roughly eighty lines of environment, resources,
# security context and volumes. Maintaining two copies guarantees they drift,
# and the on-demand path would then quietly stop matching the scheduled one.
# The CronJob stays the single source of truth for how kdrill runs; this script
# republishes its jobTemplate as a standalone Job.
#
# Same contract as hack/build-configmap.sh: the output is a pure function of the
# input, so a rebuild with no source change produces no git diff.
#
# Usage:
#   hack/build-job.sh            regenerate the manifest
#   hack/build-job.sh --check    fail if the manifest is out of date
#
# The generated Job uses generateName, so it is created with `oc create`, not
# `oc apply`, and every invocation produces a fresh run. See the README section
# "Running without a CronJob".

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${REPO_ROOT}/deploy/40-cronjob.yaml"
OUT="${REPO_ROOT}/examples/job-on-demand.yaml"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ -f "$SRC" ] || die "source not found: ${SRC}"

# shellcheck disable=SC2312
source_checksum() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$SRC" | cut -d' ' -f1
  else
    shasum -a 256 "$SRC" | cut -d' ' -f1
  fi
}

# Lifts spec.jobTemplate.spec out of the CronJob and dedents it by four spaces
# so it becomes a Job spec. Stops at the first line shallower than the block, so
# a key added after jobTemplate does not get swept in.
extract_job_spec() {
  awk '
    /^  jobTemplate:[[:space:]]*$/          { in_jt = 1; next }
    in_jt && /^    spec:[[:space:]]*$/      { in_spec = 1; next }
    in_spec {
      if ($0 ~ /^[[:space:]]*$/) { print ""; next }
      if ($0 !~ /^      /)       { exit }
      print substr($0, 5)
    }
  ' "$SRC"
}

JOB_SPEC="$(extract_job_spec)"

# Fail loudly rather than emitting a Job that is missing half its definition.
[ -n "$JOB_SPEC" ] || die "could not extract spec.jobTemplate.spec from ${SRC}"
for key in "backoffLimit:" "activeDeadlineSeconds:" "template:" "serviceAccountName:" "restartPolicy:"; do
  case "$JOB_SPEC" in
    *"$key"*) : ;;
    *) die "extracted job spec is missing '${key}', the CronJob layout may have changed" ;;
  esac
done

render() {
  local checksum="$1"

  echo "# ============================================================================="
  echo "# GENERATED FILE. DO NOT EDIT."
  echo "#"
  echo "# Produced by hack/build-job.sh from deploy/40-cronjob.yaml."
  echo "# Edit the CronJob, then run: hack/build-job.sh"
  echo "#"
  echo "# deploy/40-cronjob.yaml sha256: ${checksum}"
  echo "# ============================================================================="
  echo "#"
  echo "# On-demand kdrill run, for clusters that do not use the CronJob."
  echo "#"
  echo "# Use this when the schedule lives somewhere else: an external orchestrator"
  echo "# such as Tekton, Argo Workflows or Ansible, a change-control process where a"
  echo "# restore test only runs once a human has authorised it, a one-off check"
  echo "# before or after a cluster upgrade, or a policy that forbids CronJob."
  echo "#"
  echo "# This is an alternative to deploy/40-cronjob.yaml, not an addition. Apply"
  echo "# deploy/00 through deploy/30, then use this instead of deploy/40."
  echo "#"
  echo "# It carries generateName, not name, so create it and let the API server"
  echo "# name each run:"
  echo "#"
  echo "#   oc create -f examples/job-on-demand.yaml"
  echo "#"
  echo "# \`oc apply\` will NOT work on this file, by design: apply needs a fixed name,"
  echo "# and a completed Job cannot be re-applied because its spec is immutable."
  echo "# Creating is what makes the run repeatable."
  echo "#"
  echo "# Override any environment variable for a single run, without editing this"
  echo "# file, by piping through \`oc set env --local\`:"
  echo "#"
  echo "#   oc create -f examples/job-on-demand.yaml --dry-run=client -o yaml \\"
  echo "#     | oc set env --local -f - -o yaml SELECTION_MODE=all DRY_RUN=true \\"
  echo "#     | oc create -f -"
  echo "#"
  echo "# That preserves generateName and every other variable. Verified on oc 4.21."
  echo "# ============================================================================="
  echo "---"
  echo "apiVersion: batch/v1"
  echo "kind: Job"
  echo "metadata:"
  echo "  generateName: k10-restore-test-"
  echo "  namespace: k10-restore-test"
  echo "  labels:"
  echo "    app.kubernetes.io/name: k10-restore-test"
  echo "    kdrill.io/trigger: on-demand"
  echo "  annotations:"
  echo "    kdrill.io/generated-by: hack/build-job.sh"
  echo "    kdrill.io/source-sha256: \"${checksum}\""
  echo "spec:"
  printf '%s\n' "$JOB_SPEC"
}

CHECKSUM="$(source_checksum)"

if [ "${1:-}" = "--check" ]; then
  [ -f "$OUT" ] || die "${OUT} does not exist, run hack/build-job.sh"
  if render "$CHECKSUM" | diff -u "$OUT" - >/dev/null; then
    echo "up to date: examples/job-on-demand.yaml"
    exit 0
  fi
  echo "error: examples/job-on-demand.yaml is out of date or hand-edited" >&2
  render "$CHECKSUM" | diff -u "$OUT" - >&2 || true
  exit 1
fi

if [ "${1:-}" != "" ]; then
  die "unknown argument: $1 (expected no argument or --check)"
fi

TMP="${OUT}.tmp.$$"
# shellcheck disable=SC2064
trap "rm -f '${TMP}'" EXIT
render "$CHECKSUM" > "$TMP"
mv "$TMP" "$OUT"

printf 'wrote %s (source sha256 %s)\n' "examples/job-on-demand.yaml" "$CHECKSUM"
