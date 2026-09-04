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
  "$(printf '%s' "$settings_json" | jq --argjson g "$(printf '%s\n' "${SETTING_GROUPS[@]}" | cut -d'|' -f1 | jq -Rsc 'split("\n") | map(select(length>0))')" \
     '[.[] | select(.group as $x | $g | index($x) | not)] | length')"

section "values a person can read"
check "zero is never, not 0 s"       "never"        "$(human_duration 0)"
check "under a minute stays seconds" "45 s"         "$(human_duration 45)"
check "a round minute"               "10 min"       "$(human_duration 600)"
check "…and a ragged one keeps both" "2 min 30 s"   "$(human_duration 150)"
check "an hour"                      "1 h"          "$(human_duration 3600)"
check "…and change"                  "1 h 30 min"   "$(human_duration 5400)"
check "booleans read as on/off"      "on"           "$(human_value bool "" 1 "" true)"
check "…and off"                     "off"          "$(human_value lua-bool "" 1 "" false)"
check "a unit is spaced from its number" "26 px"    "$(human_value toml-int px 1 px 26)"
check "a multiplier is not"          "1.4×"         "$(human_value toml-float "×" 1 "×" 1.4)"
check "a rate is not"                "40/s"         "$(human_value lua-int "/s" 1 "/s" 40)"
check "an absent value is a dash"    "—"            "$(human_value number s 60 min "")"
# "1" and "1.0" are the same density; printing them differently made the panel
# offer a revert button that would have changed nothing.
check "trailing zeros are dropped"   "1"            "$(canon_number 1.0)"
check "…without eating real digits"  "1.4"          "$(canon_number 1.40)"
check "…and integers are left alone" "26"           "$(canon_number 26)"

section "the panel edits minutes, the CLI still speaks seconds"
# Earlier sections have been writing to these files; start from a known state.
cat > "$TMP/.config/omarchy/shell.json" <<'JSON'
{
  "idle": { "lock": 600, "screensaver": 150, "lazyDpms": 120, "lazySuspendAc": 0, "lazySuspendBatt": 300 },
  "bar": { "position": "top", "transparent": false }
}
JSON
sj=$(build_settings_json)
lock=$(printf '%s' "$sj" | jq '[.[] | select(.id=="idle.lock")][0]')
check "the stored value is seconds"        "600"    "$(printf '%s' "$lock" | jq -r '.value')"
check "the shown value is minutes"         "10"     "$(printf '%s' "$lock" | jq -r '.display_value')"
check "…labelled as such"                  "min"    "$(printf '%s' "$lock" | jq -r '.display_unit')"
check "…with the bounds converted too"     "1"      "$(printf '%s' "$lock" | jq -r '.display_min')"
check "…both of them"                      "120"    "$(printf '%s' "$lock" | jq -r '.display_max')"
check "a long range steps in fives"        "5"      "$(printf '%s' "$lock" | jq -r '.display_step')"
check "and the exact value is spelled out" "10 min" "$(printf '%s' "$lock" | jq -r '.value_text')"
# The rounding the stepper does must never be mistaken for the real value.
ss=$(printf '%s' "$sj" | jq '[.[] | select(.id=="idle.screensaver")][0]')
check "an odd number of seconds rounds in the stepper" "3" "$(printf '%s' "$ss" | jq -r '.display_value')"
check "…but the row still states the truth" "2 min 30 s" "$(printf '%s' "$ss" | jq -r '.value_text')"
check "zero reads as never, not 0 min"      "never" \
  "$(printf '%s' "$sj" | jq -r '[.[] | select(.id=="idle.lazySuspendAc")][0].value_text')"
check "an unscaled setting shows its stored value" "true" \
  "$(printf '%s' "$sj" | jq -r '[.[] | select(.id=="font.baseSize")][0] | .value == .display_value')"

section "the two ways back, per setting"
# Omarchy's own shipped file, so the "back to default" button has something to
# read rather than guessing.
export OMARCHY_PATH="$TMP/omarchy"
mkdir -p "$OMARCHY_PATH/config/omarchy"
# Earlier sections wrote appearance keys into shell.toml; start from the shape
# Omarchy actually ships, where most of them are simply absent.
printf '[font]\nbase-size = 14\n' > "$TMP/.config/omarchy/shell.toml"
printf '{"idle":{"lock":300},"bar":{"position":"top"}}\n' > "$OMARCHY_PATH/config/omarchy/shell.json"
check "the default comes from Omarchy's own file" "300" "$(setting_default_value idle.lock)"
sj=$(build_settings_json)
check "…and the panel is told so" "5 min" \
  "$(printf '%s' "$sj" | jq -r '[.[] | select(.id=="idle.lock")][0].default_text')"
check "a value that differs offers the button" "true" \
  "$(printf '%s' "$sj" | jq -r '[.[] | select(.id=="idle.lock")][0].can_revert_default')"
# A key Omarchy does not ship falls back to the registry's own fallback, which
# is the value the shell uses when the key is absent.
check "a key with no shipped default uses the fallback" "26" "$(setting_default_value bar.sizeHorizontal)"
check "…and offers no button while it matches" "false" \
  "$(printf '%s' "$sj" | jq -r '[.[] | select(.id=="bar.sizeHorizontal")][0].can_revert_default')"
check_false "a setting with neither has no default" setting_default_value input.repeatRate

# What the repo has, read out of the saved copy.
mkdir -p "$CONFIG_DIR/omarchy"
printf '{"idle":{"lock":900,"screensaver":150}}\n' > "$CONFIG_DIR/omarchy/shell.json"
check "the repo value comes from the saved copy" "900" "$(setting_repo_value idle.lock)"
sj=$(build_settings_json)
check "…and the panel is told so"    "15 min" \
  "$(printf '%s' "$sj" | jq -r '[.[] | select(.id=="idle.lock")][0].repo_text')"
check "a value that differs offers the button" "true" \
  "$(printf '%s' "$sj" | jq -r '[.[] | select(.id=="idle.lock")][0].can_revert_repo')"
check "one that matches does not"              "false" \
  "$(printf '%s' "$sj" | jq -r '[.[] | select(.id=="idle.screensaver")][0].can_revert_repo')"

core_revert idle.lock default >/dev/null 2>&1
check "reverting to the default writes it" "300" "$(get_setting_value idle.lock)"
check "…and touches nothing else in the file" "top" "$(jq -r '.bar.position' "$HOME/.config/omarchy/shell.json")"
core_revert idle.lock repo >/dev/null 2>&1
check "reverting to the repo writes that"  "900" "$(get_setting_value idle.lock)"
check_false "an unknown target is refused"  core_revert idle.lock sideways
check_false "an unknown setting is refused" core_revert not.a.setting default

section "the lid, on a machine that has one"
# The drop-in is root-owned in real life, so point the registry at a writable
# fixture: what is under test is the reader, the writer and the gate, not sudo.
export REPLICANT_LOGIND_DROPIN="$TMP/logind.d/99-lid.conf"
mkdir -p "$TMP/logind.d"
printf '[Login]\nHandleLidSwitch=ignore\n' > "$REPLICANT_LOGIND_DROPIN"
# shellcheck source=/dev/null
source "$CORE"
is_laptop() { return 0; }

check "a drop-in value is read back"    "ignore" "$(get_setting_value lid.close)"
set_setting_value lid.close suspend >/dev/null 2>&1
check "…and written"                    "suspend" "$(get_setting_value lid.close)"
check "…in systemd's own spelling, not TOML's" "1" \
  "$(grep -cx 'HandleLidSwitch=suspend' "$REPLICANT_LOGIND_DROPIN" || true)"
check "…keeping a backup like every other write" "1" \
  "$(ls "$REPLICANT_LOGIND_DROPIN".bak.* 2>/dev/null | wc -l)"
# A key the drop-in does not carry yet is logind's own built-in default, which
# is what the fallback field records — not "missing".
check "an absent key reports logind's default" "suspend" "$(get_setting_value lid.closeAc)"
set_setting_value lid.closeAc ignore >/dev/null 2>&1
check "…and writing it adds the key"    "ignore" "$(get_setting_value lid.closeAc)"
check "…without disturbing the other"   "suspend" "$(get_setting_value lid.close)"
check_false "a value logind does not know is refused" set_setting_value lid.close sideways
check "…and the file is untouched after a refusal" "suspend" "$(get_setting_value lid.close)"

check "the group is offered on a laptop" "1" \
  "$(build_setting_groups_json | jq -r '[.[] | select(.name=="Lid & sleep")] | length')"
is_laptop() { return 1; }
check "…and absent on a desktop"         "0" \
  "$(build_setting_groups_json | jq -r '[.[] | select(.name=="Lid & sleep")] | length')"
check "…along with its settings"         "0" \
  "$(build_settings_json | jq -r '[.[] | select(.group=="Lid & sleep")] | length')"
is_laptop() { return 0; }

section "a notice only when a setting genuinely cannot work"
# One rule, deliberately. A screensaver at or after the lock timer never appears,
# so the control silently does nothing — worth saying. Orderings people merely
# *assume* are wrong (display sleeping before the lock, suspend before the lock)
# are normal and must stay silent, or the notice trains people to ignore it.
cat > "$HOME/.config/omarchy/shell.json" <<'JSON'
{ "idle": { "lock": 300, "screensaver": 150, "lazyDpms": 60, "lazySuspendAc": 0, "lazySuspendBatt": 120 },
  "bar": { "position": "top", "transparent": false } }
JSON
notice_of() { build_settings_json | jq -r --arg id "$1" '[.[] | select(.id==$id)][0].notice'; }
check "a sane order says nothing"            "" "$(notice_of idle.screensaver)"
check "…display sleeping first is not a fault" "" "$(notice_of idle.lazyDpms)"
check "…nor is suspending before the lock"     "" "$(notice_of idle.lazySuspendBatt)"

# Screensaver at 10 min with a 5 min lock: it can never appear.
jq '.idle.screensaver = 600' "$HOME/.config/omarchy/shell.json" > "$TMP/s.json" && mv "$TMP/s.json" "$HOME/.config/omarchy/shell.json"
check "a screensaver that can never appear is called out" "1" \
  "$(notice_of idle.screensaver | grep -c 'never appears' || true)"
jq '.idle.screensaver = 150' "$HOME/.config/omarchy/shell.json" > "$TMP/s.json" && mv "$TMP/s.json" "$HOME/.config/omarchy/shell.json"
check "…and it clears when the order is fixed" "" "$(notice_of idle.screensaver)"
check "every setting carries the field"        "0" \
  "$(build_settings_json | jq '[.[] | select(has("notice") | not)] | length')"

section "the registry itself is well-formed"
bad_fields=0; dupe=0; seen=""
for entry in "${SETTINGS[@]}"; do
  n=$(printf '%s' "$entry" | awk -F'|' '{print NF}')
  [[ "$n" == 15 ]] || { bad_fields=$((bad_fields+1)); echo "    15 fields expected, got $n: $(setting_field "$entry" 1)"; }
  id=$(setting_field "$entry" 1)
  [[ ",$seen," == *",$id,"* ]] && dupe=$((dupe+1))
  seen="$seen,$id"
done
check "every line has 15 fields" "0" "$bad_fields"
check "no duplicate setting ids" "0" "$dupe"

summary
