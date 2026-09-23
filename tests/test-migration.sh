#!/bin/bash
# Migration tests use a local bare remote. They never contact GitHub.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CORE="$HERE/../bin/replicant-core.sh"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export OMARCHY_PATH="$TMP/omarchy"
export OMARCHY_REPLICANT_HOME="$TMP/replicant"
mkdir -p "$HOME/.config/hypr" "$HOME/.config/environment.d" "$OMARCHY_PATH/config/hypr"
printf 'default\n' > "$OMARCHY_PATH/config/hypr/input.lua"
printf 'custom\n' > "$HOME/.config/hypr/input.lua"
printf 'TOKEN=migration-fixture\n' > "$HOME/.config/environment.d/60-secrets.conf"
mkdir -p "$OMARCHY_REPLICANT_HOME/repo"
git -C "$OMARCHY_REPLICANT_HOME/repo" init -q -b main
# shellcheck source=/dev/null
source "$CORE" 2>/dev/null
set +e +u

section "preflight keeps the v1 repository on failure"
core_backup >/dev/null 2>&1
git -C "$REPO_DIR" add -A >/dev/null 2>&1
git -C "$REPO_DIR" commit -qm legacy >/dev/null 2>&1
printf 'changed after commit\n' >> "$HOME/.config/hypr/input.lua"
# Make the repository itself dirty. Live configuration changes are valid input
# to migration, but an unfinished repository edit is not.
printf 'unfinished\n' >> "$REPO_DIR/.replicant-track"
remote="$TMP/remote-dirty.git"
git init --bare -q -b main "$remote"
check_false "dirty source is rejected" core_migrate_v2 --remote "$remote" --identity-backup "$TMP/identity" --yes
check "no legacy rename happened" "0" \
  "$(find "$REPLICANT_HOME" -maxdepth 1 -type d -name 'legacy-repo-*' | wc -l)"
check_false "the v1 schema is still absent" test -e "$REPO_DIR/.replicant/schema.json"
printf 'custom\n' > "$HOME/.config/hypr/input.lua"
git -C "$REPO_DIR" checkout -- .replicant-track

section "successful migration creates one clean encrypted repository"
backup="$TMP/identity.backup"
core_migrate_v2 --remote "$remote" --identity-backup "$backup" --yes
migration_rc=$?
check "migration succeeds against an empty local remote" "0" "$migration_rc"
check "the active repository is v2" "2" "$(jq -r .dataVersion "$REPO_DIR/.replicant/schema.json" 2>/dev/null)"
check_true "the external identity backup exists" test -f "$backup"
check "the identity backup is private" "600" "$(stat -c '%a' "$backup" 2>/dev/null)"
check_true "the legacy repository is retained" test -f "$REPLICANT_HOME/migration-warning"
check_true "the active repository has one root commit" \
  test "$(git -C "$REPO_DIR" rev-list --max-parents=0 HEAD | wc -l)" = 1
check "the legacy metadata is absent from the new tree" "0" \
  "$(git -C "$REPO_DIR" ls-tree -r --name-only HEAD | grep -cE '(^|/)(\.replicant-track|secrets/)' || true)"
check "the secret plaintext is absent from the new tree" "0" \
  "$(git -C "$REPO_DIR" grep -Il 'TOKEN=migration-fixture' HEAD -- 2>/dev/null | wc -l)"
check_true "the remote has one root commit" \
  test "$(git --git-dir="$remote" rev-list --max-parents=0 main | wc -l)" = 1
check "the remote has no legacy paths" "0" \
  "$(git --git-dir="$remote" ls-tree -r --name-only main | grep -cE '(^|/)(\.replicant-track|secrets/)' || true)"
check "the remote has no unreachable objects" "" \
  "$(git --git-dir="$remote" fsck --full --no-reflogs --unreachable 2>/dev/null || true)"
check_true "the new identity matches the repository recipient" \
  test "$(age-keygen -y "$REPLICANT_HOME/keys/identity.txt" 2>/dev/null)" = "$(tr -d '[:space:]' < "$REPO_DIR/.replicant/recipient.txt")"

section "full status publishes the v2 contract"
full_status=$(bash "$CORE" status --json --no-fetch 2>/dev/null)
check "status schema version" "2" "$(jq -r .schema_version <<<"$full_status")"
check "migration is complete" "false" "$(jq -r .migration.required <<<"$full_status")"
check "legacy cleanup warning remains" "true" "$(jq -r .migration.legacy_warning <<<"$full_status")"
check "encryption is ready" "ready" "$(jq -r .encryption.state <<<"$full_status")"
check_true "the unified entry list is present" jq -e '.entries | length > 0' <<<"$full_status"
check_true "config entries expose the contract fields" \
  jq -e '.entries[] | select(.kind == "config") | has("id") and has("scope") and has("sync_state")' <<<"$full_status"
mv "$REPLICANT_HOME/keys/identity.txt" "$TMP/identity.locked"
locked_status=$(bash "$CORE" status --json --no-fetch 2>/dev/null)
check "locked secret status" "locked" \
  "$(jq -r '[.entries[] | select(.kind == "secret" and .exists == true)][0].sync_state' <<<"$locked_status")"
check "locked secret omits live path" "0" \
  "$(jq -r '[.entries[] | select(.kind == "secret" and .exists == true)][0] | has("src") | if . then 1 else 0 end' <<<"$locked_status")"
mv "$TMP/identity.locked" "$REPLICANT_HOME/keys/identity.txt"

summary
