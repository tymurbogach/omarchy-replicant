#!/bin/bash
# The v3 data repository schema: the version marker, the write gate, the
# entries validation, the version 2 vault index, and the machine metadata.
# Everything runs against a fake $HOME and a throwaway repo, the way
# test-schema.sh does for v2.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CORE="$HERE/../bin/replicant-core.sh"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

if ! command -v age >/dev/null 2>&1 || ! command -v age-keygen >/dev/null 2>&1; then
  echo "age or age-keygen is not on PATH — skipped (omarchy pkg add age)"
  exit 0
fi
probe_dir=$(mktemp -d); trap 'rm -rf "$TMP" "$probe_dir"' EXIT
if ! ( umask 077; age-keygen -pq -o "$probe_dir/key" >/dev/null 2>&1 ) \
    || ! grep -q '^# public key: age1pq1' "$probe_dir/key" 2>/dev/null; then
  echo "age-keygen here cannot make post-quantum keys — skipped (upgrade age past 1.3)"
  exit 0
fi
rm -rf -- "$probe_dir"

TMP=$(mktemp -d)
export HOME="$TMP/home"
export OMARCHY_PATH="$TMP/omarchy"
export OMARCHY_REPLICANT_HOME="$TMP/replicant"

mkdir -p "$HOME/.config/hypr" "$HOME/.config/environment.d" "$OMARCHY_PATH/config/hypr"
printf 'default input\n' > "$OMARCHY_PATH/config/hypr/input.lua"
printf 'my own input\n'  > "$HOME/.config/hypr/input.lua"
printf 'FIRST=v3-fixture-alpha\n' > "$HOME/.config/environment.d/60-secrets.conf"
printf 'notes-body-v3-beta\n' > "$HOME/.config/notes-private.conf"

# shellcheck source=/dev/null
source "$CORE" 2>/dev/null
set +e +u

section "a fresh repo is born v3"
core_backup >/dev/null 2>&1
check "schema marker says version 3" "3" \
  "$(jq -r .dataVersion "$REPO_DIR/.replicant/schema.json" 2>/dev/null)"
check "…and names the v2 secret format" "age-pq-v2" \
  "$(jq -r .secretFormat "$REPO_DIR/.replicant/schema.json" 2>/dev/null)"
check "the entry registry starts empty" "{}" \
  "$(jq -c . "$REPO_DIR/.replicant/entries.json" 2>/dev/null)"
check "…loading as no rows" "" "$(load_v3_entries)"
check "the machine record is at schema version 3" "3" \
  "$(jq -r .schemaVersion "$REPO_DIR/.replicant/machines/$MACHINE.json" 2>/dev/null)"
check_false "no legacy track file in a fresh v3 repo" test -f "$REPO_DIR/.replicant-track"
check_false "no legacy sync file in a fresh v3 repo" test -f "$REPO_DIR/.replicant-sync"
check_false "no legacy profiles file in a fresh v3 repo" test -f "$REPO_DIR/.replicant-profiles"
git -C "$REPO_DIR" add -A >/dev/null 2>&1
git -C "$REPO_DIR" commit -qm "born v3" >/dev/null 2>&1

section "malformed schema fields are rejected before mutation"
cp "$REPO_DIR/.replicant/schema.json" "$TMP/schema.keep"
printf '{"dataVersion":"3","secretFormat":"age-pq-v2"}\n' > "$REPO_DIR/.replicant/schema.json"
check_false "a string dataVersion blocks writes" core_backup
printf '{"dataVersion":3,"secretFormat":"age-pq-v2","dataVersion":2}\n' > "$REPO_DIR/.replicant/schema.json"
check_false "duplicate schema keys block writes" require_writable_schema
check_contains "…naming the duplication" "duplicate" "$(require_writable_schema 2>&1 || true)"
printf '{not json' > "$REPO_DIR/.replicant/schema.json"
check_false "a corrupt schema blocks writes" core_backup
cp "$TMP/schema.keep" "$REPO_DIR/.replicant/schema.json"
check "a refused write leaves the repo clean" "" \
  "$(git -C "$REPO_DIR" status --porcelain 2>/dev/null)"

section "entries validation names the bad"
good="$TMP/good.json"
cat > "$good" <<EOF
{"hypr/input.lua": {"path": "$HOME/.config/hypr/input.lua", "kind": "config", "scope": "shared", "source": "user"}}
EOF
check_true "a sound file validates" validate_v3_entries "$good"
printf '{"a": {"path": "/tmp/x\x01y", "kind": "config", "scope": "shared", "source": "user"}}' > "$TMP/f.json"
check_false "a control character in a path" validate_v3_entries "$TMP/f.json"
printf '{"a": {"path": "/x", "kind": "config", "scope": "shared", "source": "user"}, "a": {"path": "/y", "kind": "config", "scope": "shared", "source": "user"}}' > "$TMP/f.json"
check_false "a duplicate id" validate_v3_entries "$TMP/f.json"
check_contains "…naming the id" "duplicate id a" "$(validate_v3_entries "$TMP/f.json" 2>&1 || true)"

section "a custom secret round trip stays in the vault"
check_true "key init works on v3" key_init
printf 'notes-body-v3-beta\n' > "$HOME/.config/notes-private.conf"
check_true "tracking a custom secret works" core_track "$HOME/.config/notes-private.conf" --secret
core_backup >/dev/null 2>&1
idx="$(vault_index_decrypt 2>/dev/null)"
check "the vault index is version 2" "2" "$(jq -r .version <<<"$idx" 2>/dev/null)"
check "…recording the secret path" "$HOME/.config/notes-private.conf" \
  "$(jq -r '.secrets[] | select(.id == "notes-private.conf") | .path' <<<"$idx" 2>/dev/null)"
check "…recording its source" "user" \
  "$(jq -r '.secrets[] | select(.id == "notes-private.conf") | .source' <<<"$idx" 2>/dev/null)"
check "…with a 32-char hex blob" "32" \
  "$(jq -r '.secrets[] | select(.id == "notes-private.conf") | .blob' <<<"$idx" 2>/dev/null | tr -d '\n' | wc -c)"
registry_build >/dev/null 2>&1
check_true "the registry knows the secret" registry_row_for notes-private.conf
check_true "untracking drops it" core_untrack notes-private.conf
registry_build >/dev/null 2>&1
check_false "…and it leaves the registry" registry_row_for notes-private.conf

section "scope changes reload through the registry"
printf 'scope-body-v3\n' > "$HOME/.config/scope-me.conf"
check_true "tracking works" core_track "$HOME/.config/scope-me.conf"
check_true "scoping to profile works" core_scope scope-me.conf profile
check "the entries record holds the scope" "profile" \
  "$(jq -r '."scope-me.conf".scope' "$REPO_DIR/.replicant/entries.json" 2>/dev/null)"
registry_build >/dev/null 2>&1
check "…and the registry agrees" "profile" \
  "$(registry_row_for scope-me.conf | cut -f5)"
check_true "restoring the scope works" core_scope scope-me.conf shared
registry_build >/dev/null 2>&1
check "…and the registry shows shared again" "shared" \
  "$(registry_row_for scope-me.conf | cut -f5)"
check "the scope round trip touches only the policy file" "" \
  "$(git -C "$REPO_DIR" status --porcelain 2>/dev/null | grep '^ M' | grep -v 'M .replicant/entries.json' || true)"

section "the profile lives in the machine record"
check_true "setting a profile works" core_profile_set laptop
check "…recorded in the machine JSON" "laptop" \
  "$(jq -r .profile "$REPO_DIR/.replicant/machines/$MACHINE.json" 2>/dev/null)"
check "…which the resolver reads" "laptop" "$(current_profile)"
check_false "no legacy profiles file appears" test -f "$REPO_DIR/.replicant-profiles"

section "legacy policy files contaminate a v3 repo"
printf 'scope-me.conf = off\n' > "$REPO_DIR/.replicant-sync"
check_false "writes refuse a contaminated repo" core_track "$HOME/.config/scope-me.conf"
check_contains "…naming the legacy file" ".replicant-sync" "$(core_track "$HOME/.config/scope-me.conf" 2>&1 || true)"
rm -f "$REPO_DIR/.replicant-sync"

summary
