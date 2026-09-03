#!/bin/bash
# Tests for the SETTINGS layer in bin/replicant-core.sh.
#
# These run against throwaway copies in a temp dir — they never touch the real
# ~/.config or the user's repo. Run with:  ./tests/test-settings.sh
set -uo pipefail

CORE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/bin/replicant-core.sh"
pass=0; fail=0

# Named t_* on purpose: replicant-core.sh defines its own ok()/skip()/run()
# and sourcing it would otherwise silently replace the test reporters.
t_ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
t_bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail+1)); }
check(){ # check <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then t_ok "$1"; else t_bad "$1 — expected '$2', got '$3'"; fi
}

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
mkdir -p "$TMP/.config/omarchy"

cat > "$TMP/.config/omarchy/shell.json" <<'JSON'
{
  "idle": { "lock": 600, "screensaver": 300, "lazyDpms": 120 },
  "bar": { "position": "top", "transparent": false }
}
JSON
cat > "$TMP/.config/omarchy/shell.toml" <<'TOML'
[font]
base-size = 14
TOML

# shellcheck source=/dev/null
source "$CORE" 2>/dev/null
# replicant-core.sh sets -euo pipefail; the tests deliberately call failing
# commands, so relax that here (in this shell only).
set +e +u

echo "reading values"
check "reads a JSON number"      "300"   "$(get_setting_value idle.screensaver)"
check "reads a JSON enum"        "top"   "$(get_setting_value bar.position)"
check "reads a JSON bool"        "false" "$(get_setting_value bar.transparent)"
check "reads a TOML number"      "14"    "$(get_setting_value font.baseSize)"

echo "writing values"
set_setting_value idle.screensaver 240 >/dev/null 2>&1
check "writes a JSON number"     "240"   "$(get_setting_value idle.screensaver)"
set_setting_value bar.position bottom >/dev/null 2>&1
check "writes a JSON enum"       "bottom" "$(get_setting_value bar.position)"
set_setting_value bar.transparent true >/dev/null 2>&1
check "writes a JSON bool"       "true"  "$(get_setting_value bar.transparent)"
set_setting_value font.baseSize 16 >/dev/null 2>&1
check "writes a TOML number"     "16"    "$(get_setting_value font.baseSize)"
check "TOML file stays valid"    "[font]" "$(head -1 "$TMP/.config/omarchy/shell.toml")"

echo "rejecting bad input (the value must not change)"
set_setting_value idle.screensaver abc >/dev/null 2>&1
check "rejects non-numeric"      "240"   "$(get_setting_value idle.screensaver)"
set_setting_value idle.screensaver 1 >/dev/null 2>&1
check "rejects below minimum"    "240"   "$(get_setting_value idle.screensaver)"
set_setting_value idle.screensaver 999999 >/dev/null 2>&1
check "rejects above maximum"    "240"   "$(get_setting_value idle.screensaver)"
set_setting_value bar.position sideways >/dev/null 2>&1
check "rejects value outside enum" "bottom" "$(get_setting_value bar.position)"
set_setting_value bar.transparent maybe >/dev/null 2>&1
check "rejects non-boolean"      "true"  "$(get_setting_value bar.transparent)"
set_setting_value does.not.exist 1 >/dev/null 2>&1
check "rejects unknown setting"  "1"     "$?"

echo "safety"
backups=$(find "$TMP/.config/omarchy" -name '*.bak.*' | wc -l)
[[ "$backups" -gt 0 ]] && t_ok "every write left a .bak.<epoch> behind" || t_bad "no backups were made"
check "JSON is still parseable"  "0"     "$(jq empty "$TMP/.config/omarchy/shell.json" >/dev/null 2>&1; echo $?)"

echo "status JSON"
settings_json=$(build_settings_json)
check "emits one entry per setting" "8" "$(printf '%s' "$settings_json" | jq 'length')"
check "enum carries its options"    "2" "$(printf '%s' "$settings_json" | jq '[.[] | select(.type=="enum")][0].options | length')"
check "numbers stay numbers"        "number" "$(printf '%s' "$settings_json" | jq -r '[.[] | select(.id=="idle.screensaver")][0].value | type')"

echo
if (( fail == 0 )); then
  printf '\033[32mAll %d checks passed.\033[0m\n' "$pass"; exit 0
else
  printf '\033[31m%d of %d checks failed.\033[0m\n' "$fail" "$((pass+fail))"; exit 1
fi
