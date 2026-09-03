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
check "sync_state is one of the three" "0" \
  "$(printf '%s' "$configs" | jq '[.[] | select(.sync_state | IN("default","modified","saved") | not)] | length')"

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

section "status --json is well-formed"
st=$(core_status --json 2>/dev/null)
check "valid JSON"        "0"    "$(printf '%s' "$st" | jq empty >/dev/null 2>&1; echo $?)"
check "reports initialized" "true" "$(printf '%s' "$st" | jq -r '.initialized')"
for field in branch remote remote_name repo_dir dirty untracked ahead behind configs secrets settings; do
  check "status carries $field" "true" "$(printf '%s' "$st" | jq --arg f "$field" 'has($f)')"
done

summary
