#!/bin/bash
# migrate-v3: atomic v1 and v2 migration to the v3 schema. Every case runs
# against a fake $HOME, local bare remotes, and a stubbed gh: nothing here
# reaches the network. A failed migration leaves the active repository and
# the local identity exactly as they were, with a recovery journal behind.
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
printf 'my own input\n' > "$HOME/.config/hypr/input.lua"
printf 'SHIPPED=v3migrate-shipped\n' > "$HOME/.config/environment.d/60-secrets.conf"
printf 'notes-body-custom\n' > "$HOME/.config/notes-private.conf"
printf 'scope-body\n' > "$HOME/.config/scope-me.conf"

# shellcheck source=/dev/null
source "$CORE" 2>/dev/null
set +e +u

# Never touch the real machine: every git command below targets REPO_DIR, and
# `git -C ""` falls back to the current directory. A failed source once
# committed a test fixture into the plugin checkout itself — abort instead.
command -v core_migrate_v3 >/dev/null 2>&1 || { echo "test aborted: the core did not load" >&2; exit 1; }
case "$REPO_DIR" in
  "$TMP/"*) ;;
  *) echo "test aborted: REPO_DIR ($REPO_DIR) is not under the test tmp" >&2; exit 1 ;;
esac

reset_world() {
  rm -rf -- "$REPO_DIR" "$REPLICANT_HOME/keys" "$REPLICANT_HOME/migration" \
    "$REPLICANT_HOME"/legacy-repo-* "$REPLICANT_HOME/migration-warning"
  mkdir -p "$REPO_DIR"
  git -C "$REPO_DIR" init -q -b main 2>/dev/null
}

head_of() { git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true; }

no_legacy_rename() {
  [[ -z "$(find "$REPLICANT_HOME" -maxdepth 1 -type d -name 'legacy-repo-*' 2>/dev/null)" ]]
}

# build_v1: a representative legacy repository through the real writers:
# a shipped secret, a custom secret absent from every manifest, shared,
# profile and off scopes, a recorded profile, two recorded machines, and
# one retired inventory that must not survive migration.
build_v1() {
  reset_world
  core_backup >/dev/null 2>&1
  core_track "$HOME/.config/notes-private.conf" --secret >/dev/null 2>&1
  core_track "$HOME/.config/scope-me.conf" >/dev/null 2>&1
  core_scope scope-me.conf profile >/dev/null 2>&1
  core_scope hypr/input.lua off >/dev/null 2>&1
  core_profile_set laptop >/dev/null 2>&1
  core_backup >/dev/null 2>&1
  mkdir -p "$REPO_DIR/state/m2"
  printf 'second-machine-plugins\n' > "$REPO_DIR/state/m2/omarchy-plugins.txt"
  printf 'second-machine-themes\n' > "$REPO_DIR/state/m2/omarchy-themes.txt"
  printf 'retired-inventory\n' > "$REPO_DIR/state/$MACHINE/defined-secrets.txt"
  git -C "$REPO_DIR" add -A >/dev/null 2>&1
  git -C "$REPO_DIR" commit -qm "legacy v1" >/dev/null 2>&1
}

# track_upstream <remote>: point the fresh fixture at a bare remote and prove
# synchronization, the way a real pre-migration machine looks.
track_upstream() {
  git -C "$REPO_DIR" remote add origin "$1" 2>/dev/null
  git -C "$REPO_DIR" push -q -u origin main 2>/dev/null
}

# build_v2: a hand-built current v2 layout: schema marker, entries, one
# machine record plus a second machine, and a version 1 vault whose blobs
# decrypt with the test identity installed beside it.
build_v2() {
  local idf="$TMP/v2ident" recipient rid
  reset_world
  mkdir -p "$REPO_DIR/.replicant/machines" "$REPO_DIR/vault/blobs" \
    "$REPO_DIR/config/hypr" "$REPO_DIR/state/$MACHINE" "$REPO_DIR/templates"
  printf 'my own input\n' > "$REPO_DIR/config/hypr/input.lua"
  printf 'v2-plugins\n' > "$REPO_DIR/state/$MACHINE/omarchy-plugins.txt"
  jq -nc '{dataVersion: 2, secretFormat: "age-pq-v1"}' > "$REPO_DIR/.replicant/schema.json"
  jq -nc --arg p "$HOME/.config/hypr/input.lua" \
    '{"hypr/input.lua": {path: $p, kind: "config", scope: "shared", source: "override"}}' \
    > "$REPO_DIR/.replicant/entries.json"
  jq -nc --arg m "$MACHINE" \
    '{clientVersion: "test", machineId: $m, profile: "laptop", schemaVersion: 2}' \
    > "$REPO_DIR/.replicant/machines/$MACHINE.json"
  jq -nc '{clientVersion: "test", machineId: "m2", profile: "desktop", schemaVersion: 2}' \
    > "$REPO_DIR/.replicant/machines/m2.json"
  rm -f -- "$idf"
  ( umask 077; age-keygen -pq -o "$idf" >/dev/null 2>&1 ) || return 1
  recipient=$(age-keygen -y "$idf" 2>/dev/null || true)
  printf '%s\n' "$recipient" > "$REPO_DIR/.replicant/recipient.txt"
  rid=$(od -An -N16 -tx1 /dev/urandom | tr -d '[:space:]')
  age -r "$recipient" -o "$REPO_DIR/vault/blobs/$rid.age" \
    "$HOME/.config/environment.d/60-secrets.conf" 2>/dev/null || return 1
  jq -nc --arg blob "$rid" \
    '{version: 1, secrets: [{id: "env/60-secrets.conf", scope: "shared", blob: $blob}]}' > "$TMP/v2index.json"
  age -r "$recipient" -o "$REPO_DIR/vault/index.age" "$TMP/v2index.json" 2>/dev/null || return 1
  rm -f -- "$TMP/v2index.json"
  mkdir -p "$REPLICANT_HOME/keys"
  install -m 600 "$idf" "$REPLICANT_HOME/keys/identity.txt"
  git -C "$REPO_DIR" add -A >/dev/null 2>&1
  git -C "$REPO_DIR" commit -qm "legacy v2" >/dev/null 2>&1
}

empty_remote() {
  local r="$1"
  git init --bare -q -b main "$r" 2>/dev/null
}

section "legacy repositories require migration"
build_v1
check "a v1 repository requires migration" "true" "$(status_migration_json | jq -r .required)"
build_v2
check "a v2 repository requires migration" "true" "$(status_migration_json | jq -r .required)"

section "the summary prints before --yes and changes nothing"
build_v1
remote="$TMP/remote-summary.git"; empty_remote "$remote"
before=$(head_of)
out=$(core_migrate_v3 --remote "$remote" --identity-backup "$TMP/summary-backup" 2>&1); rc=$?
check "migration without --yes fails" "1" "$(if (( rc != 0 )); then echo 1; else echo 0; fi)"
check_contains "…listing every recorded machine" "$MACHINE" "$out"
check_contains "…and the second machine" "m2" "$out"
check_contains "…asking for acknowledgement" "--yes" "$out"
check "…leaving HEAD untouched" "$before" "$(head_of)"
check_false "…writing no schema marker" test -e "$REPO_DIR/.replicant/schema.json"
check_true "…renaming nothing to legacy" no_legacy_rename
check_false "…writing no identity backup" test -e "$TMP/summary-backup"

section "a representative v1 repository migrates to v3"
build_v1
upstream="$TMP/up-v1.git"; empty_remote "$upstream"
track_upstream "$upstream"
remote="$TMP/remote-v1.git"; empty_remote "$remote"
backup="$TMP/v1.backup"
core_migrate_v3 --remote "$remote" --identity-backup "$backup" --yes >/dev/null 2>&1
check "migration succeeds" "0" "$?"
check "the active repository is v3" "3" "$(jq -r .dataVersion "$REPO_DIR/.replicant/schema.json" 2>/dev/null)"
check "…with the v2 secret format" "age-pq-v2" "$(jq -r .secretFormat "$REPO_DIR/.replicant/schema.json" 2>/dev/null)"
idx="$(vault_index_decrypt 2>/dev/null)"
check "the vault index is version 2" "2" "$(jq -r .version <<<"$idx" 2>/dev/null)"
check "…recording the custom secret path" "$HOME/.config/notes-private.conf" \
  "$(jq -r '.secrets[] | select(.id == "notes-private.conf") | .path' <<<"$idx" 2>/dev/null)"
check "…recording its user source" "user" \
  "$(jq -r '.secrets[] | select(.id == "notes-private.conf") | .source' <<<"$idx" 2>/dev/null)"
check "…recording the shipped secret path" "$HOME/.config/environment.d/60-secrets.conf" \
  "$(jq -r '.secrets[] | select(.id == "env/60-secrets.conf") | .path' <<<"$idx" 2>/dev/null)"
check "the profile scope survives" "profile" \
  "$(jq -r '."scope-me.conf".scope' "$REPO_DIR/.replicant/entries.json" 2>/dev/null)"
check "…and the off scope survives" "off" \
  "$(jq -r '."hypr/input.lua".scope' "$REPO_DIR/.replicant/entries.json" 2>/dev/null)"
check "the profile lives in the machine record" "laptop" \
  "$(jq -r .profile "$REPO_DIR/.replicant/machines/$MACHINE.json" 2>/dev/null)"
check "…at schema version 3" "3" \
  "$(jq -r .schemaVersion "$REPO_DIR/.replicant/machines/$MACHINE.json" 2>/dev/null)"
check_true "both machines keep their state" test -f "$REPO_DIR/state/m2/omarchy-plugins.txt"
check_false "the retired inventory is gone" test -f "$REPO_DIR/state/$MACHINE/defined-secrets.txt"
check "the new tree has one root commit" "1" \
  "$(git -C "$REPO_DIR" rev-list --max-parents=0 HEAD 2>/dev/null | wc -l)"
check "no legacy policy file survives" "0" \
  "$(git -C "$REPO_DIR" ls-tree -r --name-only HEAD | grep -cE '(^|/)(\.replicant-track|\.replicant-sync|\.replicant-profiles|\.replicant-exclude|secrets/)' || true)"
check "no secret plaintext survives" "0" \
  "$(git -C "$REPO_DIR" grep -Il 'notes-body-custom' HEAD -- 2>/dev/null | wc -l)"
check_true "the identity backup exists" test -f "$backup"
check "…and is private" "600" "$(stat -c '%a' "$backup" 2>/dev/null)"
check_true "the new identity matches the recipient" \
  test "$(age-keygen -y "$REPLICANT_HOME/keys/identity.txt" 2>/dev/null)" = "$(tr -d '[:space:]' < "$REPO_DIR/.replicant/recipient.txt")"
check_true "the recovery journal is gone after success" \
  test -z "$(find "$REPLICANT_HOME/migration" -name journal.json 2>/dev/null)"
check "migration is complete" "false" "$(status_migration_json | jq -r .required)"
check "legacy cleanup warning remains" "true" "$(status_migration_json | jq -r .legacy_warning)"

section "the current v2 layout migrates with re-encrypted secrets"
build_v2
old_key="$(cat "$REPLICANT_HOME/keys/identity.txt")"
upstream="$TMP/up-v2.git"; empty_remote "$upstream"
track_upstream "$upstream"
remote="$TMP/remote-v2.git"; empty_remote "$remote"
backup="$TMP/v2.backup"
core_migrate_v3 --remote "$remote" --identity-backup "$backup" --yes >/dev/null 2>&1
check "migration succeeds" "0" "$?"
check "the active repository is v3" "3" "$(jq -r .dataVersion "$REPO_DIR/.replicant/schema.json" 2>/dev/null)"
idx="$(vault_index_decrypt 2>/dev/null)"
check "the vault index is version 2" "2" "$(jq -r .version <<<"$idx" 2>/dev/null)"
check "…recording the secret path" "$HOME/.config/environment.d/60-secrets.conf" \
  "$(jq -r '.secrets[] | select(.id == "env/60-secrets.conf") | .path' <<<"$idx" 2>/dev/null)"
new_blob="$(jq -r '.secrets[] | select(.id == "env/60-secrets.conf") | .blob' <<<"$idx" 2>/dev/null)"
check "the re-encrypted secret decrypts to the original plaintext" \
  "$(cat "$HOME/.config/environment.d/60-secrets.conf")" \
  "$(age -d -i "$REPLICANT_HOME/keys/identity.txt" -o - "$REPO_DIR/vault/blobs/$new_blob.age" 2>/dev/null || true)"
check "the identity was rotated" "1" "$(if [[ "$old_key" != "$(cat "$REPLICANT_HOME/keys/identity.txt")" ]]; then echo 1; else echo 0; fi)"
check "both machine records survive" "desktop" \
  "$(jq -r .profile "$REPO_DIR/.replicant/machines/m2.json" 2>/dev/null)"
check "…at schema version 3" "3" \
  "$(jq -r .schemaVersion "$REPO_DIR/.replicant/machines/m2.json" 2>/dev/null)"

section "an unknown secret path refuses migration"
build_v1
printf 'secret %s = ghost-secret.conf\n' "$HOME/.config/ghost-secret.conf" >> "$REPO_DIR/.replicant-track"
git -C "$REPO_DIR" add -A >/dev/null 2>&1
git -C "$REPO_DIR" commit -qm "ghost" >/dev/null 2>&1
upstream="$TMP/up-ghost.git"; empty_remote "$upstream"
track_upstream "$upstream"
remote="$TMP/remote-ghost.git"; empty_remote "$remote"
before=$(head_of)
out=$(core_migrate_v3 --remote "$remote" --identity-backup "$TMP/ghost.backup" --yes 2>&1); rc=$?
check "migration fails on the unknown path" "1" "$(if (( rc != 0 )); then echo 1; else echo 0; fi)"
check_contains "…naming the secret" "ghost-secret.conf" "$out"
check "…leaving HEAD untouched" "$before" "$(head_of)"
check_true "…renaming nothing to legacy" no_legacy_rename
check_false "…writing no schema marker" test -e "$REPO_DIR/.replicant/schema.json"

section "dirty, unsynced and untracked states refuse migration"
build_v1
upstream="$TMP/up-states.git"; empty_remote "$upstream"
track_upstream "$upstream"
remote="$TMP/remote-states.git"; empty_remote "$remote"
printf 'unfinished\n' >> "$REPO_DIR/.replicant-track"
out=$(core_migrate_v3 --remote "$remote" --identity-backup "$TMP/dirty.backup" --yes 2>&1); rc=$?
check "a dirty repository is rejected" "1" "$(if (( rc != 0 )); then echo 1; else echo 0; fi)"
check_contains "…naming uncommitted changes" "uncommitted" "$out"
git -C "$REPO_DIR" checkout -- .replicant-track 2>/dev/null
git -C "$REPO_DIR" commit -q --allow-empty -m "ahead" 2>/dev/null
out=$(core_migrate_v3 --remote "$remote" --identity-backup "$TMP/ahead.backup" --yes 2>&1); rc=$?
check "an ahead repository is rejected" "1" "$(if (( rc != 0 )); then echo 1; else echo 0; fi)"
check_contains "…naming the ahead state" "ahead" "$out"
git -C "$REPO_DIR" reset -q --hard HEAD~1 2>/dev/null
clone2="$TMP/second"; git clone -q "$upstream" "$clone2" 2>/dev/null
git -C "$clone2" config user.name Tests 2>/dev/null
git -C "$clone2" config user.email tests@example.com 2>/dev/null
git -C "$clone2" commit -q --allow-empty -m "remote moves" 2>/dev/null
git -C "$clone2" push -q origin main 2>/dev/null
git -C "$REPO_DIR" fetch -q origin 2>/dev/null
out=$(core_migrate_v3 --remote "$remote" --identity-backup "$TMP/behind.backup" --yes 2>&1); rc=$?
check "a behind repository is rejected" "1" "$(if (( rc != 0 )); then echo 1; else echo 0; fi)"
check_contains "…naming the behind state" "behind" "$out"
git -C "$REPO_DIR" commit -q --allow-empty -m "local moves" 2>/dev/null
out=$(core_migrate_v3 --remote "$remote" --identity-backup "$TMP/divergent.backup" --yes 2>&1); rc=$?
check "a divergent repository is rejected" "1" "$(if (( rc != 0 )); then echo 1; else echo 0; fi)"
check_contains "…naming the divergence" "diverged" "$out"
check "…leaving HEAD untouched" "$(git -C "$REPO_DIR" rev-parse HEAD)" "$(head_of)"
check_true "…renaming nothing to legacy" no_legacy_rename
build_v1
remote="$TMP/remote-notracked.git"; empty_remote "$remote"
out=$(core_migrate_v3 --remote "$remote" --identity-backup "$TMP/notracked.backup" --yes 2>&1); rc=$?
check "a repository without upstream tracking is rejected" "1" "$(if (( rc != 0 )); then echo 1; else echo 0; fi)"
check_contains "…naming upstream tracking" "upstream" "$out"

section "injected failures keep the repository and the identity"
build_v1
upstream="$TMP/up-inject.git"; empty_remote "$upstream"
track_upstream "$upstream"
remote="$TMP/remote-inject.git"; empty_remote "$remote"
before=$(head_of)
for stage in encrypt commit push verify activate; do
  out=$(REPLICANT_FAIL_MIGRATION_AT="$stage" core_migrate_v3 --remote "$remote" --identity-backup "$TMP/fail-$stage.backup" --yes 2>&1); rc=$?
  check "injected failure before $stage fails" "1" "$(if (( rc != 0 )); then echo 1; else echo 0; fi)"
  check "…leaving HEAD untouched ($stage)" "$before" "$(head_of)"
  check_false "…installing no identity ($stage)" test -f "$REPLICANT_HOME/keys/identity.txt"
done
check_true "…renaming nothing to legacy" no_legacy_rename
check_true "…keeping a recovery journal" test -n "$(find "$REPLICANT_HOME/migration" -name journal.json 2>/dev/null)"
build_v2
old_key="$(cat "$REPLICANT_HOME/keys/identity.txt")"
upstream="$TMP/up-v2fail.git"; empty_remote "$upstream"
track_upstream "$upstream"
remote="$TMP/remote-v2fail.git"; empty_remote "$remote"
before=$(head_of)
out=$(REPLICANT_FAIL_MIGRATION_AT=activate core_migrate_v3 --remote "$remote" --identity-backup "$TMP/fail-v2.backup" --yes 2>&1); rc=$?
check "injected failure before v2 activation fails" "1" "$(if (( rc != 0 )); then echo 1; else echo 0; fi)"
check "…leaving HEAD untouched" "$before" "$(head_of)"
check "…restoring the original identity" "$old_key" "$(cat "$REPLICANT_HOME/keys/identity.txt" 2>/dev/null)"

section "legacy writes after migration are detected"
build_v1
upstream="$TMP/up-legacy.git"; empty_remote "$upstream"
track_upstream "$upstream"
remote="$TMP/remote-legacy.git"; empty_remote "$remote"
core_migrate_v3 --remote "$remote" --identity-backup "$TMP/legacy.backup" --yes >/dev/null 2>&1
printf 'hypr/input.lua = off\n' > "$REPO_DIR/.replicant-sync"
out=$(core_backup 2>&1); rc=$?
check "a legacy write blocks the writer" "1" "$(if (( rc != 0 )); then echo 1; else echo 0; fi)"
check_contains "…naming the legacy file" ".replicant-sync" "$out"
rm -f -- "$REPO_DIR/.replicant-sync"
printf 'scope-me.conf\n' > "$REPO_DIR/.replicant-track"
printf '%s = laptop\n' "$MACHINE" > "$REPO_DIR/.replicant-profiles"
check_false "…and other legacy files block it too" core_backup
rm -f -- "$REPO_DIR/.replicant-track" "$REPO_DIR/.replicant-profiles"
check "the repository is clean again" "" "$(git -C "$REPO_DIR" status --porcelain 2>/dev/null)"

summary
