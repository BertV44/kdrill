#!/usr/bin/env bash
#
# Evidence gathering for CLAUDE.md known unverified item 1:
# "Exported vs local restore point discrimination."
#
# src/restore-test.sh currently greps EXPORT_MATCH (the S3 location profile
# name) against the whole restorepoints/{name}/details payload. That is a
# substring match over an entire JSON document, which is imprecise by
# construction. Nobody has yet looked at the payload on a live cluster.
#
# This script dumps the artifacts section of the details subresource for one
# local and one exported restore point, side by side, and reports:
#
#   1. where an "artifacts" key actually lives in the payload, if it exists
#   2. what differs between the local and the exported restore point
#   3. every JSON path at which the profile name appears, per restore point
#   4. whether a precise jsonpath selector could replace the grep
#
# The script asserts nothing about Kasten behaviour. It prints what the API
# returns, so the assumption can be settled with evidence.
#
# Usage:
#   hack/discover-export-artifacts.sh --list [NAMESPACE]
#   hack/discover-export-artifacts.sh \
#       --local    <namespace>/<restorepoint> \
#       --exported <namespace>/<restorepoint> \
#       [--profile <s3-location-profile-name>] \
#       [--outdir <dir>] [--width <cols>]
#
# --profile defaults to $EXPORT_MATCH. Identifying which restore point is the
# exported one is the operator's job: it is visible in the Kasten UI as the
# export action target, and it is precisely what this script exists to make
# machine-detectable.
#
# Target: Veeam Kasten 9.0.x on OpenShift 4.x.
# Requires: oc with a current context, python3, read access to
# apps.kio.kasten.io restorepoints and restorepoints/details.

set -euo pipefail

API="/apis/apps.kio.kasten.io/v1alpha1"
PROFILE="${EXPORT_MATCH:-}"
OUTDIR=""
WIDTH="${WIDTH:-200}"
LOCAL_REF=""
EXPORTED_REF=""
LIST_MODE="false"
LIST_NS=""

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
rule() { printf '%s\n' "-------------------------------------------------------------------------------"; }

usage() {
  sed -n '2,40p' "$0" | sed 's/^#//; s/^ //'
  exit "${1:-0}"
}

# --------------------------------------------------------------------------
# Arguments
# --------------------------------------------------------------------------
while [ "$#" -gt 0 ]; do
  case "$1" in
    --list)     LIST_MODE="true"; if [ "${2:-}" != "" ] && [ "${2#--}" = "$2" ]; then LIST_NS="$2"; shift; fi ;;
    --local)    LOCAL_REF="${2:?--local requires <namespace>/<restorepoint>}"; shift ;;
    --exported) EXPORTED_REF="${2:?--exported requires <namespace>/<restorepoint>}"; shift ;;
    --profile)  PROFILE="${2:?--profile requires a name}"; shift ;;
    --outdir)   OUTDIR="${2:?--outdir requires a directory}"; shift ;;
    --width)    WIDTH="${2:?--width requires a number}"; shift ;;
    -h|--help)  usage 0 ;;
    *)          die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------
command -v oc      >/dev/null 2>&1 || die "oc not found in PATH"
command -v python3 >/dev/null 2>&1 || die "python3 not found in PATH"

oc whoami >/dev/null 2>&1 || die "no usable oc context, run oc login first"

if ! oc auth can-i list restorepoints.apps.kio.kasten.io -A >/dev/null 2>&1; then
  info "warning: 'oc auth can-i list restorepoints' says no. Continuing anyway,"
  info "         the API calls below will report the real answer."
fi

# --------------------------------------------------------------------------
# --list: help the operator pick two restore points
# --------------------------------------------------------------------------
if [ "$LIST_MODE" = "true" ]; then
  info "Restore points visible to this account"
  rule
  printf '%-34s %-40s %-22s %s\n' NAMESPACE NAME ACTIONTIME LOGICAL_BYTES
  if [ -n "$LIST_NS" ]; then
    oc -n "$LIST_NS" get restorepoints.apps.kio.kasten.io \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.actionTime}{"\t"}{.status.logicalSizeBytes}{"\n"}{end}' 2>/dev/null \
      | awk -F'\t' '{printf "%-34s %-40s %-22s %s\n", $1, $2, $3, $4}'
  else
    oc get restorepoints.apps.kio.kasten.io -A \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.actionTime}{"\t"}{.status.logicalSizeBytes}{"\n"}{end}' 2>/dev/null \
      | awk -F'\t' '{printf "%-34s %-40s %-22s %s\n", $1, $2, $3, $4}'
  fi
  rule
  info ""
  info "Location profiles, candidate values for EXPORT_MATCH"
  rule
  oc get profiles.config.kio.kasten.io -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    || info "could not list profiles.config.kio.kasten.io with this account"
  rule
  info ""
  info "Next, pick one restore point you know is local only and one you know was"
  info "exported to S3, then run:"
  info "  hack/discover-export-artifacts.sh --local <ns>/<rp> --exported <ns>/<rp>"
  exit 0
fi

[ -n "$LOCAL_REF" ]    || die "--local is required (or use --list). Try --help"
[ -n "$EXPORTED_REF" ] || die "--exported is required (or use --list). Try --help"

case "$LOCAL_REF"    in */*) : ;; *) die "--local must be <namespace>/<restorepoint>" ;; esac
case "$EXPORTED_REF" in */*) : ;; *) die "--exported must be <namespace>/<restorepoint>" ;; esac

if [ -z "$OUTDIR" ]; then
  OUTDIR="$(mktemp -d)"
  info "no --outdir given, using ${OUTDIR}"
else
  mkdir -p "$OUTDIR"
fi

# --------------------------------------------------------------------------
# Fetch
# --------------------------------------------------------------------------
fetch_details() {
  # $1 = <namespace>/<restorepoint>, $2 = destination file
  local ref="$1" dest="$2" ns rp
  ns="${ref%%/*}"
  rp="${ref##*/}"
  info "fetching details for ${ns}/${rp}"
  if ! oc get --raw "${API}/namespaces/${ns}/restorepoints/${rp}/details" > "$dest" 2>"${dest}.err"; then
    info "  FAILED. API said:"
    sed 's/^/    /' "${dest}.err" >&2
    die "could not read the details subresource for ${ns}/${rp}"
  fi
  info "  wrote ${dest} ($(wc -c < "$dest" | tr -d ' ') bytes)"
}

LOCAL_JSON="${OUTDIR}/local.details.json"
EXPORTED_JSON="${OUTDIR}/exported.details.json"

fetch_details "$LOCAL_REF" "$LOCAL_JSON"
fetch_details "$EXPORTED_REF" "$EXPORTED_JSON"

# --------------------------------------------------------------------------
# Analysis
# --------------------------------------------------------------------------
# Locates any "artifacts" key at any depth, normalises it with sorted keys so
# that a diff reflects content and not key ordering, and reports every JSON
# path at which the profile name appears.
analyse() {
  python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import json, sys

path_in, label, profile, out_artifacts, out_paths = sys.argv[1:6]
doc = json.load(open(path_in))

def walk(node, path="$"):
    yield path, node
    if isinstance(node, dict):
        for k, v in node.items():
            yield from walk(v, f"{path}.{k}")
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from walk(v, f"{path}[{i}]")

# 1. every key literally named artifacts, at any depth
hits = [(p, v) for p, v in walk(doc) if p.rsplit(".", 1)[-1] == "artifacts"]

with open(out_artifacts, "w") as fh:
    if hits:
        for p, v in hits:
            fh.write(f"# artifacts found at JSON path: {p}\n")
            fh.write(json.dumps(v, indent=2, sort_keys=True))
            fh.write("\n")
    else:
        fh.write("# no key named 'artifacts' anywhere in this payload.\n")
        fh.write("# top-level structure follows, so the real shape is visible.\n")
        fh.write(json.dumps(doc, indent=2, sort_keys=True))
        fh.write("\n")

# 2. every JSON path whose key or value mentions the profile name
occ = []
if profile:
    for p, v in walk(doc):
        if isinstance(v, str) and profile in v:
            occ.append((p, v))
        elif isinstance(v, (dict, list)) is False and v is not None and profile in str(v):
            occ.append((p, str(v)))

with open(out_paths, "w") as fh:
    fh.write(f"# profile name searched: {profile or '(none given)'}\n")
    if not profile:
        fh.write("# pass --profile or set EXPORT_MATCH to run this part.\n")
    elif occ:
        for p, v in occ:
            fh.write(f"{p} = {v!r}\n")
    else:
        fh.write("# the profile name does not appear anywhere in this payload.\n")

print(f"{label}: artifacts keys found: {len(hits)}"
      + (f" at {', '.join(p for p, _ in hits)}" if hits else " (none)"))
print(f"{label}: profile name occurrences: {len(occ)}")
PY
}

info ""
info "Analysis"
rule
analyse "$LOCAL_JSON"    "local"    "$PROFILE" "${OUTDIR}/local.artifacts.txt"    "${OUTDIR}/local.profile-paths.txt"
analyse "$EXPORTED_JSON" "exported" "$PROFILE" "${OUTDIR}/exported.artifacts.txt" "${OUTDIR}/exported.profile-paths.txt"
rule

# --------------------------------------------------------------------------
# Side by side
# --------------------------------------------------------------------------
info ""
info "Artifacts section, local (left) against exported (right)"
info "local    = ${LOCAL_REF}"
info "exported = ${EXPORTED_REF}"
rule
diff -y --width="$WIDTH" \
  "${OUTDIR}/local.artifacts.txt" \
  "${OUTDIR}/exported.artifacts.txt" || true
rule

info ""
info "Unified diff of the same two sections"
rule
diff -u \
  --label "local:${LOCAL_REF}"    "${OUTDIR}/local.artifacts.txt" \
  --label "exported:${EXPORTED_REF}" "${OUTDIR}/exported.artifacts.txt" || true
rule

info ""
info "Where the profile name '${PROFILE:-(none)}' appears"
rule
info "local (${LOCAL_REF}):"
sed 's/^/  /' "${OUTDIR}/local.profile-paths.txt"
info "exported (${EXPORTED_REF}):"
sed 's/^/  /' "${OUTDIR}/exported.profile-paths.txt"
rule

# --------------------------------------------------------------------------
# Verdict
# --------------------------------------------------------------------------
local_hits=$(grep -cv '^#' "${OUTDIR}/local.profile-paths.txt"    || true)
export_hits=$(grep -cv '^#' "${OUTDIR}/exported.profile-paths.txt" || true)

info ""
info "Verdict on the EXPORT_MATCH grep"
rule
info "profile name occurrences: local=${local_hits} exported=${export_hits}"
if [ -n "$PROFILE" ] && [ "$local_hits" -eq 0 ] && [ "$export_hits" -gt 0 ]; then
  info "The grep discriminates on this pair: the profile name appears only in the"
  info "exported payload. Read the JSON paths above and replace the grep with a"
  info "jsonpath selector against the narrowest stable path."
elif [ -n "$PROFILE" ] && [ "$local_hits" -gt 0 ]; then
  info "The grep DOES NOT discriminate: the profile name also appears in the local"
  info "payload. src/restore-test.sh would select local restore points and the tool"
  info "would silently stop testing the export path. This must be fixed before use."
elif [ -n "$PROFILE" ]; then
  info "The profile name appears in neither payload. Either the name is wrong, or"
  info "the details subresource does not carry it. resolve_exported_rp would find"
  info "no candidate and every namespace would be skipped."
else
  info "No profile name given, so the grep was not evaluated. Re-run with --profile."
fi
rule
info ""
info "Raw payloads kept for inspection:"
info "  ${LOCAL_JSON}"
info "  ${EXPORTED_JSON}"
info ""
info "Record the outcome in CLAUDE.md, known unverified item 1."
