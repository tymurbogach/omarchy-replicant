#!/bin/bash
# The SETTINGS layer in bin/replicant-core.sh: reading, writing, refusing, and
# the JSON the panel consumes.
#
# Runs entirely inside a temp $HOME — it never touches the real ~/.config.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CORE="$HERE/../bin/replicant-core.sh"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
export OMARCHY_REPLICANT_HOME="$TMP/replicant"
mkdir -p "$TMP/.config/omarchy" "$TMP/.config/hypr" "$TMP/.local/state/omarchy/defaults"

cat > "$TMP/.config/omarchy/shell.json" <<'JSON'
{
  "idle": { "lock": 600, "screensaver": 300, "lazyDpms": 120, "lazySuspendAc": 0, "lazySuspendBatt": 300 },
  "bar": { "position": "top", "transparent": false }
}
JSON

printf '[font]\nbase-size = 14\n' > "$TMP/.config/omarchy/shell.toml"

cat > "$TMP/.config/hypr/input.lua" <<'LUA'
hl.config({
  input = {
    kb_layout = "es",
    repeat_rate = 40,
    repeat_delay = 250,
    touchpad = {
      natural_scroll = true,
      tap_to_click = true,  -- trailing comment must survive
      disable_while_typing = true,
    },
  },
})
-- commented out, must be ignored: repeat_rate = 99
LUA

printf 'code\n' > "$TMP/.local/state/omarchy/defaults/editor"

# shellcheck source=/dev/null
source "$CORE" 2>/dev/null
# replicant-core.sh sets -euo pipefail; these tests deliberately call failing
# commands, so relax that in this shell only.
set +e +u

section "reading — one per storage format"
check "JSON number"                  "300"   "$(get_setting_value idle.screensaver)"
check "JSON number that is zero"     "0"     "$(get_setting_value idle.lazySuspendAc)"
check "JSON enum"                    "top"   "$(get_setting_value bar.position)"
check "JSON bool that is false"      "false" "$(get_setting_value bar.transparent)"
check "TOML int"                     "14"    "$(get_setting_value font.baseSize)"
check "Lua int"                      "40"    "$(get_setting_value input.repeatRate)"
check "Lua quoted string"            "es"    "$(get_setting_value input.kbLayout)"
check "Lua bool, nested two levels"  "true"  "$(get_setting_value input.naturalScroll)"
check "single-line file"             "code"  "$(get_setting_value default.editor)"
check_false "absent TOML key reads as missing" get_setting_value spacing.scale
check_false "unknown id is rejected"           get_setting_value does.not.exist

section "writing — the value lands and the file stays valid"
set_setting_value idle.screensaver 240 >/dev/null 2>&1
check "JSON number written"          "240"    "$(get_setting_value idle.screensaver)"
set_setting_value bar.position bottom >/dev/null 2>&1
check "JSON enum written"            "bottom" "$(get_setting_value bar.position)"
set_setting_value bar.transparent true >/dev/null 2>&1
check "JSON bool written"            "true"   "$(get_setting_value bar.transparent)"
check "JSON still parses"            "0"      "$(jq empty "$TMP/.config/omarchy/shell.json" >/dev/null 2>&1; echo $?)"

set_setting_value font.baseSize 16 >/dev/null 2>&1
check "TOML int written"             "16"     "$(get_setting_value font.baseSize)"
check "TOML section header kept"     "[font]" "$(head -1 "$TMP/.config/omarchy/shell.toml")"

# shell.toml ships nearly empty, so "the key isn't there yet" is the normal
# first write for most appearance settings, not an error.
set_setting_value spacing.scale 1.25 >/dev/null 2>&1
check "TOML float created in a new section" "1.25" "$(get_setting_value spacing.scale)"
set_setting_value bar.sizeHorizontal 30 >/dev/null 2>&1
check "TOML key created in a new section"   "30"   "$(get_setting_value bar.sizeHorizontal)"
set_setting_value bar.sizeVertical 34 >/dev/null 2>&1
check "second key into the same section"    "34"   "$(get_setting_value bar.sizeVertical)"
check "earlier TOML value untouched"        "1.25" "$(get_setting_value spacing.scale)"
check "font section survived both writes"   "16"   "$(get_setting_value font.baseSize)"

set_setting_value input.repeatRate 55 >/dev/null 2>&1
check "Lua int written"              "55"     "$(get_setting_value input.repeatRate)"
set_setting_value input.tapToClick false >/dev/null 2>&1
check "Lua bool written"             "false"  "$(get_setting_value input.tapToClick)"
set_setting_value input.kbLayout us >/dev/null 2>&1
check "Lua string written"           "us"     "$(get_setting_value input.kbLayout)"
check_contains "Lua value is re-quoted" 'kb_layout = "us"' "$(cat "$TMP/.config/hypr/input.lua")"
check_contains "trailing comment survives" 'tap_to_click = false, -- trailing comment' "$(cat "$TMP/.config/hypr/input.lua")"
check_contains "indentation preserved" '    repeat_rate = 55,' "$(cat "$TMP/.config/hypr/input.lua")"
check "commented-out line untouched" "1" "$(grep -c 'repeat_rate = 99' "$TMP/.config/hypr/input.lua")"

set_setting_value default.editor nvim >/dev/null 2>&1
check "single-line file written"     "nvim"   "$(get_setting_value default.editor)"

section "refusing bad input — the value must not move"
check_false "non-numeric rejected"        set_setting_value idle.screensaver abc
check "…and the value is unchanged"  "240" "$(get_setting_value idle.screensaver)"
check_false "below minimum rejected"      set_setting_value idle.screensaver 1
check_false "above maximum rejected"      set_setting_value idle.screensaver 999999
check "…still unchanged"             "240" "$(get_setting_value idle.screensaver)"
check_false "value outside enum rejected" set_setting_value bar.position sideways
check "…still bottom"                "bottom" "$(get_setting_value bar.position)"
check_false "non-boolean rejected"        set_setting_value bar.transparent maybe
check_false "unknown setting rejected"    set_setting_value does.not.exist 1
check_false "float out of range rejected" set_setting_value spacing.scale 9
check_false "non-numeric float rejected"  set_setting_value spacing.scale wide
check "…float unchanged"             "1.25" "$(get_setting_value spacing.scale)"
check_false "int type rejects a float"    set_setting_value font.baseSize 12.5
check "…font size unchanged"         "16"   "$(get_setting_value font.baseSize)"

section "refusing an ambiguous Lua key rather than guessing"
# The same key in two tables must read as missing and refuse to be written:
# a generic nested-table editor needs a real Lua parser to be safe, and these
# files decide whether the graphical session starts at all.
cat > "$TMP/.config/hypr/input.lua" <<'LUA'
hl.config({
  input = {
    repeat_rate = 40,
    touchpad = {
      repeat_rate = 10,
    },
  },
})
LUA
check_false "duplicate key reads as missing" get_setting_value input.repeatRate
check_false "duplicate key refuses a write"  set_setting_value input.repeatRate 60
check "…both lines still present" "2" "$(grep -c 'repeat_rate' "$TMP/.config/hypr/input.lua")"
check "…and neither value moved"  "1" "$(grep -c 'repeat_rate = 40' "$TMP/.config/hypr/input.lua")"

rm -f "$TMP/.config/hypr/input.lua"
check_false "missing file reads as missing"  get_setting_value input.repeatRate
check_false "missing file refuses a write"   set_setting_value input.repeatRate 60

section "safety"
backups=$(find "$TMP/.config" "$TMP/.local" -name '*.bak.*' 2>/dev/null | wc -l)
if [[ "$backups" -gt 0 ]]; then t_ok "every write left a .bak.<epoch> behind ($backups)"; else t_bad "no backups were made"; fi

# Backups are capped per file. Dragging a slider is a dozen writes, and one
# backup each buried the real config under near-identical copies.
for v in 100 110 120 130 140; do set_setting_value idle.lock "$v" >/dev/null 2>&1; done
# At most 3, not exactly 3: the name carries a whole-second timestamp, so
# writes inside the same second reuse one file rather than adding another.
n=$(find "$TMP/.config/omarchy" -name 'shell.json.bak.*' | wc -l)
if (( n >= 1 && n <= 3 )); then t_ok "backups are capped per file (kept $n)"; else t_bad "expected 1-3 backups, found $n"; fi
check "…and the newest survives"    "140" "$(get_setting_value idle.lock)"
check "…without touching other files' backups" "1" \
  "$(find "$TMP/.local" -name 'editor.bak.*' | wc -l)"
check "JSON is still parseable"       "0" "$(jq empty "$TMP/.config/omarchy/shell.json" >/dev/null 2>&1; echo $?)"
check "TOML has no duplicate sections" "1" "$(grep -c '^\[bar\]' "$TMP/.config/omarchy/shell.toml")"

section "the JSON the panel consumes"
settings_json=$(build_settings_json)
check "valid JSON"                    "0"  "$(printf '%s' "$settings_json" | jq empty >/dev/null 2>&1; echo $?)"
check "one entry per registry line"   "${#SETTINGS[@]}" "$(printf '%s' "$settings_json" | jq 'length')"
check "every entry carries a group"   "0"  "$(printf '%s' "$settings_json" | jq '[.[] | select(.group == "" or .group == null)] | length')"
check "every entry carries a label"   "0"  "$(printf '%s' "$settings_json" | jq '[.[] | select(.label == "" or .label == null)] | length')"
check "numbers stay numbers"          "number" "$(printf '%s' "$settings_json" | jq -r '[.[] | select(.id=="idle.screensaver")][0].value | type')"
check "bools stay bools"              "boolean" "$(printf '%s' "$settings_json" | jq -r '[.[] | select(.id=="bar.transparent")][0].value | type')"
check "enums carry their options"     "4"  "$(printf '%s' "$settings_json" | jq '[.[] | select(.id=="bar.position")][0].options | length')"
check "a missing value is unavailable" "false" "$(printf '%s' "$settings_json" | jq -r '[.[] | select(.id=="input.repeatRate")][0].available')"
check "…and is reported as null"       "null"  "$(printf '%s' "$settings_json" | jq -r '[.[] | select(.id=="input.repeatRate")][0].value')"
check "every group is one of the declared ones" "0" \
  "$(printf '%s' "$settings_json" | jq --argjson g "$(printf '%s\n' "${SETTING_GROUP_ORDER[@]}" | jq -Rsc 'split("\n") | map(select(length>0))')" \
     '[.[] | select(.group as $x | $g | index($x) | not)] | length')"

section "the registry itself is well-formed"
bad_fields=0; dupe=0; seen=""
for entry in "${SETTINGS[@]}"; do
  n=$(printf '%s' "$entry" | awk -F'|' '{print NF}')
  [[ "$n" == 13 ]] || { bad_fields=$((bad_fields+1)); echo "    13 fields expected, got $n: $(setting_field "$entry" 1)"; }
  id=$(setting_field "$entry" 1)
  [[ ",$seen," == *",$id,"* ]] && dupe=$((dupe+1))
  seen="$seen,$id"
done
check "every line has 13 fields" "0" "$bad_fields"
check "no duplicate setting ids" "0" "$dupe"

summary
