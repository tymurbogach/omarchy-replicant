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

section "resolving a tracked id back to a real file"
check "a manifest id"        "$HOME/.config/hypr/input.lua" "$(resolve_manifest_src hypr/input.lua)"
check "a secret id"          "$HOME/.ssh/id_ed25519"        "$(resolve_manifest_src ssh/id_ed25519)"
check "an auto-detected id"  "$HOME/.config/omarchy/demo.json" "$(resolve_manifest_src plugins/demo.json)"
check_false "an unknown id"  resolve_manifest_src not/a/real/one

section "the three sync states, driven for real through git"
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
check "committed but never pushed → modified" "modified" "$(state_of hypr/input.lua)"

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
check "changed since the last save → modified" "modified" "$(state_of hypr/input.lua)"

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
check "sync_state is one of the four" "0" \
  "$(printf '%s' "$configs" | jq '[.[] | select(.sync_state | IN("default","modified","saved","off") | not)] | length')"

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
for entry in "${MANIFEST[@]}"; do
  rel="${entry##*:}"
  [[ "$rel" == "omarchy/theme.name" ]] && continue      # applied, never copied
  [[ -f "$CONFIG_DIR/$rel" ]] || continue               # not saved on this machine
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
for field in branch remote remote_name repo_dir machine plugin_version last_save dirty untracked ahead behind configs secrets settings categories setting_groups machines; do
  check "status carries $field" "true" "$(printf '%s' "$st" | jq --arg f "$field" 'has($f)')"
done

summary
