#!/bin/bash
# The parts of bin/replicant-core.sh that decide what gets tracked, what a file
# is compared against, and what the panel's badges say.
#
# Everything runs against a fake $HOME, a fake /usr/share/omarchy (via
# $OMARCHY_PATH) and a real but throwaway git repo, so the sync states can be
# driven for real instead of mocked.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CORE="$HERE/../bin/replicant-core.sh"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export OMARCHY_PATH="$TMP/omarchy"
export OMARCHY_REPLICANT_HOME="$TMP/replicant"

mkdir -p "$HOME/.config/hypr" "$HOME/.config/omarchy/plugins/com.example.demo" "$HOME/.config/alacritty"
mkdir -p "$OMARCHY_PATH/config/hypr" "$OMARCHY_PATH/default/bash"

# Omarchy's shipped defaults
printf 'default input\n'      > "$OMARCHY_PATH/config/hypr/input.lua"
printf 'default looknfeel\n'  > "$OMARCHY_PATH/config/hypr/looknfeel.lua"
printf 'default bashrc\n'     > "$OMARCHY_PATH/default/bash/bashrc"

# this machine: one file untouched, one customised, one with no default at all
cp "$OMARCHY_PATH/config/hypr/looknfeel.lua" "$HOME/.config/hypr/looknfeel.lua"
printf 'my own input\n'  > "$HOME/.config/hypr/input.lua"
printf 'my own bashrc\n" > /dev/null'  > "$HOME/.bashrc"
printf 'colors: mine\n'  > "$HOME/.config/alacritty/alacritty.toml"

# a third-party plugin following the discovery convention
printf '{"id":"com.example.demo","name":"Demo Plugin"}\n' > "$HOME/.config/omarchy/plugins/com.example.demo/manifest.json"
printf '{"enabled":true}\n' > "$HOME/.config/omarchy/demo.json"
# and one that does not (no config file next to the manifest)
mkdir -p "$HOME/.config/omarchy/plugins/com.example.silent"
printf '{"id":"com.example.silent","name":"Silent"}\n' > "$HOME/.config/omarchy/plugins/com.example.silent/manifest.json"

# shellcheck source=/dev/null
source "$CORE" 2>/dev/null
set +e +u

section "finding the file Omarchy ships as the default"
check "a ~/.config file with a default"      "$OMARCHY_PATH/config/hypr/input.lua" "$(default_for_src "$HOME/.config/hypr/input.lua")"
check ".bashrc maps to default/bash/bashrc"  "$OMARCHY_PATH/default/bash/bashrc"   "$(default_for_src "$HOME/.bashrc")"
check_false "/etc has no Omarchy default"    default_for_src "/etc/systemd/logind.conf.d/99-lid.conf"
check_false "~/.local/state has none either" default_for_src "$HOME/.local/state/omarchy/current/theme.name"
check_false "an unknown ~/.config file has none" default_for_src "$HOME/.config/alacritty/alacritty.toml"

section "is this file still the factory version"
check_true  "untouched file reads as default" is_default_file "$HOME/.config/hypr/looknfeel.lua"
check_false "customised file does not"        is_default_file "$HOME/.config/hypr/input.lua"
check_false "a file with no default never does" is_default_file "$HOME/.config/alacritty/alacritty.toml"

section "the path 'omarchy refresh config' expects"
# Derived from the real file, not from the repo layout: the two only coincide
# by accident, and passing the wrong one silently refreshes nothing.
check "under ~/.config"          "hypr/input.lua" "$(config_rel_for_src "$HOME/.config/hypr/input.lua")"
check_false "~/.bashrc is not under ~/.config" config_rel_for_src "$HOME/.bashrc"
check_false "nor is /etc"                      config_rel_for_src "/etc/hosts"

section "auto-detecting other plugins' configs"
entries=$(discover_plugin_entries)
check_contains "a plugin following the convention is found" "plugins/demo.json" "$entries"
check_contains "…labelled with its display name"            "Demo Plugin"       "$entries"
check "…and one entry only"       "1" "$(printf '%s\n' "$entries" | grep -c . )"
check "a plugin with no config file is skipped" "0" "$(printf '%s\n' "$entries" | grep -c silent)"
check "replicant never lists itself"            "0" "$(printf '%s\n' "$entries" | grep -c omarchy-replicant)"

section "a plugin the other machine can actually reinstall"
# The inventory is what rebuilds this machine's shell elsewhere. Two ways it
# used to record something unusable: a plugin with no git origin at all, and one
# installed from a local checkout, whose recorded "origin" is a path that does
# not exist on the other machine.
mkdir -p "$HOME/.config/omarchy/plugins/local.only"
printf '{"id":"local.only","name":"Local Only","version":"1.0.0"}\n' \
  > "$HOME/.config/omarchy/plugins/local.only/manifest.json"
check "a plugin with no git origin is named, not skipped" "1" \
  "$(local_only_plugins | grep -cx 'local.only' || true)"

# A checkout that is itself a clone: the remote is the real origin.
upstream="$TMP/upstream.git"; git init -q --bare "$upstream"
checkout="$TMP/dev-plugin"; git init -q "$checkout"
git -C "$checkout" remote add origin "$upstream"
mkdir -p "$HOME/.config/omarchy/plugins/from.checkout"
printf '{"id":"from.checkout","name":"From Checkout","version":"1.0.0"}\n' \
  > "$HOME/.config/omarchy/plugins/from.checkout/manifest.json"
git init -q "$HOME/.config/omarchy/plugins/from.checkout"
git -C "$HOME/.config/omarchy/plugins/from.checkout" remote add origin "$checkout"
core_backup >/dev/null 2>&1
inv="$STATE_DIR/omarchy-plugins.txt"
check "a local checkout resolves to its real remote" "1" \
  "$(grep -c "from.checkout.*$upstream" "$inv" || true)"
check "…and not to the path that only exists here" "0" \
  "$(grep -c "from.checkout.*$checkout\b" "$inv" || true)"
check "…so it is not reported as local-only" "0" \
  "$(local_only_plugins | grep -cx 'from.checkout' || true)"

# An edited copy of a built-in has no repo anywhere, but Omarchy can re-clone
# the built-in it came from. Different command, so the inventory records which.
mkdir -p "$HOME/.config/omarchy/plugins/mine.clock"
printf '{"id":"mine.clock","name":"My Clock","version":"1.0.0","omarchy":{"clonedFrom":"omarchy.clock"}}\n' \
  > "$HOME/.config/omarchy/plugins/mine.clock/manifest.json"
core_backup >/dev/null 2>&1
check "a clone of a built-in records the built-in it came from" "1" \
  "$(grep -cP 'mine\.clock\t[^\t]*\tomarchy\.clock\tclone' "$inv" || true)"
check "…and is not reported as unrecoverable" "0" \
  "$(local_only_plugins | grep -cx 'mine.clock' || true)"

# A plugin you wrote yourself, copied into place with no .git, but whose source
# is a checkout on this machine. This is the case Omarchy itself cannot answer:
# `plugin list --json` carries no origin and `plugin update` skips it entirely.
mkdir -p "$TMP/roots/dev/my-widget"
git init -q "$TMP/roots/dev/my-widget"
git -C "$TMP/roots/dev/my-widget" remote add origin https://example.invalid/me/my-widget.git
printf '{"id":"mine.widget","name":"My Widget","version":"1.0.0"}\n' \
  > "$TMP/roots/dev/my-widget/manifest.json"
mkdir -p "$HOME/.config/omarchy/plugins/mine.widget"
cp "$TMP/roots/dev/my-widget/manifest.json" "$HOME/.config/omarchy/plugins/mine.widget/manifest.json"
PLUGIN_SOURCE_ROOTS=("$TMP/roots/dev")
core_backup >/dev/null 2>&1
check "a plugin is traced back to the checkout that builds it" "1" \
  "$(grep -c 'mine.widget.*example.invalid/me/my-widget.git' "$inv" || true)"
check "…and counts as recoverable" "0" \
  "$(local_only_plugins | grep -cx 'mine.widget' || true)"

# And one with genuinely nowhere to come from stays reported.
check "a plugin with no trail at all is still named" "1" \
  "$(local_only_plugins | grep -cx 'local.only' || true)"

rm -rf "$HOME/.config/omarchy/plugins/local.only" "$HOME/.config/omarchy/plugins/from.checkout" \
       "$HOME/.config/omarchy/plugins/mine.clock" "$HOME/.config/omarchy/plugins/mine.widget"

section "resolving a tracked id back to a real file"
check "a manifest id"        "$HOME/.config/hypr/input.lua" "$(resolve_manifest_src hypr/input.lua)"
check "a secret id"          "$HOME/.ssh/id_ed25519"        "$(resolve_manifest_src ssh/id_ed25519)"
check "an auto-detected id"  "$HOME/.config/omarchy/demo.json" "$(resolve_manifest_src plugins/demo.json)"
check_false "an unknown id"  resolve_manifest_src not/a/real/one

section "the sync states, driven for real through git"
git init -q "$REPO_DIR" 2>/dev/null
git -C "$REPO_DIR" config user.email t@example.com
git -C "$REPO_DIR" config user.name Test
core_backup >/dev/null 2>&1
git -C "$REPO_DIR" add -A >/dev/null 2>&1
git -C "$REPO_DIR" commit -q -m initial >/dev/null 2>&1

configs=$(build_configs_json)
check "valid JSON"  "0" "$(printf '%s' "$configs" | jq empty >/dev/null 2>&1; echo $?)"
state_of() { printf '%s' "$configs" | jq -r --arg id "$1" '[.[] | select(.id == $id)][0].sync_state'; }

check "untouched file → default" "default" "$(state_of hypr/looknfeel.lua)"
# Committed but with no upstream at all, so it cannot be "saved on GitHub" yet.
check "committed but never pushed → unpushed" "unpushed" "$(state_of hypr/input.lua)"

# Give it an upstream and push, and the same file must flip to "saved".
git init -q --bare "$TMP/remote.git"
git -C "$REPO_DIR" remote add origin "$TMP/remote.git"
git -C "$REPO_DIR" push -q -u origin HEAD >/dev/null 2>&1
configs=$(build_configs_json)
check "pushed → saved"  "saved" "$(state_of hypr/input.lua)"

# Change the file on the machine and it must go back to modified.
printf 'changed again\n' > "$HOME/.config/hypr/input.lua"
core_backup >/dev/null 2>&1
configs=$(build_configs_json)
check "changed since the last save → unsaved" "unsaved" "$(state_of hypr/input.lua)"

section "a live edit is noticed without running a backup first"
# The bug this guards: `dirty` used to ask git whether the REPO COPY had changed,
# which only becomes true after core_backup has copied the live file in. A file
# edited on the machine and never saved therefore reported "saved on GitHub".
# Note there is deliberately NO core_backup between the edit and the check.
# Start from a genuinely clean baseline: copied in, committed AND pushed, so
# "saved" is the honest answer before the edit.
core_backup >/dev/null 2>&1
git -C "$REPO_DIR" add -A >/dev/null 2>&1
git -C "$REPO_DIR" commit -q -m "baseline" >/dev/null 2>&1
git -C "$REPO_DIR" push -q origin HEAD >/dev/null 2>&1
configs=$(build_configs_json)
check "a committed and pushed file reads as saved" "saved" "$(state_of hypr/input.lua)"

cp "$HOME/.config/hypr/input.lua" "$TMP/input.saved"
printf 'edited but never saved\n' > "$HOME/.config/hypr/input.lua"
configs=$(build_configs_json)
check "editing a tracked file marks it unsaved" "unsaved" "$(state_of hypr/input.lua)"

# …and putting it back must clear the warning by itself, with no backup either.
cp "$TMP/input.saved" "$HOME/.config/hypr/input.lua"
configs=$(build_configs_json)
check "putting it back clears the warning on its own" "saved" "$(state_of hypr/input.lua)"

# Reverting a customised file TO Omarchy's default is still a change to save.
# It used to read "default" and look settled, hiding the pending change.
def_src=$(default_for_src "$HOME/.config/hypr/input.lua" 2>/dev/null || true)
if [[ -n "$def_src" && -f "$def_src" ]]; then
  cp "$def_src" "$HOME/.config/hypr/input.lua"
  configs=$(build_configs_json)
  check "reverting to Omarchy's default still needs saving" "unsaved" "$(state_of hypr/input.lua)"
  cp "$TMP/input.saved" "$HOME/.config/hypr/input.lua"
fi

# A file copied in but not yet committed is also unsaved — same word, same button.
printf 'copied in, not committed\n' > "$HOME/.config/hypr/input.lua"
core_backup >/dev/null 2>&1
configs=$(build_configs_json)
check "copied into the repo but uncommitted is unsaved" "unsaved" "$(state_of hypr/input.lua)"
cp "$TMP/input.saved" "$HOME/.config/hypr/input.lua"
core_backup >/dev/null 2>&1
git -C "$REPO_DIR" add -A >/dev/null 2>&1
git -C "$REPO_DIR" commit -q -m "back to the saved copy" >/dev/null 2>&1
git -C "$REPO_DIR" push -q origin HEAD >/dev/null 2>&1

section "what each config row tells the panel"
row=$(printf '%s' "$configs" | jq -c '[.[] | select(.id == "hypr/input.lua")][0]')
for field in id label src group exists is_default has_default config_rel dirty unpushed sync_state source; do
  check "row carries $field" "true" "$(printf '%s' "$row" | jq --arg f "$field" 'has($f)')"
done
check "has_default is true where a default exists" "true" \
  "$(printf '%s' "$configs" | jq -r '[.[] | select(.id=="hypr/input.lua")][0].has_default')"
check "has_default is false where none does" "false" \
  "$(printf '%s' "$configs" | jq -r '[.[] | select(.id=="etc/99-lid.conf")][0].has_default')"
check "every row has a sync_state" "0" \
  "$(printf '%s' "$configs" | jq '[.[] | select(.sync_state == null or .sync_state == "")] | length')"
check "sync_state is one of the known set" "0" \
  "$(printf '%s' "$configs" | jq '[.[] | select(.sync_state | IN("default","unsaved","unpushed","saved","off","missing") | not)] | length')"

section "the diff the panel renders inline"
check_contains "against the repo copy" "this machine" "$(core_diff hypr/input.lua repo)"
check_contains "against the Omarchy default" "omarchy default" "$(core_diff hypr/input.lua default)"
check_contains "an unmodified file says so" "identical to Omarchy's default" "$(core_diff hypr/looknfeel.lua default)"
check_contains "a file with no default says so" "no Omarchy default" "$(core_diff alacritty/alacritty.toml default)"
check_contains "an unknown id is reported"  "unknown id" "$(core_diff nope/nope 2>&1)"

section "recent saves as JSON"
log=$(core_log 5)
check "valid JSON"          "0"    "$(printf '%s' "$log" | jq empty >/dev/null 2>&1; echo $?)"
check "at least one commit" "true" "$(printf '%s' "$log" | jq 'length > 0')"
check "entries carry a subject" "0" "$(printf '%s' "$log" | jq '[.[] | select(.subject == null)] | length')"
check "sha is abbreviated"      "7" "$(printf '%s' "$log" | jq -r '.[0].sha | length')"

section "backup only ever reads the configs it tracks"
# Scoped to ~/.config on purpose: the state/ inventory shells out to pacman,
# mise, npm and systemctl to list what is installed, and some of those write
# their own caches under $HOME. What must never change is the configuration
# itself — backup copies system -> repo and never the other way.
before=$(hash_tree "$HOME/.config")
core_backup >/dev/null 2>&1
check "tracked configs are untouched by a backup" "$before" "$(hash_tree "$HOME/.config")"

section "backup prunes what is no longer tracked"
# Dropping a MANIFEST line (or uninstalling a plugin) must not leave its last
# copy in the repo forever, describing a machine that no longer exists.
mkdir -p "$CONFIG_DIR/stale/deeper"
printf 'left over\n' > "$CONFIG_DIR/stale/deeper/old.conf"
printf 'left over\n' > "$CONFIG_DIR/omarchy-plugin-copy.qml"
core_backup >/dev/null 2>&1
check "an untracked file is removed"      "0" "$(ls "$CONFIG_DIR/omarchy-plugin-copy.qml" 2>/dev/null | wc -l)"
check "…including nested ones"            "0" "$(ls "$CONFIG_DIR/stale/deeper/old.conf" 2>/dev/null | wc -l)"
check "…and the empty dirs it leaves"     "0" "$(ls -d "$CONFIG_DIR/stale" 2>/dev/null | wc -l)"
check "a tracked file is kept"            "1" "$(ls "$CONFIG_DIR/hypr/input.lua" 2>/dev/null | wc -l)"
# A file whose source is missing on this machine is still tracked: keep its
# last saved copy rather than deleting the only record of it.
printf 'saved earlier\n' > "$CONFIG_DIR/home/XCompose"
rm -f "$HOME/.XCompose"
core_backup >/dev/null 2>&1
check "a tracked file with no source is kept" "1" "$(ls "$CONFIG_DIR/home/XCompose" 2>/dev/null | wc -l)"
check "…with its saved content intact" "saved earlier" "$(cat "$CONFIG_DIR/home/XCompose" 2>/dev/null)"

section "categories: one place decides where a file shows up"
declared=$(printf '%s\n' "${CATEGORY_ORDER[@]}")
unknown=0
for entry in "${MANIFEST[@]}"; do
  rel="${entry##*:}"
  cat=$(category_for_rel "$rel")
  grep -qx "$cat" <<<"$declared" || { unknown=$((unknown + 1)); echo "    $rel -> '$cat' is not a declared category"; }
done
check "every manifest entry lands in a declared category" "0" "$unknown"
check "the keyboard has its own area"   "shortcuts"   "$(category_for_rel hypr/bindings.lua)"
check "other hypr files do not"         "hyprland"    "$(category_for_rel hypr/input.lua)"
check "the theme is appearance"         "appearance"  "$(category_for_rel omarchy/theme.name)"
check "keys are secrets"                "secrets"     "$(category_for_rel ssh/id_ed25519)"
check "an unknown path falls back"      "other"       "$(category_for_rel wat/nope)"
check "every category is described"     "0" \
  "$(build_categories_json | jq '[.[] | select(.label == "" or .description == "" or .method == "" or .icon == "")] | length')"

section "the restore plan is derived from the manifest, never hand-listed"
# This is the bug the derivation exists to prevent: a file added to MANIFEST
# that backup copies but restore has no line for.
core_backup >/dev/null 2>&1
missing_from_plan=0
for entry in "${TRACKED[@]}"; do
  rel="${entry##*:}"
  [[ "$rel" == "omarchy/theme.name" ]] && continue      # applied, never copied
  [[ -e "$CONFIG_DIR/${rel%/}" ]] || continue           # not saved on this machine
  area=$(category_for_rel "$rel")
  # Captured, not piped into `grep -q`: grep exits on the first match, the
  # writer takes a SIGPIPE, and with `set -o pipefail` the whole pipeline then
  # reports failure even though the line was found.
  plan=$(plan_for_category "$area")
  grep -qF "|${entry%%:*}|" <<<"$plan" || {
    missing_from_plan=$((missing_from_plan + 1)); echo "    $rel ($area) is backed up but would never be restored"; }
done
check "every saved file appears in some category's plan" "0" "$missing_from_plan"
check "the theme is never copied back as a file" "0" \
  "$(plan_for_category appearance | grep -c 'theme.name' || true)"
check "destinations it cannot write are still listed" "3" \
  "$(plan_for_category system | grep -c '|/etc/' || true)"
check "keys restore as 600"   "600" "$(restore_mode_for ssh/id_ed25519)"
check "public keys do not"    "644" "$(restore_mode_for ssh/id_ed25519.pub)"
check "scripts stay runnable" "755" "$(restore_mode_for bin/omarchy-audit)"
check "hooks stay runnable"   "755" "$(restore_mode_for claude/hooks/whatever)"
check "everything else is 644" "644" "$(restore_mode_for omarchy/shell.json)"
check "hyprland is reloaded after a restore" "hyprctl reload" "$(apply_for_category hyprland)"
check "so are shortcuts"                     "hyprctl reload" "$(apply_for_category shortcuts)"
check "terminals are restarted"  "omarchy restart terminal" "$(apply_for_category terminal)"
check "files the shell watches need nothing" "" "$(apply_for_category desktop)"

section "profiles: what each machine syncs"
# hypr/monitors.lua describes the screens plugged into THIS machine. It is not
# switched off — it is scoped to a profile, so the desktop and the laptop each
# keep their own copy and neither overwrites the other.
check "monitors.lua starts scoped to a profile" "profile" "$(scope_for hypr/monitors.lua)"
check "everything else starts shared"           "shared"  "$(scope_for hypr/input.lua)"
check "input.lua is deliberately NOT per-profile — it holds the keyboard layout" \
  "shared" "$(scope_for hypr/input.lua)"
check_false "an unshared file is not 'excluded'"  is_excluded hypr/monitors.lua

# The three scopes, and the paths each one implies.
check "a shared file lives in config/" "$CONFIG_DIR/hypr/input.lua" "$(repo_path_for hypr/input.lua)"
check "a profile file lives under profiles/<profile>/" \
  "$REPO_DIR/profiles/$(current_profile)/config/hypr/monitors.lua" "$(repo_path_for hypr/monitors.lua)"

core_scope hypr/input.lua off >/dev/null 2>&1
check_true  "switching one off takes"            is_excluded hypr/input.lua
core_scope hypr/input.lua off >/dev/null 2>&1
check "switching it off twice does not duplicate it" "1" \
  "$(read_scopes | grep -cx 'hypr/input.lua = off' || true)"
core_scope hypr/input.lua shared >/dev/null 2>&1
check_false "switching it back on takes"         is_excluded hypr/input.lua
check_false "an unknown id is refused"           core_scope nope/nope off
check_false "an unknown scope is refused"        core_scope hypr/input.lua sideways
check "the decision travels in the repo, not in ~/.local" "1" \
  "$(ls "$REPO_DIR/.replicant-sync" 2>/dev/null | wc -l)"

# The v0.5 two-state switch still works, because it is in the shipped README.
core_sync hypr/input.lua off >/dev/null 2>&1
check "sync off still means off"   "off"    "$(scope_for hypr/input.lua)"
core_sync hypr/input.lua on  >/dev/null 2>&1
check "sync on still means shared" "shared" "$(scope_for hypr/input.lua)"

section "a profile-scoped file does not cross machines"
printf 'monitors as of now\n' > "$HOME/.config/hypr/monitors.lua"
core_backup >/dev/null 2>&1
check "it is saved under this profile" "monitors as of now" \
  "$(cat "$REPO_DIR/profiles/$(current_profile)/config/hypr/monitors.lua" 2>/dev/null)"
check "…and not into the shared config/" "0" \
  "$(ls "$CONFIG_DIR/hypr/monitors.lua" 2>/dev/null | wc -l)"
check "…and it does restore, from this profile's copy" "1" \
  "$(p=$(plan_for_category hyprland); grep -c 'monitors.lua' <<<"$p" || true)"

# The other profile's copy is not ours to touch, on save or on prune.
mkdir -p "$REPO_DIR/profiles/otherbox/config/hypr"
printf 'the desktop version\n' > "$REPO_DIR/profiles/otherbox/config/hypr/monitors.lua"
core_backup >/dev/null 2>&1
check "another profile's copy survives our save" "the desktop version" \
  "$(cat "$REPO_DIR/profiles/otherbox/config/hypr/monitors.lua" 2>/dev/null)"
check "…and we still read our own" "monitors as of now" \
  "$(cat "$REPO_DIR/profiles/$(current_profile)/config/hypr/monitors.lua" 2>/dev/null)"

section "switching a file off keeps what the repo already had"
core_scope hypr/monitors.lua off >/dev/null 2>&1
core_backup >/dev/null 2>&1
check "a file switched off is not copied into the repo" "0" \
  "$(ls "$CONFIG_DIR/hypr/monitors.lua" 2>/dev/null | wc -l)"
check "…and it is never restored onto this machine" "0" \
  "$(p=$(plan_for_category hyprland); grep -c 'monitors.lua' <<<"$p" || true)"
check "the panel shows it as off" "off" \
  "$(build_configs_json | jq -r '[.[] | select(.id=="hypr/monitors.lua")][0].sync_state')"
check "the panel reports its scope too" "off" \
  "$(build_configs_json | jq -r '[.[] | select(.id=="hypr/monitors.lua")][0].scope')"

section "changing scope moves the copy the repo already holds"
# Changing your mind must not strand a backup at the path nothing reads any more.
core_scope hypr/input.lua shared >/dev/null 2>&1
core_backup >/dev/null 2>&1
check "shared to begin with" "1" "$(ls "$CONFIG_DIR/hypr/input.lua" 2>/dev/null | wc -l)"
core_scope hypr/input.lua profile >/dev/null 2>&1
check "…moved out of config/ when scoped to a profile" "0" \
  "$(ls "$CONFIG_DIR/hypr/input.lua" 2>/dev/null | wc -l)"
check "…and into the profile tree" "1" \
  "$(ls "$REPO_DIR/profiles/$(current_profile)/config/hypr/input.lua" 2>/dev/null | wc -l)"
core_scope hypr/input.lua shared >/dev/null 2>&1
check "…and back again" "1" "$(ls "$CONFIG_DIR/hypr/input.lua" 2>/dev/null | wc -l)"

section "each machine belongs to a profile"
check "this machine has one"        "1" "$(current_profile | grep -c . || true)"
core_profile_set desktop >/dev/null 2>&1
check "it can be set explicitly"    "desktop" "$(current_profile)"
check "…and recorded in the repo"   "1" \
  "$(grep -c "^$MACHINE = desktop" "$REPO_DIR/.replicant-profiles" 2>/dev/null || true)"
core_profile_set laptop >/dev/null 2>&1
check "…and changed without duplicating the line" "1" \
  "$(grep -c "^$MACHINE = " "$REPO_DIR/.replicant-profiles" 2>/dev/null || true)"
check_false "a nonsense profile name is refused" core_profile_set "../etc"
check "the profile list includes ours" "1" \
  "$(list_profiles | grep -cx laptop || true)"

section "a v0.5 repo migrates its off-list"
# .replicant-exclude only ever meant "off", so the translation is exact and
# nothing the user chose is reinterpreted as something else.
rm -f "$REPO_DIR/.replicant-sync"
printf '# a comment\nhypr/monitors.lua\ngit/config\n' > "$REPO_DIR/.replicant-exclude"
check "the old file is honoured before the migration runs" "off" "$(scope_for git/config)"
ensure_repo_layout >/dev/null 2>&1
check "…and it is gone afterwards"  "0" "$(ls "$REPO_DIR/.replicant-exclude" 2>/dev/null | wc -l)"
check "…with both entries kept off" "2" \
  "$(read_scopes | grep -c ' = off$' || true)"
check "…meaning the same thing"     "off" "$(scope_for git/config)"

# The bug this guards against: changing ONE file's scope on a v0.5 repo used to
# rebuild the list from an empty read and throw the whole off-list away.
rm -f "$REPO_DIR/.replicant-sync"
printf 'hypr/monitors.lua\ngit/config\n' > "$REPO_DIR/.replicant-exclude"
core_scope hypr/input.lua profile >/dev/null 2>&1
check "changing one scope migrates first, it does not start from scratch" "off" \
  "$(scope_for git/config)"
check "…the other migrated entry survives too" "off" "$(scope_for hypr/monitors.lua)"
check "…and the new choice is recorded"        "profile" "$(scope_for hypr/input.lua)"
core_scope git/config shared >/dev/null 2>&1
core_scope hypr/monitors.lua profile >/dev/null 2>&1
core_scope hypr/input.lua shared >/dev/null 2>&1
check "the inventory is scoped by hostname" "$STATE_ROOT/$MACHINE" "$STATE_DIR"
check "…and that is where it was written"   "1" "$(ls "$STATE_DIR/system.txt" 2>/dev/null | wc -l)"
# A repo written before the scoping existed has its inventory flat in state/.
printf 'from an older version\n' > "$STATE_ROOT/legacy.txt"
ensure_repo_layout >/dev/null 2>&1
check "a flat inventory is migrated under this machine" "1" "$(ls "$STATE_DIR/legacy.txt" 2>/dev/null | wc -l)"
check "…and not left behind at the top"                 "0" "$(ls "$STATE_ROOT/legacy.txt" 2>/dev/null | wc -l)"
# The half-migrated case: a scoped copy already exists AND the old flat one is
# still there. `mv -n` exits 0 and does nothing here, which left every repo
# carrying two copies of its inventory for good.
printf 'stale\n' > "$STATE_ROOT/system.txt"
ensure_repo_layout >/dev/null 2>&1
check "a flat copy alongside a scoped one is cleared" "0" "$(ls "$STATE_ROOT/system.txt" 2>/dev/null | wc -l)"
check "…and the scoped one is the survivor"           "1" "$(ls "$STATE_DIR/system.txt" 2>/dev/null | wc -l)"
check "…with the machine's own content, not the stale copy" "0" \
  "$(grep -c '^stale$' "$STATE_DIR/system.txt" 2>/dev/null || true)"
mkdir -p "$STATE_ROOT/otherbox"; printf 'x\n' > "$STATE_ROOT/otherbox/system.txt"
check "status lists every machine that has saved here" "2" \
  "$(core_status --json --no-fetch 2>/dev/null | jq '.machines | length')"
check "…and marks which one is this one" "1" \
  "$(core_status --json --no-fetch 2>/dev/null | jq '[.machines[] | select(.current)] | length')"
rm -rf "$STATE_ROOT/otherbox"

section "shortcuts: your overrides, and what is bound right now"
mkdir -p "$HOME/.config/hypr"
cat > "$HOME/.config/hypr/bindings.lua" <<'BINDINGS'
-- o.bind("SUPER + X", "Commented out", "never-runs")
o.bind("SUPER + SHIFT + R", "SSH", "alacritty -e ssh box")
hl.unbind("SUPER + SPACE")
o.bind("SUPER + H", nil, "voxtype record toggle")
BINDINGS
sc=$(core_shortcuts)
check "valid JSON"                    "0" "$(printf '%s' "$sc" | jq empty >/dev/null 2>&1; echo $?)"
check "commented-out bindings are not yours" "3" "$(printf '%s' "$sc" | jq '.own | length')"
check "a described binding keeps its description" "SSH" \
  "$(printf '%s' "$sc" | jq -r '[.own[] | select(.key=="SUPER + SHIFT + R")][0].description')"
check "…and its command"  "alacritty -e ssh box" \
  "$(printf '%s' "$sc" | jq -r '[.own[] | select(.key=="SUPER + SHIFT + R")][0].command')"
# `o.bind(keys, nil, cmd)` is common, and counting quotes alone labels such a
# binding with its own command as its name.
check "a nil description does not become the label" "" \
  "$(printf '%s' "$sc" | jq -r '[.own[] | select(.key=="SUPER + H")][0].description')"
check "…the command lands in the command field" "voxtype record toggle" \
  "$(printf '%s' "$sc" | jq -r '[.own[] | select(.key=="SUPER + H")][0].command')"
check "an unbind is recorded as one" "unbind" \
  "$(printf '%s' "$sc" | jq -r '[.own[] | select(.key=="SUPER + SPACE")][0].kind')"

section "secrets describe themselves without revealing anything"
mkdir -p "$HOME/.ssh" "$HOME/.config/environment.d"
printf 'PRIVATE KEY MATERIAL\n' > "$HOME/.ssh/id_ed25519"; chmod 600 "$HOME/.ssh/id_ed25519"
printf 'API_TOKEN=sk-supersecret-value\nOTHER=2\n' > "$HOME/.config/environment.d/60-secrets.conf"
sj=$(build_secrets_json)
check "valid JSON" "0" "$(printf '%s' "$sj" | jq empty >/dev/null 2>&1; echo $?)"
check "a private key is labelled as one" "private key" \
  "$(printf '%s' "$sj" | jq -r '[.[] | select(.id=="ssh/id_ed25519")][0].kind')"
check "its mode is reported"             "600" \
  "$(printf '%s' "$sj" | jq -r '[.[] | select(.id=="ssh/id_ed25519")][0].mode')"
check "an env file reports how many variables it defines" "2" \
  "$(printf '%s' "$sj" | jq -r '[.[] | select(.id=="env/60-secrets.conf")][0].var_count')"
check "…by name"  "true" \
  "$(printf '%s' "$sj" | jq -r '[.[] | select(.id=="env/60-secrets.conf")][0].vars | index("API_TOKEN") != null')"
# The one thing this payload must never carry.
check "no value ever reaches the panel" "0" "$(printf '%s' "$sj" | grep -c 'supersecret' || true)"
check "…nor any key material"           "0" "$(printf '%s' "$sj" | grep -c 'PRIVATE KEY' || true)"
# Same rule for the diff the panel renders inline.
core_backup >/dev/null 2>&1
printf 'API_TOKEN=sk-rotated-value\n' > "$HOME/.config/environment.d/60-secrets.conf"
d=$(core_diff env/60-secrets.conf repo)
check_contains "a changed secret says so" "differs from the copy in your repo" "$d"
check "…and shows nothing of it" "0" "$(printf '%s' "$d" | grep -c 'sk-' || true)"

section "status --json is well-formed"
st=$(core_status --json 2>/dev/null)
check "valid JSON"        "0"    "$(printf '%s' "$st" | jq empty >/dev/null 2>&1; echo $?)"
check "reports initialized" "true" "$(printf '%s' "$st" | jq -r '.initialized')"
for field in branch remote remote_name repo_dir home machine plugin_version last_save dirty untracked ahead behind configs secrets settings categories setting_groups machines; do
  check "status carries $field" "true" "$(printf '%s' "$st" | jq --arg f "$field" 'has($f)')"
done

section "the shipped list is universal; the personal list is the user's"
# Nothing in the public plugin's MANIFEST may name one person's script, one
# person's project, or one person's hardware quirk. Every marketplace installer
# gets this list, and a stranger seeing "bin/omarchy-audit" as a missing file
# has no idea what it is or why the tool wants it.
personal=0
for entry in "${MANIFEST[@]}"; do
  case "${entry%%:*}" in
    */omarchy-audit|*/hypr-refresh-auto|*/cbm-*|*/mise.toml|*/fprintd-*|*/omarchy-audit-ignore|*/audit-config.hook)
      personal=$((personal+1)); echo "    ${entry%%:*} is one person's, not everyone's" ;;
  esac
done
check "the shipped manifest names nobody in particular" "0" "$personal"
check "~/dev/mise.toml is gone for good, not migrated" "0" \
  "$(printf '%s\n' "${LEGACY_PERSONAL[@]}" "${LEGACY_PERSONAL_SECRETS[@]}" | grep -c 'mise.toml' || true)"

section "upgrading a 0.6 repo keeps tracking what it tracked"
# The migration hazard this release creates: those entries were in MANIFEST, so
# an upgraded repo already holds copies of them. If the new core simply forgot
# them, the very next save would see the copies as untracked and PRUNE them —
# the user's backup deleted by an upgrade.
mkdir -p "$HOME/.local/bin" "$CONFIG_DIR/bin"
printf 'my audit script\n' > "$HOME/.local/bin/omarchy-audit"
printf 'my audit script\n' > "$CONFIG_DIR/bin/omarchy-audit"
rm -f "$USER_TRACK_FILE"
load_user_manifest
check_true "a 0.6 entry is still tracked before any migration runs" \
  is_tracked_path "$HOME/.local/bin/omarchy-audit"
ensure_track_file
check_true "…and the migration writes it into the user's own list" \
  test -f "$USER_TRACK_FILE"
check "…naming it" "1" "$(grep -c 'omarchy-audit' "$USER_TRACK_FILE" || true)"
check_true "…and it is still tracked afterwards" is_tracked_path "$HOME/.local/bin/omarchy-audit"
check "it is the user's entry now, not the plugin's" "0" \
  "$(printf '%s\n' "${MANIFEST[@]}" | grep -c 'omarchy-audit' || true)"
core_backup >/dev/null 2>&1
check_true "the save does NOT prune the copy it already had" \
  test -f "$CONFIG_DIR/bin/omarchy-audit"

section "adding a file of your own"
printf 'hello\n' > "$HOME/.config/mine.conf"
core_track "$HOME/.config/mine.conf" >/dev/null 2>&1
check "the name in the repo is derived the way the shipped ones are" "mine.conf" \
  "$(derive_rel "$HOME/.config/mine.conf")"
check "…and for a script"     "bin/thing"   "$(derive_rel "$HOME/.local/bin/thing")"
check "…and a bare dotfile"   "home/bashrc" "$(derive_rel "$HOME/.bashrc")"
check "…and one with a directory" "ssh/config" "$(derive_rel "$HOME/.ssh/config")"
check_true "it is tracked" is_tracked_path "$HOME/.config/mine.conf"
core_backup >/dev/null 2>&1
check_true "…and saved" test -f "$CONFIG_DIR/mine.conf"
cj=$(build_configs_json)
check "the panel says it came from the user" "user" \
  "$(printf '%s' "$cj" | jq -r '[.[] | select(.id=="mine.conf")][0].source')"
check_false "tracking a symlink is refused" core_track_symlink_probe
ln -sf "$HOME/.config/mine.conf" "$HOME/.config/mine-link.conf"
check_false "…really refused" core_track "$HOME/.config/mine-link.conf"
check_false "tracking something that is not there is refused" core_track "$HOME/.config/nope.conf"

section "dropping one of your own"
check_false "a file the plugin ships with cannot be untracked" core_untrack hypr/input.lua
check_contains "…it says to switch it off instead" "scope" \
  "$(core_untrack hypr/input.lua 2>&1)"
core_untrack mine.conf >/dev/null 2>&1
check_false "the entry is gone" is_tracked_path "$HOME/.config/mine.conf"
check_false "…and so is the copy in the repo" test -f "$CONFIG_DIR/mine.conf"

section "tracking a whole directory"
mkdir -p "$HOME/.config/tree/sub" "$HOME/.config/tree/.git"
printf 'a\n' > "$HOME/.config/tree/a.lua"
printf 'b\n' > "$HOME/.config/tree/sub/b.lua"
printf 'objects\n' > "$HOME/.config/tree/.git/HEAD"
core_track "$HOME/.config/tree" >/dev/null 2>&1
check "a directory keeps its trailing slash as its id" "tree/" \
  "$(printf '%s\n' "${USER_MANIFEST[@]}" | grep -o 'tree/$' | head -n1)"
core_backup >/dev/null 2>&1
check_true "every file under it is saved" test -f "$CONFIG_DIR/tree/sub/b.lua"
check "…and .git inside it is not — a repo is not backed up by copying it" "0" \
  "$(find "$CONFIG_DIR/tree" -name HEAD 2>/dev/null | wc -l)"
check "the panel counts the files" "2" \
  "$(build_configs_json | jq -r '[.[] | select(.id=="tree/")][0].nfiles')"
check "…and reports it as a directory" "true" \
  "$(build_configs_json | jq -r '[.[] | select(.id=="tree/")][0].is_dir')"
check "copied in but not committed is still unsaved" "unsaved" \
  "$(build_configs_json | jq -r '[.[] | select(.id=="tree/")][0].sync_state')"
git -C "$REPO_DIR" add -A >/dev/null 2>&1; git -C "$REPO_DIR" commit -qm "tree" >/dev/null 2>&1
check "…once committed" "unpushed" \
  "$(build_configs_json | jq -r '[.[] | select(.id=="tree/")][0].sync_state')"

section "a change inside a tracked tree is noticed, and un-noticing is automatic"
printf 'b changed\n' > "$HOME/.config/tree/sub/b.lua"
check "editing one file in the tree marks the whole entry unsaved" "unsaved" \
  "$(build_configs_json | jq -r '[.[] | select(.id=="tree/")][0].sync_state')"
printf 'b\n' > "$HOME/.config/tree/sub/b.lua"
check "…and putting it back clears it, with no save in between" "unpushed" \
  "$(build_configs_json | jq -r '[.[] | select(.id=="tree/")][0].sync_state')"
printf 'c\n' > "$HOME/.config/tree/c.lua"
check "adding a file to the tree counts as a change" "unsaved" \
  "$(build_configs_json | jq -r '[.[] | select(.id=="tree/")][0].sync_state')"
rm -f "$HOME/.config/tree/c.lua"
check "…and removing it again clears the warning" "unpushed" \
  "$(build_configs_json | jq -r '[.[] | select(.id=="tree/")][0].sync_state')"

section "the prune pass leaves tracked trees alone"
# The trap a directory entry sets for the prune pass: every file under it is
# untracked when the list is read one entry at a time, so without the prefix
# rule a save would delete the whole tree it had just written.
core_backup >/dev/null 2>&1
check_true "the tree survives a second save" test -f "$CONFIG_DIR/tree/sub/b.lua"
check "the tree's own mirroring drops what the machine deleted" "0" \
  "$(find "$CONFIG_DIR/tree" -name 'c.lua' 2>/dev/null | wc -l)"

section "restoring a directory"
rm -rf "$HOME/.config/tree/sub"
check_false "a file inside it is gone from the machine" test -f "$HOME/.config/tree/sub/b.lua"
core_restore_file "tree/" >/dev/null 2>&1
check_true "restore-file brings the whole tree back" test -f "$HOME/.config/tree/sub/b.lua"
check "…with the content it had" "b" "$(cat "$HOME/.config/tree/sub/b.lua" 2>/dev/null)"
check_contains "the plan lists it as a tree, slash and all" "/tree/|" \
  "$(plan_for_category "$(category_for_rel 'tree/')")"
d=$(core_diff "tree/")
check_contains "its diff summarises rather than dumps" "identical to the copy in your repo" "$d"

section "themes travel as URLs, not as 556 MB of wallpaper"
mkdir -p "$STATE_DIR"
printf '# name\torigin\nmine\thttps://example.com/omarchy-mine-theme\n' > "$STATE_DIR/omarchy-themes.txt"
check "a theme this machine lacks is reported with its origin" \
  "mine	https://example.com/omarchy-mine-theme" "$(missing_themes)"
mkdir -p "$HOME/.config/omarchy/themes/mine"
check "…and not once it is installed" "" "$(missing_themes)"
check "a theme with no origin is never proposed for install" "" \
  "$(printf 'other\t-\n' >> "$STATE_DIR/omarchy-themes.txt"; missing_themes)"

section "suggest proposes, and refuses to propose noise"
mkdir -p "$HOME/.config/appstate" "$HOME/.local/bin"
printf 'x\n' > "$HOME/.config/appstate/Local State"
printf 'y\n' > "$HOME/.config/appstate/settings.json"
printf '#!/bin/bash\nexec mise x "gh" -- "gh" "$@"\n' > "$HOME/.local/bin/gh"; chmod +x "$HOME/.local/bin/gh"
printf 'real\n' > "$HOME/.config/candidate.toml"
ln -sf "$HOME/.config/candidate.toml" "$HOME/.config/linked.toml"
sg=$(core_suggest)
check_contains "a config file you wrote is proposed" "candidate.toml" "$sg"
check "an application's own state directory is not" "0" "$(grep -c 'appstate' <<<"$sg" || true)"
check "a mise shim is not"  "0" "$(grep -c '/.local/bin/gh$' <<<"$sg" || true)"
check "a symlink is not"    "0" "$(grep -c 'linked.toml' <<<"$sg" || true)"
check "something already tracked is not" "0" "$(grep -c 'hypr/input.lua' <<<"$sg" || true)"
mkdir -p "$HOME/.config/gh"; printf 'token: abc\n' > "$HOME/.config/gh/hosts.yml"
check "a file that holds a credential is proposed as a secret" "secret" \
  "$(core_suggest | awk -F'\t' '$1 ~ /hosts.yml/ {print $4}')"
check "suggest --json is valid JSON" "0" \
  "$(core_suggest --json | jq empty >/dev/null 2>&1; echo $?)"

section "every writer of the tracked list migrates first"
# The same rule ensure_scope_file exists for, and the same failure if it is
# broken: load_user_manifest's fallback invents a list, and a read-modify-write
# against an invented list is a delete.
for fn in core_track core_untrack; do
  body=$(declare -f "$fn")
  check "$fn calls ensure_track_file before writing" "1" \
    "$(grep -c 'ensure_track_file' <<<"$body" || true)"
  check "…and before write_track_file" "1" \
    "$(awk '/ensure_track_file/{seen=1} /write_track_file/{if(seen) print "1"; exit}' <<<"$body" | head -n1 || true)"
done

section "an older machine never deletes what a newer one tracks"
# The premise of this plugin is two machines sharing one repo, and they are not
# upgraded on the same day. The prune pass deletes whatever is not in the
# RUNNING version's list — so the machine still on the old release silently
# deleted every file the upgraded one tracked, on its next save. This actually
# happened while building 0.7.0: the ~/.config/nvim tree the new code had just
# saved was gone by the time anyone looked.
check "a save records the version that wrote the repo" "$(running_version)" \
  "$(repo_written_by)"
check_true  "0.6.9 is older than 0.7.0"  version_lt 0.6.9 0.7.0
check_true  "0.7.0 is older than 0.10.0" version_lt 0.7.0 0.10.0
check_false "a version is not older than itself" version_lt 0.7.0 0.7.0
check_true "a client at the repo's own version may prune" may_prune
mkdir -p "$CONFIG_DIR/from-the-future"
printf 'z\n' > "$CONFIG_DIR/from-the-future/thing.conf"
printf '99.0.0\n' > "$REPO_VERSION_FILE"
check_false "a client older than the repo may not prune" may_prune
core_backup >/dev/null 2>&1
check_true "…so a newer version's file survives its save" \
  test -f "$CONFIG_DIR/from-the-future/thing.conf"
check "…and the recorded version is never lowered" "99.0.0" "$(repo_written_by)"
rm -rf "$CONFIG_DIR/from-the-future"
printf '%s\n' "$(running_version)" > "$REPO_VERSION_FILE"
core_backup >/dev/null 2>&1
check_true "back at its own version it prunes again" may_prune

section "the README states the numbers this code actually ships"
# A README is the first thing a stranger reads and the last thing anybody
# updates. "50 tracked paths" was this developer's own count — 41 shipped plus
# nine of their own — presented to every reader as what they would get.
readme="$HERE/../README.md"
check "the tracked-path count matches MANIFEST + SECRETS_MANIFEST" "1" \
  "$(grep -c "\*\*$(( ${#MANIFEST[@]} + ${#SECRETS_MANIFEST[@]} )) paths out of the box\*\*" "$readme" || true)"
check "…and it names the split" "1" \
  "$(grep -c "${#MANIFEST[@]} configs and ${#SECRETS_MANIFEST[@]} secrets" "$readme" || true)"
check "the settings count matches the registry" "1" \
  "$(grep -c "\*\*${#SETTINGS[@]} settings from the panel\*\*" "$readme" || true)"
# Guard 7 in run-all.sh catches the QML testing for a state the core never
# emits. This is the other direction, which is the one that fails silently: a
# NEW state added to the core, never taught to stateGlyph, falls through to its
# final `return` and renders as "saved on GitHub" — the calmest badge there is,
# on the row that needed attention.
panel="$HERE/../Panel.qml"
core_states=$(grep -oE 'sync_state="[a-z]+"' "$HERE/../bin/replicant-core.sh" |
              sed -e 's/sync_state="//' -e 's/"//' | sort -u)
unrendered=0
for st in $core_states; do
  grep -q "st === \"$st\"" "$panel" || { unrendered=$((unrendered+1)); echo "    core emits '$st' and stateGlyph has no case for it"; }
done
check "every state the core emits has a badge in the panel" "0" "$unrendered"
check "…and the states are the six that are documented" "default missing off saved unpushed unsaved" \
  "$(echo $core_states)"

section "a secret you added yourself is still a secret"
# Everything that protects a secret used to key on the path prefix ssh/ or env/,
# which was true for the three the plugin ships. `track --secret` then let a
# user add one under any name, and every one of those rules quietly stopped
# applying: ~/.config/gh/hosts.yml derives to "gh/hosts.yml".
mkdir -p "$HOME/.config/gh"
printf 'oauth_token: ghp_PLANTED_TOKEN_VALUE\n' > "$HOME/.config/gh/hosts.yml"
core_track "$HOME/.config/gh/hosts.yml" --secret >/dev/null 2>&1
check_true "it is recorded as a secret, not as config" is_secret_rel gh/hosts.yml
check_false "…and a normal file is not"                is_secret_rel hypr/input.lua
# Saved to one path and read from another is the bug hard rule 9 exists for:
# the panel called a saved file unsaved, and revert-to-repo never found it.
check "it is written and read at the SAME path" "$SECRETS_DIR/gh/hosts.yml" \
  "$(repo_copy_for_rel gh/hosts.yml)"
check "…and restored at 600, not 644"  "600" "$(restore_mode_for gh/hosts.yml)"
core_backup >/dev/null 2>&1
check_true "the copy really is under secrets/" test -f "$SECRETS_DIR/gh/hosts.yml"
printf 'oauth_token: ghp_ROTATED_TOKEN_VALUE\n' > "$HOME/.config/gh/hosts.yml"
d=$(core_diff gh/hosts.yml)
check_contains "a changed secret still says only that" "contents are not shown" "$d"
check "…and the token is never rendered" "0" "$(printf '%s' "$d" | grep -c 'ghp_' || true)"
check "…in either direction" "0" "$(printf '%s' "$(core_diff gh/hosts.yml repo)" | grep -c 'ghp_' || true)"
check "nor anywhere in the panel payload" "0" \
  "$(printf '%s%s' "$(build_configs_json)" "$(build_secrets_json)" | grep -c 'ghp_' || true)"
core_untrack gh/hosts.yml >/dev/null 2>&1

section "changing a directory's scope moves the tree, now, not eventually"
# Changing a file's scope moves the copy the repo holds so the backup is never
# stranded at the old path. The guard was -f, so a tracked DIRECTORY was never
# moved: the tree stayed in config/ while repo_path_for pointed at
# profiles/<profile>/, and until the next save the panel called a saved tree
# unsaved and revert-to-repo could not find it.
mkdir -p "$HOME/.config/tree2/sub"
printf 'a\n' > "$HOME/.config/tree2/a.lua"
printf 'b\n' > "$HOME/.config/tree2/sub/b.lua"
core_track "$HOME/.config/tree2" >/dev/null 2>&1
core_backup >/dev/null 2>&1
check "the tree starts shared" "2" "$(find "$CONFIG_DIR/tree2" -type f 2>/dev/null | wc -l)"
core_scope "tree2/" profile >/dev/null 2>&1
check "…and is at the profile path the moment the scope changes" "2" \
  "$(find "$REPO_DIR/profiles/$(current_profile)/config/tree2" -type f 2>/dev/null | wc -l)"
check "…with nothing stranded behind it" "0" \
  "$(find "$CONFIG_DIR/tree2" -type f 2>/dev/null | wc -l)"
check "…so repo_copy_for_rel finds it" "$REPO_DIR/profiles/$(current_profile)/config/tree2/" \
  "$(repo_copy_for_rel 'tree2/')"
# The content is where repo_path_for says it is, which is the thing that broke.
# The row still reads "unsaved" here and rightly so — the move is a change git
# has not been asked to commit yet, and cmd_scope is what commits it.
check_true "…and the copy there matches the machine" \
  tree_same "$(repo_copy_for_rel 'tree2/')" "$HOME/.config/tree2"
core_scope "tree2/" shared >/dev/null 2>&1
check "moving it back works the same way" "2" "$(find "$CONFIG_DIR/tree2" -type f 2>/dev/null | wc -l)"
check_false "…and never writes outside the repo" move_repo_copy "$CONFIG_DIR/tree2" "$HOME/escaped"
check_true "…leaving the source where it was" test -d "$CONFIG_DIR/tree2"
core_untrack "tree2/" >/dev/null 2>&1

section "track refuses what would own the same path twice"
mkdir -p "$HOME/.config/owned/deep"
printf 'x\n' > "$HOME/.config/owned/a.conf"
printf 'y\n' > "$HOME/.config/owned/deep/b.conf"
core_track "$HOME/.config/owned" >/dev/null 2>&1
check_true "the directory is tracked" is_tracked_path "$HOME/.config/owned/a.conf"
# Two entries owning one path in the repo: the panel drew the row twice, and
# untracking the file would have deleted the copy the directory still owns.
out=$(core_track "$HOME/.config/owned/a.conf" 2>&1)
check_contains "a file inside it is refused" "already covered by the tracked directory" "$out"
check "…and nothing was added" "1" \
  "$(printf '%s\n' "${USER_MANIFEST[@]}" | grep -c 'owned' || true)"
# The other way round: a directory that swallows a file listed on its own.
printf 'z\n' > "$HOME/.config/solo.conf"
core_track "$HOME/.config/solo.conf" >/dev/null 2>&1
out=$(core_track "$HOME/.config/" 2>&1 || true)
check_contains "a directory that swallows a listed file is refused" "would swallow" "$out"
check_false "…and it really was not added" is_tracked_path "$HOME/.config/unrelated-thing.conf"
core_untrack "solo.conf" >/dev/null 2>&1
core_untrack "owned/" >/dev/null 2>&1

section "track will not quietly put a hundred megabytes in a git repo"
mkdir -p "$HOME/.config/huge"
for i in $(seq 1 420); do printf 'x\n' > "$HOME/.config/huge/f$i.conf"; done
out=$(core_track "$HOME/.config/huge" 2>&1 || true)
check_contains "a big tree is refused, with the number" "holds 420 files" "$out"
check_contains "…and says what to do instead" "narrower directory" "$out"
check_false "…and is not tracked" is_tracked_path "$HOME/.config/huge/f1.conf"
rm -rf "$HOME/.config/huge"

summary
