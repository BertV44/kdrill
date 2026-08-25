#!/usr/bin/env bash
#
# Generates deploy/30-script-configmap.yaml from src/restore-test.sh.
#
# The output is a pure function of the input: same source, same bytes, no
# timestamps, no hostnames, no ordering that depends on the filesystem. A
# rebuild with no source change therefore produces no git diff.
#
# Usage:
#   hack/build-configmap.sh            regenerate the manifest
#   hack/build-configmap.sh --check    fail if the manifest is out of date
#
# The --check mode is what a CI job or a pre-commit hook should call. It is
# also the guard against hand-editing the generated file.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${REPO_ROOT}/src/restore-test.sh"
OUT="${REPO_ROOT}/deploy/30-script-configmap.yaml"

CM_NAME="k10-restore-test-script"
CM_NAMESPACE="k10-restore-test"
KEY="restore-test.sh"
INDENT="    "

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ -f "$SRC" ] || die "source not found: ${SRC}"

# shellcheck disable=SC2312
# sha256sum on Linux, shasum on macOS. Only the hex digest is kept.
script_checksum() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$SRC" | cut -d' ' -f1
  else
    shasum -a 256 "$SRC" | cut -d' ' -f1
  fi
}

render() {
  local checksum="$1"

  echo "# ============================================================================="
  echo "# GENERATED FILE. DO NOT EDIT."
  echo "#"
  echo "# Produced by hack/build-configmap.sh from src/restore-test.sh."
  echo "# Edit the script, then run: hack/build-configmap.sh"
  echo "#"
  echo "# src/restore-test.sh sha256: ${checksum}"
  echo "# ============================================================================="
  echo "---"
  echo "apiVersion: v1"
  echo "kind: ConfigMap"
  echo "metadata:"
  echo "  name: ${CM_NAME}"
  echo "  namespace: ${CM_NAMESPACE}"
  echo "  annotations:"
  echo "    kdrill.io/generated-by: hack/build-configmap.sh"
  echo "    kdrill.io/source-sha256: \"${checksum}\""
  echo "data:"
  echo "  ${KEY}: |"

  # Indent every line by INDENT. Lines that are empty stay empty rather than
  # becoming whitespace-only, so the file carries no trailing whitespace.
  while IFS= read -r line; do
    if [ -z "$line" ]; then
      echo ""
    else
      printf '%s%s\n' "$INDENT" "$line"
    fi
  done < "$SRC"
}

CHECKSUM="$(script_checksum)"

if [ "${1:-}" = "--check" ]; then
  [ -f "$OUT" ] || die "${OUT} does not exist, run hack/build-configmap.sh"
  if render "$CHECKSUM" | diff -u "$OUT" - >/dev/null; then
    echo "up to date: deploy/30-script-configmap.yaml"
    exit 0
  fi
  echo "error: deploy/30-script-configmap.yaml is out of date or hand-edited" >&2
  echo "diff (committed vs regenerated):" >&2
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

printf 'wrote %s (source sha256 %s)\n' "deploy/30-script-configmap.yaml" "$CHECKSUM"
