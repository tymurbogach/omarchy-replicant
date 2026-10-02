#!/bin/bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
export HOME="$WORK/home" OMARCHY_REPLICANT_HOME="$WORK/data" REPLICANT_PROFILE=desktop
mkdir -p "$HOME"
"$ROOT/bin/replicant" init >/dev/null
test "$(jq -r .format "$OMARCHY_REPLICANT_HOME/repo/.replicant/schema.json")" = replicant
"$ROOT/bin/replicant-core.sh" schema-gate
for marker in '{}' '{"format":"wrong"}' '{"format":"replicant","extra":true}'; do
  printf '%s\n' "$marker" > "$OMARCHY_REPLICANT_HOME/repo/.replicant/schema.json"
  if "$ROOT/bin/replicant-core.sh" schema-gate >/dev/null 2>&1; then echo "accepted invalid schema" >&2; exit 1; fi
done
printf '{"format":"replicant"}\n' > "$OMARCHY_REPLICANT_HOME/repo/.replicant/schema.json"
mkdir -p "$OMARCHY_REPLICANT_HOME/repo/secrets"; printf x > "$OMARCHY_REPLICANT_HOME/repo/secrets/plain"
if "$ROOT/bin/replicant-core.sh" schema-gate >/dev/null 2>&1; then echo "accepted plaintext secret" >&2; exit 1; fi
rm -rf "$OMARCHY_REPLICANT_HOME/repo/secrets"
for id in '../bad' 'bad//id'; do
  printf '{"%s":{"path":"%s/file","kind":"config","scope":"shared","source":"user"}}\n' "$id" "$HOME" > "$OMARCHY_REPLICANT_HOME/repo/.replicant/entries.json"
  if "$ROOT/bin/replicant-core.sh" schema-gate >/dev/null 2>&1; then echo "accepted unsafe entry id" >&2; exit 1; fi
done
printf '{}\n' > "$OMARCHY_REPLICANT_HOME/repo/.replicant/entries.json"
"$ROOT/bin/replicant-core.sh" schema-gate
echo "format tests passed"
