#!/bin/bash
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../bin/omarchy-replicant"
CORE="$HERE/../bin/replicant-core.sh"
source "$HERE/lib.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" OMARCHY_PATH="$TMP/omarchy" OMARCHY_REPLICANT_HOME="$TMP/replicant"
mkdir -p "$HOME/.config/omarchy" "$HOME/.config/hypr" \
  "$HOME/.local/state/omarchy/current" "$OMARCHY_PATH/config/omarchy"
printf '{"idle":{"lock":600},"bar":{"position":"top"}}\n' > "$HOME/.config/omarchy/shell.json"
printf '{"idle":{"lock":300}}\n' > "$OMARCHY_PATH/config/omarchy/shell.json"
printf 'original input\n' > "$HOME/.config/hypr/input.lua"
printf 'tokyo-night\n' > "$HOME/.local/state/omarchy/current/theme.name"

check_true "initial repository setup succeeds" "$CLI" init
# shellcheck source=/dev/null
source "$CORE" 2>/dev/null
set +e +u
check "theme settings save their marker entry" "omarchy/theme.name" \
  "$(setting_save_id theme.current)"
check "theme repo value reads its saved marker" "tokyo-night" \
  "$(setting_repo_value theme.current)"
check_true "theme comparison normalizes the current name" \
  setting_value_saved theme.current "Tokyo Night"

section "a setting save failure names the exact retry"
printf 'unrelated live edit\n' > "$HOME/.config/hypr/input.lua"
printf 'not a directory\n' > "$REPLICANT_HOME/transactions"
set_out=$("$CLI" set idle.lock 900 2>&1); set_rc=$?
(( set_rc != 0 )) && t_ok "a blocked transaction reports failure" || t_bad "a blocked transaction reports failure"
check_contains "the setting says it changed but was not saved" \
  "changed on this machine but was not saved" "$set_out"
check_contains "the setting prints the owning-entry retry" \
  "omarchy-replicant save --id omarchy/shell.json -m" "$set_out"
check "the failed save leaves the repository value unchanged" "600" \
  "$(jq -r '.idle.lock' "$CONFIG_DIR/omarchy/shell.json")"
check "the failed save leaves unrelated copies unchanged" "original input" \
  "$(<"$CONFIG_DIR/hypr/input.lua")"

section "set saves only its owning entry"
rm -f "$REPLICANT_HOME/transactions"
check_true "setting set succeeds" "$CLI" set idle.lock 900
check "the setting value reaches the repository" "900" \
  "$(jq -r '.idle.lock' "$CONFIG_DIR/omarchy/shell.json")"
check "the unrelated live edit stays out of the repository" "original input" \
  "$(<"$CONFIG_DIR/hypr/input.lua")"
printf 'unrelated edit before revert\n' > "$HOME/.config/hypr/input.lua"
check_true "setting revert succeeds" "$CLI" revert idle.lock default
check "revert saves the owning entry" "300" \
  "$(jq -r '.idle.lock' "$CONFIG_DIR/omarchy/shell.json")"
check "revert leaves the unrelated repo copy unchanged" "original input" \
  "$(<"$CONFIG_DIR/hypr/input.lua")"

section "a failed push reports a push retry"
remote="$TMP/remote.git"
git init --bare -q -b main "$remote"
git -C "$REPO_DIR" remote add origin "$remote"
git -C "$REPO_DIR" push -q -u origin main
mkdir -p "$remote/hooks"
printf '#!/bin/sh\nexit 1\n' > "$remote/hooks/pre-receive"
chmod +x "$remote/hooks/pre-receive"
set_out=$("$CLI" set idle.lock 1200 2>&1); set_rc=$?
(( set_rc != 0 )) && t_ok "a rejected push reports failure" || t_bad "a rejected push reports failure"
check_contains "the setting says the local commit exists" "Saved locally" "$set_out"
check_contains "the setting prints the push retry" "Retry: omarchy-replicant push" "$set_out"
check "the setting remains committed locally" "1200" \
  "$(jq -r '.idle.lock' "$CONFIG_DIR/omarchy/shell.json")"
check "the unrelated live edit stays out during a failed push" "original input" \
  "$(<"$CONFIG_DIR/hypr/input.lua")"
rm -f "$remote/hooks/pre-receive"
check_true "the advertised push retry succeeds" "$CLI" push

section "settings follow their profile-scoped owner"
check_true "the setting entry can scope to this profile" \
  "$CLI" scope omarchy/shell.json profile
check_true "a profile-scoped setting saves" "$CLI" set idle.lock 1500
profile_copy=$(repo_path_for omarchy/shell.json)
check "the setting value reaches the profile copy" "1500" \
  "$(jq -r '.idle.lock' "$profile_copy")"
check "the setting owner remains explicit" "omarchy/shell.json" \
  "$(setting_save_id idle.lock)"

summary
