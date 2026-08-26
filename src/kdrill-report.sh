#!/usr/bin/env bash
#
# kdrill coverage report.
#
# Answers the question an auditor actually asks: for every application in scope,
# when was its restore last proven to work, and is that within the cadence we
# committed to. It reads the coverage ledger and reports, it never restores
# anything and never writes.
#
# This is the deliverable behind architecture decision 5 in CLAUDE.md. kdrill
# rotates deterministically rather than sampling randomly precisely so that this
# report can state a coverage guarantee instead of a confidence interval.
#
# Deliberately self-contained: no shared library, no ConfigMap, no Kubernetes
# object of its own. Copy this single file to a workstation, a CI runner or a
# jump host and it works. That self-containment is why it repeats a little logic
# from restore-test.sh; the two must be kept in step when eligibility changes.
#
# Target: Veeam Kasten 9.0.x on OpenShift 4.x or vanilla Kubernetes 1.x.
# Requires: oc or kubectl with a working context, and GNU or BSD date.
#
# Usage:
#   src/kdrill-report.sh [--format text|csv|markdown] [--quiet]
#
# Configuration is by environment variable, using the same names as
# restore-test.sh so one set of settings drives both:
#   SELF_NS, LEDGER_CONFIGMAP, LEDGER_BACKEND, LEDGER_FILE
#   SELECTION_MODE, INCLUDE_LABEL, EXCLUDE_LABEL, TIER_LABEL
#   TIER1_CADENCE_DAYS, TIER2_CADENCE_DAYS, TIER3_CADENCE_DAYS,
#   DEFAULT_CADENCE_DAYS, SYSTEM_NS_REGEX, TARGET_SUFFIX
#   EXPORT_LABEL, EXPORT_MATCH  (optional, adds the restorable column)
#
# Exit status, so it can gate a pipeline:
#   0  every namespace in scope is within its cadence
#   1  at least one namespace is overdue or has never been tested
#   2  usage or environment error

set -euo pipefail

SELF_NS="${SELF_NS:-k10-restore-test}"
LEDGER="${LEDGER_CONFIGMAP:-k10-restore-test-ledger}"
LEDGER_BACKEND="${LEDGER_BACKEND:-configmap}"
LEDGER_FILE="${LEDGER_FILE:-${HOME:-/tmp}/.kdrill/ledger}"

SELECTION_MODE="${SELECTION_MODE:-opt-in}"
INCLUDE_LABEL="${INCLUDE_LABEL:-k10.kasten.io/restore-test=enabled}"
EXCLUDE_LABEL="${EXCLUDE_LABEL:-k10.kasten.io/restore-test=excluded}"
TIER_LABEL="${TIER_LABEL:-backup-tier}"
SUFFIX="${TARGET_SUFFIX:--restored}"

TIER1_CADENCE="${TIER1_CADENCE_DAYS:-7}"
TIER2_CADENCE="${TIER2_CADENCE_DAYS:-30}"
TIER3_CADENCE="${TIER3_CADENCE_DAYS:-90}"
DEFAULT_CADENCE="${DEFAULT_CADENCE_DAYS:-30}"

SYSTEM_NS_RE="${SYSTEM_NS_REGEX:-^(openshift|kube|default$|kasten-io$|k10-restore-test$)}"

EXPORT_LABEL="${EXPORT_LABEL:-k10.kasten.io/exportProfile}"
EXPORT_MATCH="${EXPORT_MATCH:-}"

FORMAT="text"
QUIET="false"
CLI="${KDRILL_CLI:-}"
DATE_FLAVOUR=""
NOW=$(date -u +%s)
GENERATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

die() { printf 'error: %s\n' "$*" >&2; exit 2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --format) FORMAT="${2:?--format requires text, csv or markdown}"; shift ;;
    --quiet)  QUIET="true" ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^#//; s/^ //'; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

case "$FORMAT" in
  text|csv|markdown) : ;;
  *) die "--format must be text, csv or markdown, got '${FORMAT}'" ;;
esac

case "$LEDGER_BACKEND" in
  configmap|file) : ;;
  *) die "LEDGER_BACKEND must be configmap or file, got '${LEDGER_BACKEND}'" ;;
esac

if [ -z "$CLI" ]; then
  for c in oc kubectl; do
    if command -v "$c" >/dev/null 2>&1; then CLI="$c"; break; fi
  done
fi
[ -n "$CLI" ] || die "neither oc nor kubectl found in PATH"
command -v "$CLI" >/dev/null 2>&1 || die "KDRILL_CLI=${CLI} is not in PATH"
"$CLI" api-versions >/dev/null 2>&1 || die "cannot reach the cluster API using ${CLI}"

if date -u -d "2000-01-01T00:00:00Z" +%s >/dev/null 2>&1; then
  DATE_FLAVOUR="gnu"
elif date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "2000-01-01T00:00:00Z" +%s >/dev/null 2>&1; then
  DATE_FLAVOUR="bsd"
else
  die "no usable date implementation, install GNU coreutils"
fi

epoch_of() {
  case "$DATE_FLAVOUR" in
    gnu) date -u -d "$1" +%s 2>/dev/null || echo 0 ;;
    bsd) date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || echo 0 ;;
    *)   echo 0 ;;
  esac
}

ledger_get() {
  case "$LEDGER_BACKEND" in
    file)
      if [ -f "$LEDGER_FILE" ]; then
        awk -F'\t' -v k="$1" '$1 == k { print $2; exit }' "$LEDGER_FILE"
      fi
      ;;
    *)
      "$CLI" -n "$SELF_NS" get configmap "$LEDGER" \
        -o "jsonpath={.data.$1}" 2>/dev/null || true
      ;;
  esac
}

cadence_for_tier() {
  case "$1" in
    1) echo "$TIER1_CADENCE" ;;
    2) echo "$TIER2_CADENCE" ;;
    3) echo "$TIER3_CADENCE" ;;
    *) echo "$DEFAULT_CADENCE" ;;
  esac
}

ns_has_label() {
  [ -n "$("$CLI" get namespace -l "$2" \
            -o "jsonpath={.items[?(@.metadata.name=='$1')].metadata.name}" \
            2>/dev/null)" ]
}

# --------------------------------------------------------------------------
# Collect
# --------------------------------------------------------------------------
declare -a R_NS=() R_TIER=() R_CADENCE=() R_LAST=() R_AGE=() R_STATUS=() R_RP=()
COUNT_OK=0; COUNT_OVERDUE=0; COUNT_NEVER=0; WORST=0

for ns in $("$CLI" get restorepoints.apps.kio.kasten.io -A \
              -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' \
              2>/dev/null | sort -u); do

  [[ "$ns" =~ $SYSTEM_NS_RE ]] && continue
  [[ "$ns" == *"$SUFFIX" ]] && continue

  case "$SELECTION_MODE" in
    opt-in)  ns_has_label "$ns" "$INCLUDE_LABEL" || continue ;;
    opt-out) ns_has_label "$ns" "$EXCLUDE_LABEL" && continue ;;
    all)     : ;;
    *) die "SELECTION_MODE must be opt-in, opt-out or all, got '${SELECTION_MODE}'" ;;
  esac

  tier=$("$CLI" get namespace "$ns" \
           -o "jsonpath={.metadata.labels.$TIER_LABEL}" 2>/dev/null || true)
  cadence=$(cadence_for_tier "${tier:-default}")
  last=$(ledger_get "$ns")

  if [ -z "$last" ]; then
    age="-"; status="NEVER TESTED"; COUNT_NEVER=$(( COUNT_NEVER + 1 ))
  else
    ref=$(epoch_of "$last")
    if [ "$ref" -eq 0 ]; then
      age="?"; status="UNPARSEABLE"; COUNT_NEVER=$(( COUNT_NEVER + 1 ))
    else
      age=$(( (NOW - ref) / 86400 ))
      if [ "$age" -gt "$WORST" ]; then WORST="$age"; fi
      if [ "$age" -gt "$cadence" ]; then
        status="OVERDUE"; COUNT_OVERDUE=$(( COUNT_OVERDUE + 1 ))
      else
        status="OK"; COUNT_OK=$(( COUNT_OK + 1 ))
      fi
    fi
  fi

  # Optional: is there currently an exported restore point kdrill could use.
  rp="not checked"
  if [ -n "$EXPORT_MATCH" ]; then
    n=$("$CLI" -n "$ns" get restorepoints.apps.kio.kasten.io \
          -l "${EXPORT_LABEL}=${EXPORT_MATCH}" \
          -o jsonpath='{range .items[*]}x{end}' 2>/dev/null | wc -c | tr -d ' ')
    if [ "${n:-0}" -gt 0 ]; then rp="yes"; else rp="NONE"; fi
  fi

  R_NS+=("$ns"); R_TIER+=("${tier:-none}"); R_CADENCE+=("$cadence")
  R_LAST+=("${last:--}"); R_AGE+=("$age"); R_STATUS+=("$status"); R_RP+=("$rp")
done

TOTAL=${#R_NS[@]}

# --------------------------------------------------------------------------
# Render
# --------------------------------------------------------------------------
render_text() {
  printf 'kdrill coverage report\n'
  printf 'generated       : %s\n' "$GENERATED_AT"
  printf 'cluster         : %s\n' "$("$CLI" config current-context 2>/dev/null || echo unknown)"
  printf 'selection mode  : %s\n' "$SELECTION_MODE"
  if [ "$LEDGER_BACKEND" = "file" ]; then
    printf 'ledger          : file %s\n' "$LEDGER_FILE"
  else
    printf 'ledger          : configmap %s/%s\n' "$SELF_NS" "$LEDGER"
  fi
  printf 'cadence targets : tier1=%sd tier2=%sd tier3=%sd default=%sd\n\n' \
    "$TIER1_CADENCE" "$TIER2_CADENCE" "$TIER3_CADENCE" "$DEFAULT_CADENCE"

  if [ "$TOTAL" -eq 0 ]; then
    printf 'No namespace is in scope. That is not coverage, it is an empty pool.\n'
    printf 'In opt-in mode, check that %s is applied somewhere.\n' "$INCLUDE_LABEL"
    return
  fi

  printf '%-34s %-6s %-8s %-22s %-6s %-13s %s\n' \
    NAMESPACE TIER CADENCE LAST_PASSED AGE STATUS EXPORT_RP
  printf '%s\n' "-------------------------------------------------------------------------------------------------------------"
  local i
  for i in "${!R_NS[@]}"; do
    printf '%-34s %-6s %-8s %-22s %-6s %-13s %s\n' \
      "${R_NS[$i]}" "${R_TIER[$i]}" "${R_CADENCE[$i]}d" "${R_LAST[$i]}" \
      "${R_AGE[$i]}" "${R_STATUS[$i]}" "${R_RP[$i]}"
  done
  printf '%s\n' "-------------------------------------------------------------------------------------------------------------"
  printf '\nin scope %s   within cadence %s   overdue %s   never tested %s   worst age %sd\n' \
    "$TOTAL" "$COUNT_OK" "$COUNT_OVERDUE" "$COUNT_NEVER" "$WORST"
  if [ "$TOTAL" -gt 0 ]; then
    printf 'compliance %s%% of namespaces in scope are within their cadence\n' \
      "$(( COUNT_OK * 100 / TOTAL ))"
  fi
  printf '\nWhat a passing row means is defined in docs/scope.md. It does not mean the\n'
  printf 'data was checked, only that the application restored from its export and\n'
  printf 'became Ready.\n'
}

render_csv() {
  printf 'namespace,tier,cadence_days,last_passed,age_days,status,export_restore_point,generated_at\n'
  local i
  for i in "${!R_NS[@]}"; do
    printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "${R_NS[$i]}" "${R_TIER[$i]}" "${R_CADENCE[$i]}" "${R_LAST[$i]}" \
      "${R_AGE[$i]}" "${R_STATUS[$i]}" "${R_RP[$i]}" "$GENERATED_AT"
  done
}

# shellcheck disable=SC2016
# The backticks below are literal Markdown code spans, not command substitution.
# Single quotes are correct here and the values arrive through printf arguments.
render_markdown() {
  printf '# kdrill coverage report\n\n'
  printf -- '- Generated: `%s`\n' "$GENERATED_AT"
  printf -- '- Cluster: `%s`\n' "$("$CLI" config current-context 2>/dev/null || echo unknown)"
  printf -- '- Selection mode: `%s`\n' "$SELECTION_MODE"
  printf -- '- Cadence targets: tier1 %sd, tier2 %sd, tier3 %sd, default %sd\n\n' \
    "$TIER1_CADENCE" "$TIER2_CADENCE" "$TIER3_CADENCE" "$DEFAULT_CADENCE"
  printf '| Namespace | Tier | Cadence | Last passed | Age | Status | Export RP |\n'
  printf '|---|---|---:|---|---:|---|---|\n'
  local i
  for i in "${!R_NS[@]}"; do
    printf '| `%s` | %s | %sd | %s | %s | %s | %s |\n' \
      "${R_NS[$i]}" "${R_TIER[$i]}" "${R_CADENCE[$i]}" "${R_LAST[$i]}" \
      "${R_AGE[$i]}" "${R_STATUS[$i]}" "${R_RP[$i]}"
  done
  printf '\n**In scope %s, within cadence %s, overdue %s, never tested %s, worst age %sd.**\n' \
    "$TOTAL" "$COUNT_OK" "$COUNT_OVERDUE" "$COUNT_NEVER" "$WORST"
  printf '\nWhat a passing row means is defined in `docs/scope.md`. It does not mean the\n'
  printf 'data was checked, only that the application restored from its export and\n'
  printf 'became Ready.\n'
}

if [ "$QUIET" != "true" ]; then
  case "$FORMAT" in
    text)     render_text ;;
    csv)      render_csv ;;
    markdown) render_markdown ;;
  esac
fi

if [ "$COUNT_OVERDUE" -gt 0 ] || [ "$COUNT_NEVER" -gt 0 ]; then exit 1; fi
exit 0
