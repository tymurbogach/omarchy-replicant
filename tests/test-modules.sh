#!/bin/bash
# Module boundaries that the shell dispatcher relies on.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CORE="$HERE/../bin/replicant-core.sh"
source "$HERE/lib.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" OMARCHY_REPLICANT_HOME="$TMP/replicant" OMARCHY_PATH="$TMP/omarchy"
mkdir -p "$HOME/.config" "$OMARCHY_PATH/config"
# shellcheck source=bin/replicant-core.sh
source "$CORE" 2>/dev/null
set +e +u

section "shell module boundaries"
check_true "inventory module is loaded" declare -F regenerate_inventory
check_true "backup module is loaded" declare -F core_backup
check_true "repository module is loaded" declare -F repo_push
check_true "save module is loaded" declare -F core_save
check_true "crypto module is loaded" declare -F vault_save_all
check_true "migration module is loaded" declare -F core_migration_confirm
check_false "layout does not define inventory generation" bash -c 'grep -q "Regenerating state/ inventory" "$1"' _ "$HERE/../bin/lib/layout.sh"
check_false "layout does not export backup operation" bash -c 'grep -q "^core_backup()" "$1"' _ "$HERE/../bin/lib/layout.sh"
check_true "status module serializes status" declare -F core_status
check "remote state without a remote" "local-only" "$(remote_state_for "" true 0 0)"
check "remote state with local commits" "ahead" "$(remote_state_for "origin" true 2 0)"
check "remote state with remote commits" "behind" "$(remote_state_for "origin" true 0 2)"
check "remote state with both sides changed" "diverged" "$(remote_state_for "origin" true 1 1)"
check "remote state when fetch fails" "offline" "$(remote_state_for "origin" false 0 0)"
summary
