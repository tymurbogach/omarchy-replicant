#!/bin/bash
# Deterministic fixture world plus normalized state dumps for parity testing.
# The committed files under tests/fixtures/state-parity/ come from this script:
# after a refactor, the suite rebuilds the same world and diffs against them.
#
# Usage: parity-dump.sh <world> <outdir>
#   world: v1 (plaintext secrets) or v2 (vault; needs age with -pq)
# Everything runs against a throwaway $HOME. PATH must carry the test stubs
# and GIT_CONFIG_GLOBAL a test identity (tests/lib.sh provides both).
set -uo pipefail

WORLD="${1:-v2}"
OUT="$2"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CORE="$HERE/../bin/replicant-core.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export OMARCHY_PATH="$TMP/omarchy"
export OMARCHY_REPLICANT_HOME="$TMP/replicant"

mkdir -p "$HOME/.config/hypr" "$HOME/.config/nvim" \
  "$HOME/.config/environment.d" "$OMARCHY_PATH/config/hypr"
printf 'default input\n'  > "$OMARCHY_PATH/config/hypr/input.lua"
printf 'lock conf\n'      > "$OMARCHY_PATH/config/hypr/hyprlock.conf"
printf 'live input v1\n'  > "$HOME/.config/hypr/input.lua"
printf 'land base\n'      > "$HOME/.config/hypr/hyprland.lua"
printf 'lock conf\n'      > "$HOME/.config/hypr/hyprlock.conf"
printf 'autostart\n'      > "$HOME/.config/hypr/autostart.lua"
printf 'monitors\n'       > "$HOME/.config/hypr/monitors.lua"
printf 'xdph\n'           > "$HOME/.config/hypr/xdph.conf"
printf 'init.lua body\n'  > "$HOME/.config/nvim/init.lua"
printf 'K=parity-base\n'  > "$HOME/.config/environment.d/60-secrets.conf"

# A v1 world keeps its history: initializing git before the first backup means
# no v2 skeleton is ever written. A v2 world is born fresh.
if [[ "$WORLD" == v1 ]]; then
  mkdir -p "$OMARCHY_REPLICANT_HOME/repo"
  git -C "$OMARCHY_REPLICANT_HOME/repo" init -q -b main 2>/dev/null
fi

# shellcheck source=/dev/null
source "$CORE" 2>/dev/null
set +e +u

git_init_remote() {
  git init -q --bare -b main "$TMP/remote.git" 2>/dev/null
  git -C "$REPO_DIR" remote add origin "$TMP/remote.git" 2>/dev/null
  git -C "$REPO_DIR" push -q -u origin main 2>/dev/null
}

# No legacy seeding: the seed pass copies whatever this host happens to have
# (a fingerprint unit under /etc exists here and not in CI), so the track file
# is pre-created empty and the world is identical on every machine.
mkdir -p "$REPO_DIR"
printf '# empty on purpose: no legacy seed, no user entries\n' > "$REPO_DIR/.replicant-track"
load_user_manifest

# Before any copy: profile-scoped files land under this profile's tree, and
# the profile must not depend on which chassis the test runs on.
core_profile_set desktop >/dev/null 2>&1

core_backup >/dev/null 2>&1
git -C "$REPO_DIR" add -A >/dev/null 2>&1
git -C "$REPO_DIR" commit -qm base >/dev/null 2>&1
git_init_remote
if [[ "$WORLD" == v2 ]]; then
  key_init >/dev/null 2>&1
  core_backup >/dev/null 2>&1
  git -C "$REPO_DIR" add -A >/dev/null 2>&1
  git -C "$REPO_DIR" commit -qm vault >/dev/null 2>&1
  git -C "$REPO_DIR" push -q origin main 2>/dev/null
fi

# The states under test: one edited file, one edited tree, one incoming file,
# one switched-off file, one deleted file, one file at its Omarchy default,
# one changed secret, the rest saved.
printf 'live input v2\n' > "$HOME/.config/hypr/input.lua"
printf 'extra module\n'  > "$HOME/.config/nvim/extra.lua"
printf 'land from laptop\n' > "$HOME/.config/hypr/hyprland.lua"
record_incoming hypr/hyprland.lua
core_scope hypr/xdph.conf off >/dev/null 2>&1
rm -f "$HOME/.config/hypr/autostart.lua"
printf 'K=parity-changed\n' > "$HOME/.config/environment.d/60-secrets.conf"
git -C "$REPO_DIR" add -A >/dev/null 2>&1
git -C "$REPO_DIR" commit -qm states >/dev/null 2>&1

mkdir -p "$OUT"
norm_json() {
  jq --arg tmp "$TMP" --arg m "$MACHINE" '
    walk(if type == "string"
         then gsub($tmp; "@TMP@") | gsub($m; "@MACHINE@")
         else . end)' 2>/dev/null
}
norm_text() {
  sed -e "s|$TMP|@TMP@|g" -e "s|$MACHINE|@MACHINE@|g"
}

build_configs_json | norm_json > "$OUT/configs.json"
build_secrets_json | norm_json > "$OUT/secrets.json"
core_status --json --brief --no-fetch 2>/dev/null | norm_json > "$OUT/brief.json"
count_changes 2>/dev/null | norm_text > "$OUT/counts.txt"
for cat in "${CATEGORY_ORDER[@]}" secrets; do
  plan_for_category "$cat" 2>/dev/null
done | norm_text | LC_ALL=C sort > "$OUT/plans.txt"
core_diff hypr/input.lua repo 2>&1 | norm_text > "$OUT/diff-input.txt"
core_diff env/60-secrets.conf 2>&1 | norm_text > "$OUT/diff-secret.txt"
core_diff nvim/ 2>&1 | norm_text > "$OUT/diff-tree.txt"

# Without the key the vault cannot be compared: same world, locked verdicts.
if [[ "$WORLD" == v2 ]]; then
  mv "$REPLICANT_HOME/keys/identity.txt" "$TMP/identity.keep"
  build_secrets_json | norm_json > "$OUT/secrets-keyless.json"
  core_status --json --brief --no-fetch 2>/dev/null | norm_json > "$OUT/brief-keyless.json"
  count_changes 2>/dev/null | norm_text > "$OUT/counts-keyless.txt"
  mv "$TMP/identity.keep" "$REPLICANT_HOME/keys/identity.txt"
fi
