#!/bin/bash
# Verify that every public CLI command is mapped to tests.
# Usage: ./tests/coverage-check.sh [--list-missing]
# Fails when any dispatcher command has no manifest entry, when the manifest
# names an unknown command, when a mapped file is missing, or when a command
# lacks success, failure, and no-op coverage.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/.." && pwd)"
MANIFEST="$HERE/coverage.json"

LIST_ONLY=0
[[ "${1:-}" == "--list-missing" ]] && LIST_ONLY=1

dispatch_commands() {
  grep -oE '^    [a-z][a-z0-9|-]*\) shift' "$ROOT/bin/omarchy-replicant" \
    | sed -e 's/^ *//' -e 's/) shift//' | sort -u
}

if [[ ! -f "$MANIFEST" ]]; then
  (( LIST_ONLY )) && exit 0
  echo "coverage manifest is missing: $MANIFEST" >&2; exit 1
fi
jq empty "$MANIFEST" >/dev/null 2>&1 || { echo "coverage manifest is not valid JSON" >&2; exit 1; }

failed=0
missing=""
while read -r cmd; do
  [[ -n "$cmd" ]] || continue
  if ! jq -e --arg c "$cmd" '.commands | has($c)' "$MANIFEST" >/dev/null; then
    missing="$missing $cmd"
    (( LIST_ONLY )) || { echo "unmapped command: $cmd" >&2; failed=1; }
    continue
  fi
  for kind in success failure noop; do
    file="$(jq -r --arg c "$cmd" --arg k "$kind" '.commands[$c][$k] // empty' "$MANIFEST")"
    if [[ -z "$file" ]]; then
      (( LIST_ONLY )) || { echo "$cmd has no $kind test mapping" >&2; failed=1; }
    elif [[ ! -e "$ROOT/$file" ]]; then
      (( LIST_ONLY )) || { echo "$cmd maps $kind to missing file $file" >&2; failed=1; }
    fi
  done
done < <(dispatch_commands)

while read -r cmd; do
  if ! dispatch_commands | grep -qx "$cmd"; then
    (( LIST_ONLY )) || { echo "manifest names unknown command: $cmd" >&2; failed=1; }
  fi
done < <(jq -r '.commands | keys[]' "$MANIFEST")

if (( LIST_ONLY )); then
  printf '%s' "$missing"
  [[ -n "$missing" ]] && printf '\n'
  exit 0
fi
exit "$failed"
