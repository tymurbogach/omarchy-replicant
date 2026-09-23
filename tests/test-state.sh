#!/bin/bash
# The unified entry registry: every source that names an entry resolves to one
# row with eight fields, and on version 1 it holds exactly what the tracked
# lists hold. Everything runs against a fake $HOME and a throwaway repo, the
# way test-core.sh does.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CORE="$HERE/../bin/replicant-core.sh"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export OMARCHY_PATH="$TMP/omarchy"
export OMARCHY_REPLICANT_HOME="$TMP/replicant"

mkdir -p "$HOME/.config/hypr" "$HOME/.config/nvim" "$HOME/.config/omarchy/plugins/demoifact" \
  "$HOME/.config/environment.d" "$OMARCHY_PATH/config/hypr"
printf 'default input\n' > "$OMARCHY_PATH/config/hypr/input.lua"
printf 'my own input\n'  > "$HOME/.config/hypr/input.lua"
printf 'init.lua body\n' > "$HOME/.config/nvim/init.lua"
printf 'notes body\n'    > "$HOME/.config/notes.conf"
printf 'FIRST=state-fixture-alpha\n' > "$HOME/.config/environment.d/60-secrets.conf"
printf '{"id":"io.example.demoifact","name":"Demoifact"}\n' \
  > "$HOME/.config/omarchy/plugins/demoifact/manifest.json"
printf '{"enabled":true}\n' > "$HOME/.config/omarchy/demoifact.json"

# Pin version 1: a repo with history keeps what it has, so initializing git
# before the first backup means no v2 skeleton is ever written.
mkdir -p "$OMARCHY_REPLICANT_HOME/repo"
git -C "$OMARCHY_REPLICANT_HOME/repo" init -q -b main 2>/dev/null

# shellcheck source=/dev/null
source "$CORE" 2>/dev/null
set +e +u

field() { registry_field "$2" "$1"; }

section "a shipped entry resolves all eight fields"
core_backup >/dev/null 2>&1
check_true "the registry builds on v1" registry_build
row=$(registry_row_for hypr/input.lua)
check "kind" "config" "$(field 2 "$row")"
check "source" "manifest" "$(field 3 "$row")"
check "category" "hyprland" "$(field 4 "$row")"
check "scope" "shared" "$(field 5 "$row")"
check "live path" "$HOME/.config/hypr/input.lua" "$(field 6 "$row")"
check "repo path" "$CONFIG_DIR/hypr/input.lua" "$(field 7 "$row")"
check "no blob on v1" "" "$(field 8 "$row")"
check "not locked on v1" "false" "$(field 9 "$row")"
check "a directory entry is a dir" "dir" \
  "$(field 2 "$(registry_row_for nvim/)")"
check "a shipped secret is a secret" "secret" \
  "$(field 2 "$(registry_row_for env/60-secrets.conf)")"
check "…kept as plaintext on v1" "$SECRETS_DIR/env/60-secrets.conf" \
  "$(field 7 "$(registry_row_for env/60-secrets.conf)")"

section "user entries win over auto-discovered ones"
core_track "$HOME/.config/notes.conf" >/dev/null 2>&1
registry_build >/dev/null 2>&1
check "a tracked file reads user" "user" \
  "$(field 3 "$(registry_row_for notes.conf)")"
check "a found plugin config reads auto" "auto" \
  "$(field 3 "$(registry_row_for plugins/demoifact.json)")"
printf '%s = plugins/demoifact.json\n' "$HOME/.config/omarchy/demoifact.json" >> "$USER_TRACK_FILE"
load_user_manifest
registry_build >/dev/null 2>&1
check "one row for the contested id" "1" \
  "$(printf '%s\n' "${REGISTRY[@]}" | grep -c '^plugins/demoifact.json'$'\t' || true)"
check "…and it is the user's" "user" \
  "$(field 3 "$(registry_row_for plugins/demoifact.json)")"
# The contested line was only for the precedence check: drop it again so the
# parity below compares the natural tracked lists.
sed -i '\|plugins/demoifact.json|d' "$USER_TRACK_FILE"
load_user_manifest
registry_build >/dev/null 2>&1
check "the contest leaves one auto row" "auto" \
  "$(field 3 "$(registry_row_for plugins/demoifact.json)")"

section "every row is known, sorted and unique"
check "sources are one of four words" "0" \
  "$(printf '%s\n' "${REGISTRY[@]}" | awk -F'\t' '$3 != "manifest" && $3 != "user" && $3 != "auto" && $3 != "override"' | grep -c . || true)"
check "ids arrive sorted" "$(printf '%s\n' "${REGISTRY[@]}" | cut -f1)" \
  "$(printf '%s\n' "${REGISTRY[@]}" | cut -f1 | LC_ALL=C sort)"
check "no id twice" "$(printf '%s\n' "${REGISTRY[@]}" | cut -f1 | wc -l)" \
  "$(printf '%s\n' "${REGISTRY[@]}" | cut -f1 | sort -u | wc -l)"

section "parity: v1 holds exactly the shipped and tracked entries"
pairs_now=$(printf '%s\n' "${REGISTRY[@]}" | awk -F'\t' '{print $6 ":" $1}' | LC_ALL=C sort)
pairs_then=$(printf '%s\n' "${TRACKED[@]}" "${TRACKED_SECRETS[@]}" | LC_ALL=C sort)
check "registry pairs match TRACKED pairs" "$pairs_then" "$pairs_now"

section "a v2 override record wins over the shipped entry"
ensure_v2_layout >/dev/null 2>&1
check "the repo is version 2 now" "2" "$(repo_data_version)"
cat > "$REPO_DIR/.replicant/entries.json" <<EOF
{"hypr/input.lua": {"path": "$HOME/.config/hypr/input.lua", "kind": "config", "scope": "profile", "source": "override"}}
EOF
registry_build >/dev/null 2>&1
row=$(registry_row_for hypr/input.lua)
check "source reads override" "override" "$(field 3 "$row")"
check "scope reads profile" "profile" "$(field 5 "$row")"
check "repo path moves to the profile tree" \
  "$REPO_DIR/profiles/$(current_profile)/config/hypr/input.lua" "$(field 7 "$row")"
printf '{}\n' > "$REPO_DIR/.replicant/entries.json"
registry_build >/dev/null 2>&1
check "an empty registry falls back to shipped" "manifest" \
  "$(field 3 "$(registry_row_for hypr/input.lua)")"
printf '{oops' > "$REPO_DIR/.replicant/entries.json"
check_false "an invalid registry fails loudly" registry_build
printf '{}\n' > "$REPO_DIR/.replicant/entries.json"

section "vault secrets resolve to blobs, or to locked"
if command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1 \
    && probe=$(mktemp -d) && ( umask 077; age-keygen -pq -o "$probe/key" >/dev/null 2>&1 ) \
    && grep -q '^# public key: age1pq1' "$probe/key" 2>/dev/null; then
  rm -rf -- "$probe"
  key_init >/dev/null 2>&1
  core_backup >/dev/null 2>&1
  registry_build >/dev/null 2>&1
  row=$(registry_row_for env/60-secrets.conf)
  check "the blob id is opaque" "0" \
    "$(field 8 "$row" | grep -cvE '^[0-9a-f]{32}$' || true)"
  check "…pointing at the vault file" "vault/blobs/$(field 8 "$row").age" \
    "$(field 7 "$row" | sed "s|^$REPO_DIR/||")"
  check "…unlocked with the key" "false" "$(field 9 "$row")"
  mv "$REPLICANT_HOME/keys/identity.txt" "$TMP/identity.keep"
  registry_build >/dev/null 2>&1
  row=$(registry_row_for env/60-secrets.conf)
  check "no key means locked" "true" "$(field 9 "$row")"
  check "…with no blob to point at" "" "$(field 8 "$row")"
  mv "$TMP/identity.keep" "$REPLICANT_HOME/keys/identity.txt"
else
  rm -rf -- "${probe:-/nonexistent}" 2>/dev/null || true
  registry_build >/dev/null 2>&1
  check "no key means locked" "true" \
    "$(field 9 "$(registry_row_for env/60-secrets.conf)")"
fi

section "one evaluator answers every row"
# A committed base, so git answers clean and the healing below shows: without
# it every copied file reads dirty, which is correct but buries the point.
core_backup >/dev/null 2>&1
git -C "$REPO_DIR" add -A >/dev/null 2>&1
git -C "$REPO_DIR" commit -qm "unit base" >/dev/null 2>&1 || true
registry_build >/dev/null 2>&1
verdict() { registry_build >/dev/null 2>&1; invalidate_git_cache; state_verdict "$(registry_row_for "$1")"; }
check "an edited file is unsaved" "unsaved false true true false" \
  "$(printf 'changed\n' >> "$HOME/.config/hypr/input.lua"; verdict hypr/input.lua)"
check "…and an exact revert heals it" "unpushed false false true false" \
  "$(printf 'my own input\n' > "$HOME/.config/hypr/input.lua"; verdict hypr/input.lua)"
check "a file inside a tree marks the tree" "unsaved false true true false" \
  "$(printf 'extra\n' > "$HOME/.config/nvim/extra.lua"; verdict nvim/)"
check "…and removing it heals the tree" "unpushed false false true false" \
  "$(rm -f "$HOME/.config/nvim/extra.lua"; verdict nvim/)"
record_incoming hypr/input.lua
check "incoming outranks unsaved" "incoming false true true true" \
  "$(printf 'changed\n' >> "$HOME/.config/hypr/input.lua"; verdict hypr/input.lua)"
record_incoming
check "clearing the mark gives unsaved back" "unsaved false true true false" \
  "$(verdict hypr/input.lua)"
printf 'my own input\n' > "$HOME/.config/hypr/input.lua"
cp "$HOME/.config/notes.conf" "$TMP/notes.keep"
rm -f "$HOME/.config/notes.conf"
check "a deleted file is missing, not unsaved" "missing false false true false" \
  "$(verdict notes.conf)"
check "brief counts the missing file" "1" \
  "$(core_status --json --brief --no-fetch 2>/dev/null | jq -r .missing)"
check "brief asks for action" "true" \
  "$(core_status --json --brief --no-fetch 2>/dev/null | jq -r .needs_action)"
cp "$TMP/notes.keep" "$HOME/.config/notes.conf"
check "brief drops the missing count" "0" \
  "$(core_status --json --brief --no-fetch 2>/dev/null | jq -r .missing)"
printf 'default input\n' > "$HOME/.config/hypr/input.lua"
core_backup >/dev/null 2>&1
git -C "$REPO_DIR" add -A >/dev/null 2>&1
git -C "$REPO_DIR" commit -qm "back to default" >/dev/null 2>&1 || true
check "a file at its Omarchy default reads default" "default false false true false" \
  "$(verdict hypr/input.lua)"

section "parity: the same world dumps the committed fixtures"
for world in v1 v2; do
  parity_out="$TMP/parity-$world"
  bash "$HERE/parity-dump.sh" "$world" "$parity_out" >/dev/null 2>&1
  for f in "$HERE/fixtures/state-parity/$world"/*; do
    base=$(basename "$f")
    if diff -u "$f" "$parity_out/$base" >/dev/null 2>&1; then
      pass=$((pass+1)); printf '  \033[32m✓\033[0m %s %s matches\n' "$world" "$base"
    else
      fail=$((fail+1)); printf '  \033[31m✗\033[0m %s %s differs\n' "$world" "$base"
      diff -u "$f" "$parity_out/$base" 2>/dev/null | head -n 10 | sed 's/^/    /'
    fi
  done
done

section "brief cache: metadata hit, byte-accurate full"
# The bar polls brief once a minute; full stays authoritative and never reads
# the cache. A content change that preserves size and mtime still hits the
# brief cache (the documented limit) while full compares bytes and sees it.
rm -f "$OMARCHY_REPLICANT_HOME/cache/state-v2.json" 2>/dev/null || true
core_status --json --brief --no-fetch >/dev/null 2>&1
check "the first brief writes the cache" "true" \
  "$([[ -f "$OMARCHY_REPLICANT_HOME/cache/state-v2.json" ]] && echo true || echo false)"
check "the cache declares version 2" "2" \
  "$(jq -r .version "$OMARCHY_REPLICANT_HOME/cache/state-v2.json" 2>/dev/null)"
brief_u1=$(core_status --json --brief --no-fetch 2>/dev/null | jq -r .unsaved)
brief_u2=$(core_status --json --brief --no-fetch 2>/dev/null | jq -r .unsaved)
check "a repeated brief agrees with itself" "$brief_u1" "$brief_u2"
printf 'cache check line\n' >> "$HOME/.config/hypr/input.lua"
check "an edit misses the cache" "1" \
  "$(core_status --json --brief --no-fetch 2>/dev/null | jq -r .unsaved)"
printf 'default input\n' > "$HOME/.config/hypr/input.lua"
core_status --json --brief --no-fetch >/dev/null 2>&1
oldmt=$(stat -c %Y "$HOME/.config/hypr/input.lua")
printf 'default inpuX\n' > "$HOME/.config/hypr/input.lua"
touch -d "@$oldmt" "$HOME/.config/hypr/input.lua"
check "brief hits stale on a timestamp-preserving edit" "0" \
  "$(core_status --json --brief --no-fetch 2>/dev/null | jq -r .unsaved)"
check "full still detects the timestamp-preserving edit" "1" \
  "$(core_status --json --no-fetch 2>/dev/null | jq -r .unsaved)"
check "the direct count stays authoritative too" "1 0 0 0" \
  "$(count_changes 2>/dev/null)"
printf 'default input\n' > "$HOME/.config/hypr/input.lua"
touch "$HOME/.config/hypr/input.lua"
check "a mtime change misses again" "0" \
  "$(core_status --json --brief --no-fetch 2>/dev/null | jq -r .unsaved)"
check "the cache holds no secret plaintext" "" \
  "$(grep -o 'state-fixture-alpha' "$OMARCHY_REPLICANT_HOME/cache/state-v2.json" 2>/dev/null || true)"
check "…and no secret variable assignment either" "" \
  "$(grep -o 'FIRST=' "$OMARCHY_REPLICANT_HOME/cache/state-v2.json" 2>/dev/null || true)"
printf 'oops' > "$OMARCHY_REPLICANT_HOME/cache/state-v2.json"
check "a corrupt cache falls back to a correct brief" "0" \
  "$(core_status --json --brief --no-fetch 2>/dev/null | jq -r .unsaved)"
check "…and heals the cache file" "2" \
  "$(jq -r .version "$OMARCHY_REPLICANT_HOME/cache/state-v2.json" 2>/dev/null)"
core_backup >/dev/null 2>&1
check "a save invalidates the cache" "false" \
  "$([[ -f "$OMARCHY_REPLICANT_HOME/cache/state-v2.json" ]] && echo true || echo false)"
core_status --json --brief --no-fetch >/dev/null 2>&1
record_incoming hypr/input.lua
check "an incoming record invalidates the cache" "false" \
  "$([[ -f "$OMARCHY_REPLICANT_HOME/cache/state-v2.json" ]] && echo true || echo false)"
record_incoming

summary
