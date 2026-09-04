#!/bin/bash
# replicant-core.sh — core logic for the omarchy-replicant plugin (savegame pattern
# ported from ~/omarchy_thinkpad). Doesn't reinvent: MANIFEST/SECRETS_MANIFEST +
# install-with-backup + scan-secrets + backup/savegame/restore.
# Located at: ~/.config/omarchy/plugins/io.github.tymurbogach.omarchy-replicant/bin/
set -euo pipefail

REAL_CORE="$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
PLUGIN_DIR="$(cd -- "$(dirname -- "$REAL_CORE")/.." && pwd)"
# User's target repo (separate from the plugin's own code): private, savegame layout
REPLICANT_HOME="${OMARCHY_REPLICANT_HOME:-$HOME/.local/share/omarchy-replicant}"
REPO_DIR="$REPLICANT_HOME/repo"
CONFIG_DIR="$REPO_DIR/config"
SECRETS_DIR="$REPO_DIR/secrets"
# One repo, several machines. state/ is an inventory OF A MACHINE — its
# packages, its services, its plugins — so a shared state/ meant the desktop and
# the laptop overwrote each other's inventory on every save, and every pull
# looked like a change. Scoping it by hostname makes two machines additive
# instead of competing.
MACHINE="${REPLICANT_MACHINE:-$(hostnamectl --static 2>/dev/null || hostname 2>/dev/null || echo unknown)}"
STATE_ROOT="$REPO_DIR/state"
STATE_DIR="$STATE_ROOT/$MACHINE"

# Overridable so the tests can exercise the reader and the writer without a
# root-owned file; in normal use it is exactly where logind looks.
LOGIND_DROPIN="${REPLICANT_LOGIND_DROPIN:-/etc/systemd/logind.conf.d/99-lid.conf}"

TEMPLATES_DIR="$REPO_DIR/templates"
GITHOOKS_DIR="$REPO_DIR/.githooks"

# ─── CORE MANIFEST — what any Omarchy machine plausibly has ─────────────────
# One-way direction: system -> repo. Only your own stuff, or what differs from
# default. Anything identical to the default isn't tracked: recover it with
# omarchy-refresh-config.
#
# This list is SHIPPED, in public plugin source, and is therefore only the paths
# a stranger installing from the marketplace would recognise. It used to carry
# one person's Claude hooks, their audit script and their fingerprint-reader
# unit — which every installer then saw as a screenful of "missing" rows for
# files they had never heard of, while none of their OWN files were tracked at
# all. Anything personal now lives in the user's list (see USER_TRACK_FILE
# below), inside their own repo, where it travels between their machines
# without being published to everybody else's.
#
# A trailing slash makes an entry a DIRECTORY (see is_dir_entry). Use it only
# for a tree of hand-written config; anything that is really a git clone
# belongs in an inventory instead — see the theme inventory in core_backup,
# which records a URL rather than copying 556 MB of wallpapers into a git repo.
MANIFEST=(
  "$HOME/.bashrc:home/bashrc"
  "$HOME/.bash_profile:home/bash_profile"
  "$HOME/.inputrc:home/inputrc"
  "$HOME/.XCompose:home/XCompose"
  "$HOME/.ssh/config:ssh/config"
  "$HOME/.config/git/config:git/config"
  "$HOME/.claude/settings.json:claude/settings.json"
  "$HOME/.claude/settings.local.json:claude/settings.local.json"
  "$HOME/.claude/.mcp.json:claude/mcp.json"
  "$HOME/.config/Code/User/settings.json:vscode/settings.json"
  "$HOME/.config/mise/config.toml:mise/config.toml"
  "$HOME/.config/nvim/:nvim/"
  "$HOME/.config/hypr/bindings.lua:hypr/bindings.lua"
  "$HOME/.config/hypr/hyprland.lua:hypr/hyprland.lua"
  "$HOME/.config/hypr/input.lua:hypr/input.lua"
  "$HOME/.config/hypr/looknfeel.lua:hypr/looknfeel.lua"
  "$HOME/.config/hypr/monitors.lua:hypr/monitors.lua"
  "$HOME/.config/hypr/autostart.lua:hypr/autostart.lua"
  "$HOME/.config/hypr/hyprlock.conf:hypr/hyprlock.conf"
  "$HOME/.config/hypr/hyprsunset.conf:hypr/hyprsunset.conf"
  "$HOME/.config/hypr/xdph.conf:hypr/xdph.conf"
  "$HOME/.config/xdg-terminals.list:xdg-terminals.list"
  "$HOME/.config/mimeapps.list:mimeapps.list"
  "$HOME/.config/opencode/opencode.json:opencode/opencode.json"
  "$HOME/.config/opencode/tui.json:opencode/tui.json"
  "$HOME/.config/opencode/AGENTS.md:opencode/AGENTS.md"
  "$HOME/.config/omarchy/branding/screensaver.txt:branding/screensaver.txt"
  "$HOME/.config/omarchy/shell.json:omarchy/shell.json"
  "$HOME/.config/omarchy/extensions/omarchy-menu.jsonc:omarchy/extensions/omarchy-menu.jsonc"
  "$HOME/.config/omarchy/shell.toml:omarchy/shell.toml"
  # Outside ~/.config, but they are what makes a machine look like yours:
  # the active theme's name and the editor Omarchy opens config files with.
  # theme.name is restored by re-running `omarchy theme set`, not by copying
  # the file back (see the "theme" group in cmd_restore).
  "$HOME/.local/state/omarchy/current/theme.name:omarchy/theme.name"
  "$HOME/.local/state/omarchy/defaults/editor:omarchy/defaults/editor"
  "$HOME/.config/alacritty/alacritty.toml:alacritty/alacritty.toml"
  "$HOME/.config/foot/foot.ini:foot/foot.ini"
  "$HOME/.config/kitty/kitty.conf:kitty/kitty.conf"
  "$HOME/.config/ghostty/config:ghostty/config"
  "$HOME/.config/starship.toml:starship.toml"
  "$HOME/.config/btop/btop.conf:btop/btop.conf"
  "$HOME/.config/lazygit/config.yml:lazygit/config.yml"
  "/etc/systemd/logind.conf.d/99-lid.conf:etc/99-lid.conf"
  "/etc/systemd/sleep.conf.d/99-hibernate-delay.conf:etc/99-hibernate-delay.conf"
)

SECRETS_MANIFEST=(
  "$HOME/.ssh/id_ed25519:ssh/id_ed25519"
  "$HOME/.ssh/id_ed25519.pub:ssh/id_ed25519.pub"
  "$HOME/.config/environment.d/60-secrets.conf:env/60-secrets.conf"
)

# What the pre-0.7 core tracked that is one person's rather than everyone's.
# Kept only so an existing repo does not silently stop tracking them the day it
# upgrades: ensure_track_file writes whichever of these the repo or the machine
# actually has into the user's own list, and load_user_manifest falls back to
# the same set for reads until that migration runs. Nothing here is offered to
# a fresh install. `~/dev/mise.toml` is deliberately absent — it is a project
# file, not machine config, and is dropped rather than migrated.
LEGACY_PERSONAL=(
  "$HOME/.claude/hooks/cbm-code-discovery-gate:claude/hooks/cbm-code-discovery-gate"
  "$HOME/.claude/hooks/cbm-session-reminder:claude/hooks/cbm-session-reminder"
  "$HOME/.claude/hooks/cbm-subagent-reminder:claude/hooks/cbm-subagent-reminder"
  "$HOME/.config/uwsm/env.d/50-local-bin-priority.sh:uwsm/env.d/50-local-bin-priority.sh"
  "$HOME/.local/bin/hypr-refresh-auto:bin/hypr-refresh-auto"
  "$HOME/.local/bin/omarchy-audit:bin/omarchy-audit"
  "$HOME/.config/omarchy-audit-ignore:omarchy-audit-ignore"
  "$HOME/.config/omarchy/hooks/post-update.d/audit-config.hook:omarchy/hooks/post-update.d/audit-config.hook"
  "/etc/systemd/system/fprintd-resume.service:etc/fprintd-resume.service"
)
LEGACY_PERSONAL_SECRETS=(
  "$HOME/dev/portfolio/.env:env/portfolio.env"
  "$HOME/dev/lazytripz/backend/.env:env/lazytrip-backend.env"
)

# ─── THE USER'S OWN LIST ────────────────────────────────────────────────────
# Everything above ships with the plugin. Everything a particular person wants
# backed up on top of it lives here, in a file inside THEIR repo — the same
# place, and for the same reason, as .replicant-sync and .replicant-profiles:
# "back up my audit script" is a decision about the setup, not about one
# machine, so making it once must be enough for both.
#
# Format, one entry per line:
#
#   ~/.local/bin/my-script                  a file, name in the repo derived
#   ~/.config/foo/bar.conf = foo/bar.conf   a file, name in the repo given
#   ~/.config/nvim/                         a directory (trailing slash)
#   secret ~/dev/app/.env                   stored 600, contents never rendered
#
USER_TRACK_FILE="$REPO_DIR/.replicant-track"
USER_MANIFEST=()
USER_SECRETS=()

# A trailing slash is the whole of the directory/file distinction, on the repo
# side of the entry. It survives every place a rel is passed around as a string.
is_dir_entry() { [[ "$1" == */ ]]; }

# derive_rel <absolute-path> — where an entry lands in the repo when the user
# does not say. It reproduces the naming the shipped MANIFEST already uses, so
# a tracked ~/.config/foo/bar.conf sits next to the shipped ones rather than in
# a parallel scheme: ~/.config/X -> X, ~/.local/bin/X -> bin/X, ~/.X -> home/X.
derive_rel() {
  local p="$1" rel slash=""
  [[ "$p" == */ ]] && { slash="/"; p="${p%/}"; }
  case "$p" in
    "$HOME/.config/"*)     rel="${p#"$HOME"/.config/}" ;;
    "$HOME/.local/bin/"*)  rel="bin/${p#"$HOME"/.local/bin/}" ;;
    "$HOME/.local/share/"*) rel="share/${p#"$HOME"/.local/share/}" ;;
    "$HOME/.local/state/"*) rel="state-files/${p#"$HOME"/.local/state/}" ;;
    "$HOME/."*)
      rel="${p#"$HOME"/.}"
      # ~/.ssh/config keeps its directory (ssh/config); ~/.bashrc, which has
      # none, would otherwise land in the repo root as a bare "bashrc".
      [[ "$rel" == */* ]] || rel="home/$rel" ;;
    "$HOME/"*)             rel="home/${p#"$HOME"/}" ;;
    /etc/*)                rel="etc/${p##*/}" ;;
    *)                     rel="misc/${p##*/}" ;;
  esac
  printf '%s%s\n' "$rel" "$slash"
}

read_track_lines() {
  [[ -f "$USER_TRACK_FILE" ]] || return 0
  sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$USER_TRACK_FILE" 2>/dev/null || true
}

# parse_track_line <line> -> "kind<TAB>src<TAB>rel", or nothing if unusable.
parse_track_line() {
  local line="$1" kind=config src rel
  line="${line#"${line%%[![:space:]]*}"}"
  if [[ "$line" == secret[[:space:]]* ]]; then kind=secret; line="${line#secret}"; fi
  if [[ "$line" == *=* ]]; then src="${line%%=*}"; rel="${line#*=}"; else src="$line"; rel=""; fi
  # Trim, but only at the ends: a path may legitimately contain a space.
  src="${src#"${src%%[![:space:]]*}"}"; src="${src%"${src##*[![:space:]]}"}"
  rel="${rel#"${rel%%[![:space:]]*}"}"; rel="${rel%"${rel##*[![:space:]]}"}"
  [[ -n "$src" ]] || return 0
  case "$src" in "~/"*) src="$HOME/${src#\~/}" ;; "\$HOME/"*) src="$HOME/${src#\$HOME/}" ;; esac
  [[ "$src" == /* ]] || return 0
  [[ -n "$rel" ]] || rel=$(derive_rel "$src")
  # A directory on one side is a directory on both, whichever side said so.
  if [[ "$src" == */ || "$rel" == */ ]]; then src="${src%/}/"; rel="${rel%/}/"; fi
  printf '%s\t%s\t%s\n' "$kind" "$src" "$rel"
}

rebuild_tracked() {
  TRACKED=("${MANIFEST[@]}" ${USER_MANIFEST[@]+"${USER_MANIFEST[@]}"})
  TRACKED_SECRETS=("${SECRETS_MANIFEST[@]}" ${USER_SECRETS[@]+"${USER_SECRETS[@]}"})
}

# Reading has a fallback; writing needs the real migration (ensure_track_file).
# A repo written before 0.7 has no .replicant-track, but its config/ is full of
# files the old core tracked — so until the migration runs we read the same set
# the migration is going to write. Without this, the first command after an
# upgrade would see those files as untracked and core_backup's prune pass would
# delete every one of them from the repo.
load_user_manifest() {
  local line kind src rel
  USER_MANIFEST=(); USER_SECRETS=()
  if [[ -f "$USER_TRACK_FILE" ]]; then
    while IFS= read -r line; do
      IFS=$'\t' read -r kind src rel < <(parse_track_line "$line")
      [[ -n "${rel:-}" ]] || continue
      if [[ "$kind" == secret ]]; then USER_SECRETS+=("$src:$rel"); else USER_MANIFEST+=("$src:$rel"); fi
    done < <(read_track_lines)
  else
    local entry
    for entry in "${LEGACY_PERSONAL[@]}"; do
      legacy_personal_present "$entry" && USER_MANIFEST+=("$entry")
    done
    for entry in "${LEGACY_PERSONAL_SECRETS[@]}"; do
      [[ -f "${entry%%:*}" || -f "$SECRETS_DIR/${entry##*:}" ]] && USER_SECRETS+=("$entry")
    done
  fi
  rebuild_tracked
}

# A pre-0.7 entry counts as this user's only if the repo already holds a copy or
# the machine still has the file. Deliberately blunt about where the copy might
# be: this runs before scope_for is defined, so it looks under both roots rather
# than asking repo_path_for which one applies.
legacy_personal_present() {
  local src="${1%%:*}" rel="${1##*:}" p
  [[ -e "$src" ]] && return 0
  [[ -e "$CONFIG_DIR/$rel" ]] && return 0
  for p in "$REPO_DIR"/profiles/*/config/"$rel"; do [[ -e "$p" ]] && return 0; done
  return 1
}

load_user_manifest

# ─── CATEGORIES — how the panel files everything, and how each is put back ───
# The panel shows one collapsed card per category instead of one long list of
# 40 files, so nothing needs a long scroll. `method` is the honest answer to
# "what will Replicant actually run to restore this?" — it is shown in the UI
# rather than hidden in the code, because using the Omarchy-sanctioned path
# (omarchy theme set, omarchy plugin add, hyprctl reload) instead of blindly
# copying files back is the whole point of this plugin.
#
# Format: "id|icon|label|description|method"
CATEGORIES=(
  "shortcuts|󰌌|Shortcuts|Your keybinding overrides, layered on top of Omarchy's defaults|Copied back, then hyprctl reload"
  "appearance|󰏘|Appearance|Theme, look & feel, fonts, interface density and branding|Theme re-applied with omarchy theme set"
  "desktop|󰍹|Desktop & bar|The Omarchy shell: bar layout, widgets, menu and idle behaviour|Written to shell.json / shell.toml, which the shell watches live"
  "hyprland|󰖯|Hyprland|Input, monitors, autostart, lock screen and night light|Copied back, then hyprctl reload and a config-error check"
  "terminal|󰆍|Terminal & shell|Alacritty, foot, the default terminal, bashrc and compose keys|Copied back, then omarchy restart terminal"
  "development|󰅴|Development|git, editors, Claude and opencode, mise, VS Code|Copied back; nothing needs restarting"
  "secrets|󰌆|Secrets & keys|SSH keys, tokens and .env files — private, mode 600|Copied back as mode 600; contents are never printed"
  "plugins|󰐱|Plugins|Plugin settings, plus every installed plugin's id and git origin|Reinstalled with omarchy plugin add, then their settings copied back"
  "scripts|󰈙|Scripts|Your own helper scripts under ~/.local/bin and Omarchy hooks|Copied back with the executable bit kept"
  "system|󰋊|System|systemd drop-ins for lid, sleep and fingerprint|Copied back with sudo, then systemctl daemon-reload"
  "other|󰈔|Other|Anything else you asked Replicant to track|Copied back as-is"
)
CATEGORY_ORDER=(shortcuts appearance desktop hyprland terminal development secrets plugins scripts system other)

category_field() { local -a f; IFS='|' read -ra f <<<"$1"; printf '%s' "${f[$(($2 - 1))]:-}"; }
find_category() {
  local id="$1" entry
  for entry in "${CATEGORIES[@]}"; do
    [[ "$(category_field "$entry" 1)" == "$id" ]] && { printf '%s\n' "$entry"; return 0; }
  done
  return 1
}

# category_for_rel <repo-relative-id> — one place deciding where a tracked file
# shows up. It used to live inline in build_configs_json, which meant the CLI
# and the panel could disagree about what "appearance" meant.
category_for_rel() {
  case "$1" in
    hypr/bindings.lua)                                 echo shortcuts ;;
    hypr/looknfeel.lua|omarchy/theme.name|omarchy/shell.toml|branding/*) echo appearance ;;
    omarchy/shell.json|omarchy/extensions/*)           echo desktop ;;
    hypr/*)                                            echo hyprland ;;
    alacritty/*|foot/*|kitty/*|ghostty/*|xdg-terminals.list|home/*) echo terminal ;;
    git/*|vscode/*|mise/*|claude/*|opencode/*|dev/*|nvim/*|nvim/|omarchy/defaults/*) echo development ;;
    ssh/*|env/*)                                       echo secrets ;;
    plugins/*)                                         echo plugins ;;
    bin/*|omarchy/hooks/*|omarchy-audit-ignore)        echo scripts ;;
    etc/*|uwsm/*|systemd/*)                            echo system ;;
    mimeapps.list)                                     echo desktop ;;
    starship.toml|btop/*|lazygit/*)                    echo terminal ;;
    *)                                                 echo other ;;
  esac
}

build_categories_json() {
  local entries=() entry
  local id
  for id in "${CATEGORY_ORDER[@]}"; do
    entry=$(find_category "$id") || continue
    entries+=("$(jq -nc --arg id "$id" \
      --arg icon "$(category_field "$entry" 2)" \
      --arg label "$(category_field "$entry" 3)" \
      --arg description "$(category_field "$entry" 4)" \
      --arg method "$(category_field "$entry" 5)" \
      '{id:$id,icon:$icon,label:$label,description:$description,method:$method}')")
  done
  printf '%s\n' "${entries[@]}" | jq -s '.'
}

# ─── Profiles and what each machine syncs ───────────────────────────────────
# One repo, more than one machine, and they are not the same machine. A desktop
# and a laptop want the same shell, the same keybindings and the same git
# identity — and emphatically NOT the same monitor layout, touchpad settings or
# lid behaviour. So every tracked file carries a scope:
#
#   shared   (default) one copy in config/, every machine saves and restores it
#   profile  a copy per profile in profiles/<profile>/config/, so the desktop
#            and the laptop each keep their own and neither overwrites the other
#   off      not saved from here, not restored onto here, and whatever copy the
#            repo already holds is left exactly as it is
#
# "profile" is the one that makes two machines practical. Switching monitors.lua
# off means nobody gets a backup of it; scoping it to a profile means both
# machines get one, they just don't get each OTHER's.
#
# Both lists live in the repo rather than ~/.local/share, because "monitors are
# machine-specific" is a fact about the setup, not about one machine: decide it
# once, and every machine sharing the repo honours it.
SCOPE_FILE="$REPO_DIR/.replicant-sync"
PROFILE_FILE="$REPO_DIR/.replicant-profiles"
LEGACY_EXCLUDE_FILE="$REPO_DIR/.replicant-exclude"

# Seeded on a fresh repo. Not hardcoded rules: they are written into a file the
# user can see, edit, and change from the panel. These are the files that are
# *about the hardware*, which is exactly what a profile is for.
# Only files that describe the hardware itself. hypr/input.lua deliberately is
# NOT here: it carries the keyboard layout and repeat rate, which you do want on
# both machines, alongside a few touchpad keys a desktop simply ignores.
# Splitting it per profile would cost more than it saves.
DEFAULT_SCOPES=(
  "hypr/monitors.lua=profile"
  "etc/99-lid.conf=profile"
  "etc/99-hibernate-delay.conf=profile"
)

# A machine with no explicit assignment guesses from its own chassis. Guessing
# is safe here: the guess only picks WHICH profile directory this machine reads
# and writes, and `profile set` overrides it permanently.
guess_profile() {
  if command -v omarchy-hw-laptop >/dev/null 2>&1; then
    omarchy-hw-laptop >/dev/null 2>&1 && { echo laptop; return; }
    echo desktop; return
  fi
  # No Omarchy helper (a test fixture, or a non-Omarchy box): fall back to the
  # kernel's own answer — a lid is the thing that makes a laptop a laptop.
  if [[ -d /proc/acpi/button/lid ]]; then echo laptop; else echo desktop; fi
}

read_profile_map() {
  [[ -f "$PROFILE_FILE" ]] || return 0
  sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$PROFILE_FILE" 2>/dev/null || true
}

profile_for_machine() {
  local want="$1" line k v
  while IFS= read -r line; do
    k="${line%%=*}"; v="${line#*=}"
    k="${k//[[:space:]]/}"; v="${v//[[:space:]]/}"
    [[ "$k" == "$want" ]] && { printf '%s\n' "$v"; return 0; }
  done < <(read_profile_map)
  return 1
}

# Resolved once per process: every scope lookup needs it.
current_profile() {
  if [[ -n "${REPLICANT_PROFILE:-}" ]]; then printf '%s\n' "$REPLICANT_PROFILE"; return; fi
  profile_for_machine "$MACHINE" && return
  guess_profile
}

# core_profile_set <name> — assign this machine to a profile, creating it.
core_profile_set() {
  local want="$1" line k v
  local -a keep=()
  [[ "$want" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || {
    echo "profile: use lowercase letters, digits, '-' or '_' (max 32)" >&2; return 1; }
  ensure_repo_layout
  while IFS= read -r line; do
    k="${line%%=*}"; k="${k//[[:space:]]/}"
    [[ "$k" == "$MACHINE" ]] || keep+=("$line")
  done < <(read_profile_map)
  keep+=("$MACHINE = $want")
  {
    echo "# Which profile each machine belongs to: <hostname> = <profile>."
    echo "# A machine that is not listed guesses from its own chassis."
    echo "# Files scoped to a profile live in profiles/<profile>/config/, so two"
    echo "# machines in different profiles never overwrite each other's copy."
    printf '%s\n' "${keep[@]}"
  } > "$PROFILE_FILE"
  echo "$MACHINE is now in the '$want' profile" >&2
}

# Every profile the repo knows about: the assignments, the directories that
# already exist, and this machine's own — so the panel can list them.
list_profiles() {
  {
    read_profile_map | sed -e 's/.*=//' -e 's/[[:space:]]//g'
    [[ -d "$REPO_DIR/profiles" ]] && find "$REPO_DIR/profiles" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null
    current_profile
  } | sed '/^$/d' | sort -u
}

read_scopes() {
  [[ -f "$SCOPE_FILE" ]] || return 0
  sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$SCOPE_FILE" 2>/dev/null || true
}

# scope_for <rel> → shared | profile | off   (unlisted files are shared)
scope_for() {
  local rel="$1" line k v
  while IFS= read -r line; do
    k="${line%%=*}"; v="${line#*=}"
    k="${k//[[:space:]]/}"; v="${v//[[:space:]]/}"
    if [[ "$k" == "$rel" ]]; then
      case "$v" in shared|profile|off) printf '%s\n' "$v"; return 0 ;; esac
    fi
  done < <(read_scopes)
  # A v0.5 repo that has not been through ensure_repo_layout yet still keeps its
  # off-list in the old flat file. Honour it until the migration runs, so a file
  # the user switched off never reads as shared for even one command.
  if [[ ! -f "$SCOPE_FILE" && -f "$LEGACY_EXCLUDE_FILE" ]]; then
    while IFS= read -r line; do
      [[ "${line//[[:space:]]/}" == "$rel" ]] && { printf 'off\n'; return 0; }
    done < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$LEGACY_EXCLUDE_FILE" 2>/dev/null || true)
  fi
  printf 'shared\n'
}

# Kept so the eight call sites that only care about "is this switched off"
# read the way they always did.
is_excluded() { [[ "$(scope_for "$1")" == "off" ]]; }

# repo_path_for <rel> [profile] — where this file's copy lives in the repo.
# The one place that knows shared files sit in config/ and profile-scoped ones
# sit under profiles/<profile>/. Every reader and writer goes through it, so a
# file cannot be saved to one path and restored from another.
repo_path_for() {
  local rel="$1" prof="${2:-}"
  if [[ "$(scope_for "$rel")" == "profile" ]]; then
    [[ -n "$prof" ]] || prof=$(current_profile)
    printf '%s\n' "$REPO_DIR/profiles/$prof/config/$rel"
  else
    printf '%s\n' "$CONFIG_DIR/$rel"
  fi
}

write_scope_file() {
  local -a keep=("$@")
  {
    echo "# What Replicant does with each tracked file, one per line:"
    echo "#   <path> = shared    one copy, every machine saves and restores it"
    echo "#   <path> = profile   a copy per profile, under profiles/<profile>/config/"
    echo "#   <path> = off       never saved from or restored onto any machine"
    echo "# A path that is not listed is shared. Written by the panel; safe to edit."
    (( ${#keep[@]} )) && printf '%s\n' "${keep[@]}"
  } > "$SCOPE_FILE"
}

# Seed the scope list on a fresh repo, and migrate the v0.5 flat off-list.
# .replicant-exclude only had two states; every path in it meant "off", which is
# still exactly what it means here — so the migration is a straight translation
# and nothing a user chose is reinterpreted.
#
# EVERY writer must call this before rewriting the file. core_scope once did not,
# and because read_scopes() sees no .replicant-sync it rebuilt the list from
# nothing — silently discarding a v0.5 user's entire off-list the first time they
# touched any file's scope. Reading has a fallback; writing needs the real thing.
ensure_scope_file() {
  [[ -f "$SCOPE_FILE" ]] && return 0
  mkdir -p "$(dirname "$SCOPE_FILE")" 2>/dev/null || true
  local -a seed=()
  if [[ -f "$LEGACY_EXCLUDE_FILE" ]]; then
    local ln
    while IFS= read -r ln; do
      ln="${ln//[[:space:]]/}"
      [[ -n "$ln" ]] && seed+=("$ln = off")
    done < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$LEGACY_EXCLUDE_FILE" 2>/dev/null || true)
    write_scope_file "${seed[@]}"
    rm -f -- "$LEGACY_EXCLUDE_FILE"
    echo "  · migrated .replicant-exclude to .replicant-sync (${#seed[@]} entries kept off)" >&2
  else
    write_scope_file "${DEFAULT_SCOPES[@]/=/ = }"
  fi
}

# core_scope <rel> <shared|profile|off> — the panel's per-file scope control.
core_scope() {
  local rel="$1" want="$2" line k old
  local -a keep=()
  case "$want" in shared|profile|off) ;; *)
    echo "scope: expected 'shared', 'profile' or 'off'" >&2; return 1 ;; esac
  resolve_manifest_src "$rel" >/dev/null 2>&1 || { echo "unknown id: $rel" >&2; return 1; }
  ensure_scope_file
  old=$(scope_for "$rel")
  [[ "$old" == "$want" ]] && { echo "$rel is already '$want'" >&2; return 0; }
  mkdir -p "$(dirname "$SCOPE_FILE")"
  while IFS= read -r line; do
    k="${line%%=*}"; k="${k//[[:space:]]/}"
    [[ "$k" == "$rel" ]] || keep+=("$line")
  done < <(read_scopes)
  [[ "$want" != "shared" ]] && keep+=("$rel = $want")
  write_scope_file "${keep[@]}"

  # Moving between scopes moves the copy the repo already holds, so changing
  # your mind does not silently strand a backup at the old path.
  local from to
  case "$old:$want" in
    shared:profile)
      from="$CONFIG_DIR/$rel"; to="$REPO_DIR/profiles/$(current_profile)/config/$rel"
      if [[ -f "$from" ]]; then mkdir -p "$(dirname "$to")"; mv -f -- "$from" "$to"; fi ;;
    profile:shared)
      from="$REPO_DIR/profiles/$(current_profile)/config/$rel"; to="$CONFIG_DIR/$rel"
      if [[ -f "$from" ]]; then mkdir -p "$(dirname "$to")"; mv -f -- "$from" "$to"; fi ;;
  esac

  case "$want" in
    shared)  echo "$rel is shared by every machine" >&2 ;;
    profile) echo "$rel is kept per profile — this machine reads and writes the '$(current_profile)' copy" >&2 ;;
    off)     echo "$rel will no longer sync" >&2 ;;
  esac
}

# core_sync <rel> <on|off> — the older two-state switch, kept because it is in
# the shipped README and in scripts. "on" means shared.
core_sync() {
  local rel="$1" want="$2"
  case "$want" in
    on)  core_scope "$rel" shared ;;
    off) core_scope "$rel" off ;;
    *)   echo "sync: expected 'on' or 'off'" >&2; return 1 ;;
  esac
}

# ─── The user's list: writing it ────────────────────────────────────────────
write_track_file() {
  local -a keep=("$@")
  {
    echo "# Files and directories YOU want backed up, on top of the ones the"
    echo "# plugin ships with. One per line:"
    echo "#"
    echo "#   ~/.local/bin/my-script                  name in the repo derived"
    echo "#   ~/.config/foo/bar.conf = foo/bar.conf   name in the repo given"
    echo "#   ~/.config/nvim/                         a directory (trailing slash)"
    echo "#   secret ~/dev/app/.env                   stored 600, never rendered"
    echo "#"
    echo "# This file lives in the repo, so both your machines honour it."
    echo "# Written by the panel and by 'omarchy-replicant track'; safe to edit."
    (( ${#keep[@]} )) && printf '%s\n' "${keep[@]}"
  } > "$USER_TRACK_FILE"
}

# Same contract as ensure_scope_file, for the same reason: load_user_manifest
# has a read-only fallback so nothing stops being tracked the moment you
# upgrade, but a read-modify-write against a list the fallback invented would
# be a delete. Every writer calls this first.
ensure_track_file() {
  [[ -f "$USER_TRACK_FILE" ]] && return 0
  mkdir -p "$(dirname "$USER_TRACK_FILE")" 2>/dev/null || true
  local -a seed=() entry
  for entry in "${LEGACY_PERSONAL[@]}"; do
    legacy_personal_present "$entry" && seed+=("$(track_line_for "${entry%%:*}" "${entry##*:}" config)")
  done
  for entry in "${LEGACY_PERSONAL_SECRETS[@]}"; do
    [[ -f "${entry%%:*}" || -f "$SECRETS_DIR/${entry##*:}" ]] &&
      seed+=("$(track_line_for "${entry%%:*}" "${entry##*:}" secret)")
  done
  write_track_file ${seed[@]+"${seed[@]}"}
  (( ${#seed[@]} )) &&
    echo "  · ${#seed[@]} entry(ies) that used to be hardcoded are now yours, in .replicant-track" >&2
  load_user_manifest
  return 0
}

# One line of .replicant-track, written the way a human would: the derived name
# is left implicit, so the file only ever states what it has to.
track_line_for() {
  local src="$1" rel="$2" kind="${3:-config}" pretty="${1/#$HOME/\~}" line
  line="$pretty"
  [[ "$(derive_rel "$src")" == "$rel" ]] || line="$pretty = $rel"
  [[ "$kind" == secret ]] && line="secret $line"
  printf '%s\n' "$line"
}

is_user_entry() {
  local rel="$1" entry
  for entry in ${USER_MANIFEST[@]+"${USER_MANIFEST[@]}"} ${USER_SECRETS[@]+"${USER_SECRETS[@]}"}; do
    [[ "${entry##*:}" == "$rel" ]] && return 0
  done
  return 1
}

# core_track <path> [rel] [--secret] — add one path to the user's list.
core_track() {
  local path="" rel="" kind=config arg
  for arg in "$@"; do
    case "$arg" in
      --secret) kind=secret ;;
      -*) ;;
      *) if [[ -z "$path" ]]; then path="$arg"; else rel="$arg"; fi ;;
    esac
  done
  [[ -n "$path" ]] || { echo "track: usage: track <path> [name-in-repo] [--secret]" >&2; return 1; }
  case "$path" in "~/"*) path="$HOME/${path#\~/}" ;; esac
  [[ "$path" == /* ]] || path="$PWD/$path"
  # A trailing slash is how the user says "directory", but so is the file
  # system: asking it means `track ~/.config/nvim` does the obvious thing.
  [[ -d "${path%/}" ]] && path="${path%/}/"
  [[ -e "${path%/}" ]] || { echo "track: $path does not exist on this machine" >&2; return 1; }
  [[ -L "${path%/}" ]] && { echo "track: $path is a symlink — track what it points at instead" >&2; return 1; }
  [[ -n "$rel" ]] || rel=$(derive_rel "$path")
  if [[ "$path" == */ ]]; then rel="${rel%/}/"; fi

  local entry
  for entry in "${TRACKED[@]}" "${TRACKED_SECRETS[@]}"; do
    if [[ "${entry%%:*}" == "$path" || "${entry##*:}" == "$rel" ]]; then
      echo "track: already tracked as '${entry##*:}'" >&2; return 0
    fi
  done

  ensure_track_file
  local -a keep=()
  while IFS= read -r entry; do keep+=("$entry"); done < <(read_track_lines)
  keep+=("$(track_line_for "$path" "$rel" "$kind")")
  write_track_file ${keep[@]+"${keep[@]}"}
  load_user_manifest
  echo "tracking ${path/#$HOME/\~} as $rel" >&2
}

# core_untrack <rel> — drop one entry from the user's list. Only the user's:
# a shipped core entry is switched off with `scope <rel> off`, which keeps the
# row (and the copy the repo holds) instead of making both disappear.
core_untrack() {
  local rel="$1" entry k line
  [[ -n "$rel" ]] || { echo "untrack: usage: untrack <id>" >&2; return 1; }
  if ! is_user_entry "$rel"; then
    for entry in "${MANIFEST[@]}" "${SECRETS_MANIFEST[@]}"; do
      [[ "${entry##*:}" == "$rel" ]] && {
        echo "untrack: $rel is one of the files the plugin ships with — use 'scope $rel off' to stop syncing it" >&2
        return 1; }
    done
    echo "untrack: $rel is not in your list" >&2; return 1
  fi
  ensure_track_file
  local -a keep=()
  while IFS= read -r line; do
    IFS=$'\t' read -r k _ entry < <(parse_track_line "$line")
    [[ "${entry:-}" == "$rel" ]] || keep+=("$line")
  done < <(read_track_lines)
  write_track_file ${keep[@]+"${keep[@]}"}
  load_user_manifest
  # The repo copy goes with it — core_backup's prune pass would remove it on
  # the next save anyway, and leaving it until then means the panel shows a row
  # for a file nothing tracks.
  local copy; copy=$(repo_copy_for_rel "$rel")
  [[ -e "$copy" ]] && rm -rf -- "$copy"
  echo "$rel is no longer tracked (the copy in your repo was removed too)" >&2
}

# ─── suggest — the part that makes adding easy ──────────────────────────────
# The manifest is deliberately not auto-discovery: the guarantee that only what
# a human decided to track gets tracked is the point of the whole thing. But
# "you may add anything you like" is worthless if finding it means remembering
# every path you ever edited. So this proposes, and the user disposes: it walks
# the few places hand-written config actually lives and prints what is not
# tracked yet, with the reason it is worth a second look.
#
# Everything it refuses to suggest, it refuses for a mechanical reason, never
# a guess about taste:
SUGGEST_MAX_BYTES=262144   # a config file people wrote by hand; not a database

# What a config file looks like. A positive list rather than a blocklist,
# because the things under ~/.config that are NOT config outnumber the things
# that are, and they are invented faster than anyone can exclude them.
SUGGEST_EXTENSIONS="conf toml ini yml yaml lua json jsonc rc list css scss sh bash fish zsh service timer socket desktop kdl nix editorconfig theme vim"

# An Electron or Chromium application keeps its entire state in ~/.config/<app>,
# and every file in there is machine-generated: "Local State", "Preferences",
# "TransportSecurity", a machine id. Suggesting them would bury the handful of
# files a person actually wrote, and restoring one onto another machine would
# be actively wrong. The tell is reliable and cheap — these names are the
# Chromium profile layout, and nothing hand-written is called any of them.
APP_STATE_MARKERS=("Local State" "Preferences" "TransportSecurity" "machineid" "Cookies" "History" "Network Persistent State" "Session Storage" "blob_storage" "Service Worker")

is_app_state_dir() {
  local d="$1" m
  for m in "${APP_STATE_MARKERS[@]}"; do [[ -e "$d/$m" ]] && return 0; done
  return 1
}

suggest_skip_reason() {
  local f="$1" base="${f##*/}" ext="${f##*.}"
  [[ -L "$f" ]]                             && { echo "a symlink"; return 0; }
  [[ "$base" == *.bak.* || "$base" == *~ ]] && { echo "a backup"; return 0; }
  [[ $(stat -c%s "$f" 2>/dev/null || echo 0) -gt $SUGGEST_MAX_BYTES ]] && { echo "too big to be hand-written"; return 0; }
  grep -Iq . "$f" 2>/dev/null || { echo "not a text file"; return 0; }
  is_app_state_dir "$(dirname "$f")" && { echo "an application's own state"; return 0; }
  # Already picked up on its own: a plugin config next to its manifest is found
  # by discover_plugin_entries and saved without anybody listing it.
  is_discovered_plugin_config "$f" && { echo "already saved as a plugin config"; return 0; }
  case "$base" in
    package.json|package-lock.json|yarn.lock|pnpm-lock.yaml|composer.lock)
      { echo "a package manager's file"; return 0; } ;;
    *session*|*state*|*.log|*.pid|*.sock*|*.db|*.lock)
      { echo "runtime state, not config"; return 0; } ;;
  esac
  # A script has no extension to go by, so it is judged by being executable and
  # living where you put scripts. Everything else must look like config.
  if [[ "$f" != "$HOME/.local/bin/"* ]]; then
    [[ "$ext" != "$base" ]] || { echo "no extension — not obviously config"; return 0; }
    [[ " $SUGGEST_EXTENSIONS " == *" ${ext,,} "* ]] || { echo ".$ext is not a config format"; return 0; }
  fi
  # A mise shim is generated, identical on every machine, and recreated by
  # `mise use -g` — nine of them in ~/.local/bin would drown the real scripts.
  grep -qE '^exec mise x ' "$f" 2>/dev/null && { echo "a mise shim"; return 0; }
  # Installed by another plugin, which is what reinstalls it. The tell is the
  # uninstaller every Omarchy plugin installer drops beside its script.
  [[ -e "${f}-uninstall" ]] && { echo "installed by a plugin"; return 0; }
  [[ "$base" == *-uninstall ]] && [[ -e "${f%-uninstall}" ]] && { echo "installed by a plugin"; return 0; }
  # Byte-identical to what Omarchy ships: nothing of yours is in it, and
  # `omarchy refresh config` already puts it back.
  is_default_file "$f" 2>/dev/null && { echo "identical to Omarchy's default"; return 0; }
  return 1
}

# owning_rel <repo-relative-path> — the tracked id a repo path belongs to. For
# a plain file that is the path itself; for a file inside a tracked directory
# it is the directory's id, which is where its scope is recorded. The prune
# pass needs it: "is this switched off" is a question about the entry, and a
# file three levels inside a tracked tree has no entry of its own.
owning_rel() {
  local p="$1" entry erel
  for entry in "${TRACKED[@]}"; do
    erel="${entry##*:}"
    [[ "$erel" == */ && "$p" == "$erel"* ]] && { printf '%s\n' "$erel"; return 0; }
  done
  printf '%s\n' "$p"
}

is_discovered_plugin_config() {
  local p="$1" psrc _prel _pname
  while IFS=$'\t' read -r psrc _prel _pname; do
    [[ "$psrc" == "$p" ]] && return 0
  done < <(discover_plugin_entries)
  return 1
}

# Some config files hold a credential. gh/hosts.yml carries an OAuth token, a
# .netrc carries a password. They are perfectly reasonable things to back up
# into a private repo — but as secrets, at mode 600, with their contents never
# rendered in the panel. Suggesting one as ordinary config is how a token ends
# up world-readable in a git checkout, so it is named here.
suggest_kind() {
  case "${1##*/}" in
    hosts.yml|hosts.yaml|.netrc|netrc|credentials|credentials.*|*token*|*secret*|*.pem|*.key)
      echo secret ;;
    *) echo config ;;
  esac
}

is_tracked_path() {
  local p="$1" entry esrc
  for entry in "${TRACKED[@]}" "${TRACKED_SECRETS[@]}"; do
    esrc="${entry%%:*}"
    [[ "$esrc" == "$p" ]] && return 0
    # A file inside a tracked directory is tracked by it.
    [[ "$esrc" == */ && "$p" == "$esrc"* ]] && return 0
  done
  return 1
}

# core_suggest [--json] — "path<TAB>rel<TAB>reason" per line, or the same as
# JSON for the panel's checklist.
core_suggest() {
  local as_json=0; [[ "${1:-}" == "--json" ]] && as_json=1
  {
    local f reason kind
    # Top level of ~/.config and one directory down: deep trees are libraries
    # and caches, and the config people actually edit is never four levels in.
    while IFS= read -r f; do
      is_tracked_path "$f" && continue
      case "$f" in
        */omarchy/themes/*|*/omarchy/backgrounds/*) continue ;;  # inventoried, not copied
        */.git/*|*/node_modules/*|*/cache/*|*/Cache/*) continue ;;
      esac
      suggest_skip_reason "$f" >/dev/null && continue
      reason="config you edited by hand"
      case "$f" in
        */systemd/user/*) reason="a user service you added" ;;
        "$HOME/.local/bin/"*) reason="a script you wrote" ;;
      esac
      kind=$(suggest_kind "$f")
      [[ "$kind" == secret ]] && reason="holds a credential — track it as a secret"
      printf '%s\t%s\t%s\t%s\n' "$f" "$(derive_rel "$f")" "$reason" "$kind"
    done < <({
      find "$HOME/.config" -maxdepth 2 -type f 2>/dev/null
      find "$HOME/.config/systemd/user" -maxdepth 1 -type f 2>/dev/null
      find "$HOME/.local/bin" -maxdepth 1 -type f -executable 2>/dev/null
    } | sort -u)
  } | if (( as_json )); then
    jq -Rsc 'def home: sub("^"+$ENV.HOME; "~");
      split("\n") | map(select(length > 0) | split("\t")
      | {path: .[0], pretty: (.[0]|home), id: .[1], reason: .[2], kind: .[3]})'
  else
    cat
  fi
}

# install helpers — install_file() writes with a .bak.<epoch> of whatever it overwrites
DRY=${DRY:-0}
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1" >&2; }
skip() { printf '  \033[33m·\033[0m %s\n' "$1" >&2; }
run()  { if (( DRY )); then printf '  \033[36m»\033[0m %s\n' "$*" >&2; else "$@"; fi; }
install_file() {
  local src=$1 dst=$2 mode=$3
  local short_path=${dst/#$HOME/\~}
  if [[ ! -f $src ]]; then
    skip "$short_path — source missing in the repo ($src)"
    return
  fi
  if [[ -f $dst ]] && cmp -s "$src" "$dst"; then
    run chmod "$mode" "$dst"
    ok "$short_path (already matches, mode $mode)"
    return
  fi
  if [[ -e $dst ]]; then
    run cp -a "$dst" "$dst.bak.$(date +%s)"
    skip "$short_path — previous version saved as .bak.<epoch>"
  fi
  run install -D -m "$mode" "$src" "$dst"
  ok "$short_path ($mode)"
}

# ─── Directory entries ──────────────────────────────────────────────────────
# A handful of things people configure are a small tree rather than one file —
# ~/.config/nvim is the obvious one. What is deliberately NOT here is anything
# that is really a git clone: the eight custom themes on the machine this was
# written on come to 556 MB, 400 of it inside their own .git directories, and
# copying that into a git repo would be both enormous and worse than the thing
# it replaced. Those get an inventory and `omarchy theme install` instead.
#
# .git is skipped inside a tracked tree for the same reason, one size down: a
# repo nested in a repo is not backed up by copying its objects around.
TREE_EXCLUDES=(".git" "node_modules" "__pycache__" ".cache")

tree_find() {
  local root="${1%/}" e
  local -a prune=()
  for e in "${TREE_EXCLUDES[@]}"; do prune+=(-name "$e" -o); done
  find "$root" \( "${prune[@]}" -false \) -prune -o -type f -print 2>/dev/null
}

# tree_files <root> — paths inside the tree, relative to it, sorted.
tree_files() {
  local root="${1%/}"
  tree_find "$root" | sed "s|^$root/||" | sort
}

tree_count() { tree_find "${1%/}" | wc -l | tr -d ' '; }

# Do the two trees hold the same files with the same contents?
tree_same() {
  local a="${1%/}" b="${2%/}"
  [[ -d "$a" && -d "$b" ]] || return 1
  [[ "$(tree_files "$a")" == "$(tree_files "$b")" ]] || return 1
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    cmp -s "$a/$f" "$b/$f" || return 1
  done < <(tree_files "$a")
  return 0
}

# tree_diff_summary <from-dir> <to-dir> — what restoring would change, named
# but never quoted. A tree is too big to show as a unified diff in a terminal
# or a panel, and the question at restore time is which files move, not which
# bytes.
tree_diff_summary() {
  local a="${1%/}" b="${2%/}" f n_add=0 n_chg=0 n_del=0
  local -a add=() chg=() del=()
  if [[ ! -d "$b" ]]; then
    echo "(doesn't exist: would be created with $(tree_count "$a") files)"
    return 0
  fi
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if [[ ! -e "$b/$f" ]]; then add+=("$f"); n_add=$((n_add+1))
    elif ! cmp -s "$a/$f" "$b/$f"; then chg+=("$f"); n_chg=$((n_chg+1)); fi
  done < <(tree_files "$a")
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    [[ -e "$a/$f" ]] || { del+=("$f"); n_del=$((n_del+1)); }
  done < <(tree_files "$b")
  printf '%d added, %d changed, %d only on this machine\n' "$n_add" "$n_chg" "$n_del"
  for f in ${add[@]+"${add[@]}"}; do echo "  + $f"; done | head -n 20
  for f in ${chg[@]+"${chg[@]}"}; do echo "  ~ $f"; done | head -n 20
  # Restoring never deletes: install_tree writes what the repo has and leaves
  # the rest, so these are listed as information, not as a pending removal.
  for f in ${del[@]+"${del[@]}"}; do echo "  · $f (left alone)"; done | head -n 10
}

# copy_tree_into_repo <src-dir> <dst-dir> — mirror one tree into the repo, in
# both directions: a file deleted on the machine goes from the repo too, or a
# tracked directory would only ever grow. The destination is required to be
# inside the repo, because this is the one place the plugin removes a tree.
copy_tree_into_repo() {
  local src="${1%/}" dst="${2%/}" f
  case "$dst/" in "$REPO_DIR"/*) ;; *) echo "refusing to mirror outside the repo: $dst" >&2; return 1 ;; esac
  mkdir -p "$dst"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    mkdir -p "$dst/$(dirname "$f")"
    cp -f "$src/$f" "$dst/$f"
  done < <(tree_files "$src")
  # Prune what the source no longer has.
  local keep; keep=$(tree_files "$src")
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    grep -qxF "$f" <<<"$keep" || rm -f -- "$dst/$f"
  done < <(tree_files "$dst")
  find "$dst" -mindepth 1 -type d -empty -delete 2>/dev/null || true
}

# install_tree <repo-dir> <dst-dir> <mode> — the restore side, with the same
# .bak.<epoch> of the whole directory that install_file makes of one file.
install_tree() {
  local src="${1%/}" dst="${2%/}" mode="$3" f
  local short_path=${dst/#$HOME/\~}
  if [[ ! -d $src ]]; then skip "$short_path/ — not in the repo"; return; fi
  if [[ -d $dst ]] && tree_same "$src" "$dst"; then
    ok "$short_path/ (already matches, $(tree_count "$src") files)"
    return
  fi
  if [[ -e $dst ]]; then
    run cp -a "$dst" "$dst.bak.$(date +%s)"
    skip "$short_path/ — previous version saved as .bak.<epoch>"
  fi
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    run install -D -m "$mode" "$src/$f" "$dst/$f"
  done < <(tree_files "$src")
  ok "$short_path/ ($(tree_count "$src") files, $mode)"
}

ensure_repo_layout() {
  mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$TEMPLATES_DIR"
  # A repo written before state/ was scoped by machine has its inventory flat in
  # state/. Move it under this machine's name rather than leaving two shapes to
  # support forever; git records the move like any other change.
  # `mv -n` is not enough: it exits 0 and does NOTHING when the target already
  # exists, so a half-migrated repo kept a stale flat copy of every inventory
  # file next to the scoped one, forever. The scoped copy is regenerated from
  # this machine on every backup, so where both exist it is the newer of the
  # two and the flat one is what goes.
  local flat name
  for flat in "$STATE_ROOT"/*.txt; do
    [[ -f "$flat" ]] || continue
    name=$(basename "$flat")
    if [[ -f "$STATE_DIR/$name" ]]; then
      rm -f -- "$flat"
    else
      mv -- "$flat" "$STATE_DIR/$name" 2>/dev/null || true
    fi
  done
  ensure_scope_file
  ensure_track_file
  mkdir -p "$REPO_DIR/profiles/$(current_profile)/config" 2>/dev/null || true
  install -d -m 700 "$SECRETS_DIR" 2>/dev/null || mkdir -p "$SECRETS_DIR"
  # templates placeholder
  if [[ ! -f "$TEMPLATES_DIR/60-secrets.conf.example" && -f "$HOME/omarchy_thinkpad/templates/60-secrets.conf.example" ]]; then
    cp -a "$HOME/omarchy_thinkpad/templates/"*.example "$TEMPLATES_DIR/" 2>/dev/null || true
  fi
  # githooks
  mkdir -p "$GITHOOKS_DIR"
  if [[ ! -f "$GITHOOKS_DIR/pre-commit" ]]; then
    cat >"$GITHOOKS_DIR/pre-commit" <<'HOOK'
#!/bin/bash
set -uo pipefail
REPO=$(git rev-parse --show-toplevel)
SCAN="$REPO/bin/scan-secrets.sh"
[[ -x "$SCAN" ]] || SCAN="$HOME/.config/omarchy/plugins/io.github.tymurbogach.omarchy-replicant/bin/scan-secrets.sh"
[[ -x "$SCAN" ]] || exit 0
fail=0
files=$(git diff --cached --name-only --diff-filter=ACM)
[[ -z $files ]] && exit 0
while IFS= read -r file; do
  [[ -f $file ]] || continue
  [[ $file == secrets/* ]] && continue
  git show ":$file" 2>/dev/null | "$SCAN" --stdin "$file" || fail=1
done <<<"$files"
if (( fail )); then
  cat <<'MSG'
COMMIT BLOCKED: possible credential in config/state/templates.
MSG
  exit 1
fi
HOOK
    chmod +x "$GITHOOKS_DIR/pre-commit"
  fi
  # scan-secrets bin
  if [[ ! -f "$REPO_DIR/bin/scan-secrets.sh" ]]; then
    mkdir -p "$REPO_DIR/bin"
    if [[ -f "$PLUGIN_DIR/bin/scan-secrets.sh" ]]; then
      cp -a "$PLUGIN_DIR/bin/scan-secrets.sh" "$REPO_DIR/bin/scan-secrets.sh"
    elif [[ -f "$HOME/omarchy_thinkpad/bin/scan-secrets.sh" ]]; then
      cp -a "$HOME/omarchy_thinkpad/bin/scan-secrets.sh" "$REPO_DIR/bin/scan-secrets.sh"
    fi
    chmod +x "$REPO_DIR/bin/scan-secrets.sh" 2>/dev/null || true
  fi
  # pacman-delta-ignore
  if [[ ! -f "$REPO_DIR/bin/pacman-delta-ignore" && -f "$HOME/omarchy_thinkpad/bin/pacman-delta-ignore" ]]; then
    mkdir -p "$REPO_DIR/bin"
    cp -a "$HOME/omarchy_thinkpad/bin/pacman-delta-ignore" "$REPO_DIR/bin/pacman-delta-ignore"
  fi
  # .gitignore — savegame style (state/ is generated, .bak.* ignored, secrets/ tracked)
  if [[ ! -f "$REPO_DIR/.gitignore" ]]; then
    cat >"$REPO_DIR/.gitignore" <<'GI'
# — replicant savegame —
*.bak.*
*.bak
**/.cache/
**/Cache/
.ssh/id_*
.ssh/*.pem
GI
  fi
  # git init if needed
  if [[ ! -d "$REPO_DIR/.git" ]]; then
    git -C "$REPO_DIR" init -q -b main
    git -C "$REPO_DIR" config init.defaultBranch main 2>/dev/null || true
    git -C "$REPO_DIR" config user.name  "${GIT_AUTHOR_NAME:-$(git config --global user.name 2>/dev/null || echo "$USER")}"
    git -C "$REPO_DIR" config user.email "${GIT_AUTHOR_EMAIL:-$(git config --global user.email 2>/dev/null || echo "$USER@omarchy-replicant")}"
    git -C "$REPO_DIR" config core.hooksPath .githooks 2>/dev/null || true
  else
    git -C "$REPO_DIR" config core.hooksPath .githooks 2>/dev/null || true
  fi
}

core_backup() {
  ensure_repo_layout
  echo "→ Copying configuration (fixed MANIFEST, savegame)" >&2
  copied=0; missing=0
  local skipped=0
  for entry in "${TRACKED[@]}"; do
    src=${entry%%:*}
    rel="${entry##*:}"
    dst=$(repo_path_for "$rel")
    # Switched off in .replicant-sync: not copied from here, and (see the
    # prune pass below) whatever the repo already holds is left alone.
    if is_excluded "$rel"; then
      skipped=$((skipped + 1))
      continue
    fi
    if is_dir_entry "$rel"; then
      if [[ -d "${src%/}" ]]; then
        copy_tree_into_repo "$src" "$dst"
        ((copied++)) || true
      else
        echo "  · missing: ${src/#$HOME/\~}" >&2
        ((missing++)) || true
      fi
    elif [[ -f $src ]]; then
      mkdir -p "$(dirname "$dst")"
      cp -f "$src" "$dst"
      ((copied++)) || true
    else
      echo "  · missing: ${src/#$HOME/\~}" >&2
      ((missing++)) || true
    fi
  done
  if (( skipped > 0 )); then
    echo "  $copied copied, $missing missing, $skipped not synced (switched off)" >&2
  else
    echo "  $copied copied, $missing missing" >&2
  fi

  echo "→ Copying auto-detected plugin configs" >&2
  local pcopied=0 psrc prel _pname
  while IFS=$'\t' read -r psrc prel _pname; do
    [[ -n "$psrc" ]] || continue
    dst="$CONFIG_DIR/$prel"
    mkdir -p "$(dirname "$dst")"
    cp -f "$psrc" "$dst"
    pcopied=$((pcopied+1))
  done < <(discover_plugin_entries)
  echo "  $pcopied plugin config(s) detected" >&2

  # Prune what is no longer tracked. Without this, dropping a line from MANIFEST
  # (or uninstalling a plugin) leaves its last copy in config/ forever — the
  # repo slowly fills with files that describe a machine that no longer exists,
  # and the panel has no row to act on them with. Nothing is actually lost:
  # every removal lands in a commit, and git keeps the content.
  # A file is expected at exactly one path: the one repo_path_for() gives it.
  # So the prune pass asks the same function the copy pass did, and a file that
  # moved between scopes is cleaned up at its old path by core_scope(), not here.
  local -a expected=()
  local _e
  for entry in "${TRACKED[@]}"; do
    _e="${entry##*:}"
    is_excluded "$_e" && continue
    expected+=("$(repo_path_for "$_e")")
  done
  while IFS=$'\t' read -r _psrc prel _pname; do
    [[ -n "$prel" ]] && expected+=("$CONFIG_DIR/$prel")
  done < <(discover_plugin_entries)
  local pruned=0 found e
  # Only this profile's tree is swept. Another machine's profile directory is
  # not ours to tidy: from here every file in it looks untracked, and pruning
  # it would delete the other machine's only backup on our next save.
  local -a sweep=("$CONFIG_DIR")
  [[ -d "$REPO_DIR/profiles/$(current_profile)/config" ]] && sweep+=("$REPO_DIR/profiles/$(current_profile)/config")
  while IFS= read -r -d '' f; do
    found=0
    for e in "${expected[@]}"; do
      # A directory entry claims everything under it. Its own mirroring already
      # pruned what the machine no longer has, so this pass must not second-
      # guess it — without the prefix case it would delete the whole tree on
      # the next save, one file at a time.
      if [[ "$e" == */ ]]; then [[ "$f" == "$e"* ]] && { found=1; break; }
      else [[ "$e" == "$f" ]] && { found=1; break; }; fi
    done
    (( found )) && continue
    # A file that is switched off keeps its last saved copy, by design —
    # wherever that copy happens to sit. Strip whichever sweep root it is under
    # so an off file stranded in the profile tree is recognised too.
    local candrel="$f"
    candrel="${candrel#"$REPO_DIR/profiles/$(current_profile)/config/"}"
    candrel="${candrel#"$CONFIG_DIR/"}"
    is_excluded "$(owning_rel "$candrel")" && continue
    rm -f -- "$f"
    echo "  · no longer tracked, removed from the repo: ${f#"$REPO_DIR"/}" >&2
    pruned=$((pruned+1))
  done < <(find "${sweep[@]}" -type f -print0 2>/dev/null)
  # leave no empty directories behind either
  find "${sweep[@]}" -mindepth 1 -type d -empty -delete 2>/dev/null || true
  (( pruned > 0 )) && echo "  $pruned stale file(s) pruned" >&2

  echo "→ Copying secrets (private repo, 600)" >&2
  install -d -m 700 "$SECRETS_DIR" 2>/dev/null || true
  scopied=0
  for entry in "${TRACKED_SECRETS[@]}"; do
    src=${entry%%:*}
    rel="${entry##*:}"
    dst="$SECRETS_DIR/$rel"
    is_excluded "$rel" && continue
    if [[ -f $src ]]; then
      install -d -m 700 "$(dirname "$dst")" 2>/dev/null || mkdir -p "$(dirname "$dst")"
      install -m 600 "$src" "$dst"
      ((scopied++)) || true
    else
      echo "  · missing: ${src/#$HOME/\~}" >&2
    fi
  done
  # CIFS credentials (root:600, best-effort)
  install -d -m 700 "$SECRETS_DIR/samba" 2>/dev/null || true
  for src in /etc/samba/credentials-pi /etc/samba/credentials-nas; do
    dst="$SECRETS_DIR/samba/$(basename "$src")"
    if [[ -r $src ]]; then install -m 600 "$src" "$dst" 2>/dev/null || true
    elif [[ -e $src && ! -f $dst ]]; then
      echo "  · $src needs sudo: sudo install -m600 -o $USER -g $USER $src $dst" >&2
    fi
  done
  echo "  $scopied secret(s) copied" >&2

  echo "→ Regenerating state/ inventory" >&2
  mkdir -p "$STATE_DIR"
  {
    echo "# Generated by replicant-core.sh — do not edit by hand"
    echo "date:         $(date -Is)"
    echo "hostname:     $(hostnamectl --static 2>/dev/null || hostname)"
    echo "kernel:       $(uname -r)"
    echo "omarchy:      $(cat /usr/share/omarchy/version 2>/dev/null || cat "$HOME/.local/share/omarchy/version" 2>/dev/null || echo '?')"
    echo "claude-code:  $(claude --version 2>/dev/null || echo 'not installed')"
  } > "$STATE_DIR/system.txt"
  pacman -Qqen > "$STATE_DIR/pacman-official.txt" 2>/dev/null || true
  pacman -Qqem > "$STATE_DIR/pacman-aur.txt" 2>/dev/null || true
  OMARCHY_PATH=${OMARCHY_PATH:-/usr/share/omarchy}
  base_omarchy="$OMARCHY_PATH/install/omarchy-base.packages"
  other_omarchy="$OMARCHY_PATH/install/omarchy-other.packages"
  if [[ -r $base_omarchy ]]; then
    known=$(mktemp)
    cat "$base_omarchy" "$other_omarchy" 2>/dev/null | sed 's/#.*//' | tr -s ' \t' '\n' | sed '/^$/d' >> "$known"
    if [[ -r "$REPO_DIR/bin/pacman-delta-ignore" ]]; then
      sed 's/#.*//' "$REPO_DIR/bin/pacman-delta-ignore" | tr -d ' \t' | sed '/^$/d' >> "$known"
    elif [[ -r "$PLUGIN_DIR/bin/pacman-delta-ignore" ]]; then
      sed 's/#.*//' "$PLUGIN_DIR/bin/pacman-delta-ignore" | tr -d ' \t' | sed '/^$/d' >> "$known"
    fi
    sort -u "$known" -o "$known"
    comm -23 <(sort -u "$STATE_DIR/pacman-official.txt") "$known" > "$STATE_DIR/pacman-delta.txt"
    comm -23 <(sort -u "$STATE_DIR/pacman-aur.txt")       "$known" > "$STATE_DIR/pacman-delta-aur.txt"
    rm -f "$known"
  else
    : > "$STATE_DIR/pacman-delta.txt"
    : > "$STATE_DIR/pacman-delta-aur.txt"
  fi
  # Which Omarchy plugins this machine has, and where they came from — the one
  # thing you need to make a second machine's shell match this one. Recorded
  # rather than copied: `omarchy plugin add <url>` rebuilds each of them, and
  # copying a plugin's source into a backup repo only ages badly.
  {
    echo "# id<TAB>version<TAB>origin<TAB>method"
    echo "# method 'add'   -> omarchy plugin add <origin>"
    echo "# method 'clone' -> omarchy plugin clone <origin>   (an edited copy of a built-in;"
    echo "#                  this restores the built-in, not the edits made to it)"
    local pmf pid pver porigin pdir
    for pmf in "$HOME/.config/omarchy/plugins"/*/manifest.json; do
      [[ -f "$pmf" ]] || continue
      pdir="$(dirname "$pmf")"
      pid=$(jq -r '.id // empty' "$pmf" 2>/dev/null) || continue
      [[ -n "$pid" ]] || continue
      pver=$(jq -r '.version // "?"' "$pmf" 2>/dev/null)
      local pmethod
      IFS=$'\t' read -r porigin pmethod < <(resolve_plugin_origin "$pdir" "$pid" "$pmf")
      printf '%s\t%s\t%s\t%s\n' "$pid" "$pver" "$porigin" "$pmethod"
    done
  } > "$STATE_DIR/omarchy-plugins.txt"

  # Themes, on exactly the same principle as plugins, and for a much louder
  # reason. theme.name has always been tracked and replayed with
  # `omarchy theme set` — but on a machine that does not HAVE the theme that
  # command fails, so the one thing the panel shows off restored to nothing.
  # The obvious fix, tracking ~/.config/omarchy/themes/ as a directory, is a
  # trap: the eight installed here are 556 MB, 400 of it their own .git. Every
  # user theme Omarchy knows about is a git clone, so what travels is the URL.
  {
    echo "# name<TAB>origin — user-installed themes, reinstalled with:"
    echo "#   omarchy theme install <origin>"
    echo "# Local edits to a theme are NOT here: this reinstalls the upstream copy."
    local tdir tname torigin
    for tdir in "$HOME/.config/omarchy/themes"/*/; do
      [[ -d "$tdir" ]] || continue
      tname=$(basename "${tdir%/}")
      torigin=$(git -C "${tdir%/}" remote get-url origin 2>/dev/null || true)
      [[ -n "$torigin" ]] || torigin="-"
      printf '%s\t%s\n' "$tname" "$torigin"
    done
  } > "$STATE_DIR/omarchy-themes.txt"

  mise ls 2>/dev/null > "$STATE_DIR/mise.txt" || true
  npm ls -g --depth=0 2>/dev/null > "$STATE_DIR/npm-global.txt" || true
  systemctl list-unit-files --state=enabled --no-pager --no-legend 2>/dev/null | awk '{print $1}' > "$STATE_DIR/system-services.txt" || true
  systemctl --user list-unit-files --state=enabled --no-pager --no-legend 2>/dev/null | awk '{print $1}' > "$STATE_DIR/user-services.txt" || true
  docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Ports}}' 2>/dev/null > "$STATE_DIR/containers.txt" || true
  grep -E '[[:space:]]cifs[[:space:]]' /etc/fstab > "$STATE_DIR/cifs-mounts.txt" 2>/dev/null || true
  if [[ -r $HOME/.config/environment.d/60-secrets.conf ]]; then
    { echo "# Names of the defined variables. VALUES are not tracked."; grep -oE '^[A-Z_]+' "$HOME/.config/environment.d/60-secrets.conf" | sort; } > "$STATE_DIR/defined-secrets.txt"
  fi
  NOISE='^(chromium|fcitx5|systemd|omarchy|elephant|environment\.d|btop)$'
  {
    echo "# Files under ~/.config that differ from Omarchy's default."
    echo "# Content differences only: 'Only in' lines are almost always runtime data."
    echo "# Excluded as noise: chromium, fcitx5, systemd, omarchy, elephant, environment.d, btop"
    echo
    for d in "$HOME/.local/share/omarchy/config"/* "$OMARCHY_PATH/config"/*; do
      [[ -e "$d" ]] || continue
      name=$(basename "$d")
      [[ $name =~ $NOISE ]] && continue
      [[ -e "$HOME/.config/$name" ]] || continue
      diff -rq "$d" "$HOME/.config/$name" 2>/dev/null | grep ' differ$' | sed 's|.*/\.config/|~/.config/|' || true
    done
  } > "$STATE_DIR/drift-vs-omarchy.txt"

  echo "→ Scanning what was copied (excludes secrets/)" >&2
  SCAN="$REPO_DIR/bin/scan-secrets.sh"
  [[ -x "$SCAN" ]] || SCAN="$PLUGIN_DIR/bin/scan-secrets.sh"
  if [[ -x "$SCAN" ]]; then
    if ! "$SCAN" "$CONFIG_DIR" "$STATE_DIR" 2>&1; then
      echo "  ✗ POSSIBLE SECRET — DO NOT commit" >&2
      return 1
    fi
    echo "  ✓ clean" >&2
  else
    echo "  · scan-secrets.sh not found, skipping" >&2
  fi
  echo "Done. Review with 'git -C $REPO_DIR diff' and commit with a why." >&2
}
# default_for_src <abs-src> — prints the path of Omarchy's shipped default for
# that file, or fails when the file has no default at all. Three callers need
# this same answer and used to each guess it differently: the sync badge
# ("default" vs "unsaved"), Diff (there is nothing to diff against without
# one), and reset-all (`omarchy refresh config` can only restore a file that
# ships a default — listing one that doesn't guaranteed a failure mid-run).
default_for_src() {
  local src="$1" base rel
  local omarchy_path="${OMARCHY_PATH:-/usr/share/omarchy}"
  if [[ "$src" == "$HOME/.config/"* ]]; then
    rel="${src#$HOME/.config/}"
    for base in "$omarchy_path/config" "$omarchy_path/default"; do
      [[ -f "$base/$rel" ]] && { printf '%s\n' "$base/$rel"; return 0; }
    done
  elif [[ "$src" == "$HOME/.bashrc" ]]; then
    for base in "$omarchy_path/default/bash" "$omarchy_path/config"; do
      [[ -f "$base/bashrc" ]] && { printf '%s\n' "$base/bashrc"; return 0; }
    done
  fi
  # /etc, ~/.local/state and everything else: no Omarchy default, always personal
  return 1
}

is_default_file() {
  # $1 = absolute source path. 0 when the file is byte-identical to the default
  # Omarchy ships, so there is nothing of the user's in it to lose.
  local def; def=$(default_for_src "$1") || return 1
  cmp -s "$1" "$def" 2>/dev/null
}

# config_rel_for_src <abs-src> — the path `omarchy refresh config` expects,
# i.e. relative to ~/.config. Derived from the real source path rather than
# from the repo layout: the two only coincide by accident (repo "home/bashrc"
# is ~/.bashrc, not ~/.config/home/bashrc) and passing the wrong one silently
# refreshes nothing.
config_rel_for_src() {
  local src="$1"
  [[ "$src" == "$HOME/.config/"* ]] || return 1
  printf '%s\n' "${src#$HOME/.config/}"
}

# path_unpushed <rel-path-inside-the-repo> — 0 (true) if that file's local HEAD
# differs from origin/<branch> (includes "never pushed at all": no upstream -> true)
path_unpushed() {
  local relpath="$1"
  if ! git -C "$REPO_DIR" rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
    return 0
  fi
  ! git -C "$REPO_DIR" diff --quiet @{u} -- "$relpath" 2>/dev/null
}

# discover_plugin_entries — auto-detects configs of OTHER installed Omarchy plugins
# (goal: any-monitor, sleepwalker, enter-the-matrix, future dev/omarchy-*, and
# third-party plugins too). Convention observed on this system: each plugin <id>
# keeps its user config at ~/.config/omarchy/<last-segment-of-id>.json (e.g.
# any-monitor.json, enter-the-matrix.json). No need to touch MANIFEST when a new
# plugin following that convention is installed.
# Emits one "src<TAB>rel<TAB>label" line per detected plugin with a config present.
discover_plugin_entries() {
  local plugins_dir="$HOME/.config/omarchy/plugins"
  [[ -d "$plugins_dir" ]] || return 0
  local mf pid pname short src
  for mf in "$plugins_dir"/*/manifest.json; do
    [[ -f "$mf" ]] || continue
    pid=$(jq -r '.id // empty' "$mf" 2>/dev/null) || continue
    [[ -n "$pid" ]] || continue
    [[ "$pid" == "io.github.tymurbogach.omarchy-replicant" ]] && continue
    pname=$(jq -r '.name // .id' "$mf" 2>/dev/null)
    short="${pid##*.}"
    src="$HOME/.config/omarchy/$short.json"
    [[ -f "$src" ]] || continue
    printf '%s\t%s\t%s\n' "$src" "plugins/$short.json" "$pname"
  done
}

# ─── SETTINGS — curated, individually-editable fields (not whole files) ─────
# Unlike MANIFEST (whole files, tracked for backup/sync), each entry here is one
# single field inside an already-tracked file, safe to read and write
# mechanically. The panel renders a control per type, so adding a setting is one
# line here and no QML change.
#
# Format: "id|group|file|path|type|label|unit|min|max|options|hint|apply|fallback|scale|display"
#
#   group    the section the panel files this control under
#   file     the file holding the value ("-" for types that don't read a file)
#   path     jq path (".idle.lock") for JSON | "section.key" for TOML |
#            the bare key ("repeat_rate") for lua-* | "-" for theme
#   type     number | bool | enum            JSON, via jq
#            toml-int | toml-float           "key = <n>" inside a [section]
#            lua-int | lua-bool | lua-enum   a "key = value" line in a Hyprland
#                                            Lua config (see lua_get for limits)
#            theme                           the active Omarchy theme
#            line-enum                       a file holding one bare word
#   min/max  numeric types only, in the STORED unit
#   options  enum types only, comma-separated
#   hint     one short line shown under the control
#   apply    command run after a successful write. Empty means the value is
#            picked up live: the Omarchy shell watches both shell.json and
#            ~/.config/omarchy/shell.toml (FileView watchChanges), so those
#            need nothing. Hyprland does not, hence `hyprctl reload`.
#   fallback the value in force when the key is absent from the file, i.e. the
#            shell's own built-in default. Only for keys the writer can create
#            (the toml-* types): shell.toml ships nearly empty, so most
#            appearance keys are missing until you change one, and reporting
#            them as "unavailable" would leave a control the user can see but
#            never touch. Reported with implicit:true so the panel can say the
#            value is inherited rather than written down anywhere. It doubles as
#            the value "reset to the Omarchy default" writes when the file
#            Omarchy ships has nothing to read.
#   scale    stored-unit -> shown-unit divisor. Omarchy stores idle timers in
#            seconds; nobody thinks in "600 seconds", so the panel edits them in
#            minutes (scale 60) and multiplies back before writing. Empty or 1
#            means the two units are the same. The CLI always speaks the STORED
#            unit — `set idle.lock 600` is still seconds — so scripts do not
#            have to know what the panel happens to display.
#   display  the unit shown next to the control once `scale` is applied
#            ("min"). Empty falls back to `unit`.
#
# A setting whose file or key is missing on this machine reads as null and the
# panel greys the control out. That is the intended behaviour, not an error:
# these files are the user's own and no two machines carry the same keys.
SETTINGS=(
  # ── Idle & power — ~/.config/omarchy/shell.json, watched live by the shell.
  # Stored in seconds by Omarchy, edited in minutes here.
  "idle.screensaver|Idle & power|$HOME/.config/omarchy/shell.json|.idle.screensaver|number|Screensaver|s|60|3600||Idle time before the screensaver starts|||60|min"
  "idle.lock|Idle & power|$HOME/.config/omarchy/shell.json|.idle.lock|number|Lock screen|s|60|7200||Idle time before the screen locks|||60|min"
  "idle.lazyDpms|Idle & power|$HOME/.config/omarchy/shell.json|.idle.lazyDpms|number|Turn off display|s|60|7200||Idle time before the display powers down|||60|min"
  "idle.lazySuspendAc|Idle & power|$HOME/.config/omarchy/shell.json|.idle.lazySuspendAc|number|Suspend on AC|s|0|14400||Idle time before suspending on AC power (0 = never)|||60|min"
  "idle.lazySuspendBatt|Idle & power|$HOME/.config/omarchy/shell.json|.idle.lazySuspendBatt|number|Suspend on battery|s|0|14400||Idle time before suspending on battery (0 = never)|||60|min"
  # ── Appearance
  "theme.current|Appearance|-|-|theme|Theme|||||The theme applied to the shell, terminals and editor||tokyo-night|1|"
  "bar.position|Appearance|$HOME/.config/omarchy/shell.json|.bar.position|enum|Bar position||||top,bottom,left,right|Which screen edge the status bar sits on|||1|"
  "bar.transparent|Appearance|$HOME/.config/omarchy/shell.json|.bar.transparent|bool|Transparent bar|||||Let the wallpaper show through the bar|||1|"
  "font.baseSize|Appearance|$HOME/.config/omarchy/shell.toml|font.base-size|toml-int|Interface font size|pt|8|32||Base size every bar, menu and panel font derives from||12|1|"
  "spacing.scale|Appearance|$HOME/.config/omarchy/shell.toml|spacing.scale|toml-float|Interface density|×|0.5|2||Multiplies every margin, gap and control size||1.0|1|"
  "bar.sizeHorizontal|Appearance|$HOME/.config/omarchy/shell.toml|bar.size-horizontal|toml-int|Bar thickness (top/bottom)|px|16|80||Height of the bar when it sits on a horizontal edge; setting it stops the bar scaling with the font||26|1|"
  "bar.sizeVertical|Appearance|$HOME/.config/omarchy/shell.toml|bar.size-vertical|toml-int|Bar thickness (left/right)|px|16|120||Width of the bar when it sits on a vertical edge; setting it stops the bar scaling with the font||28|1|"
  "bar.iconFont|Appearance|$HOME/.config/omarchy/shell.toml|bar.icon-font|toml-int|Bar icon size|px|8|28||How large the glyphs in the bar are drawn||13|1|"
  # ── Input — Hyprland reads Lua at startup, so these need an explicit reload
  "input.repeatRate|Input|$HOME/.config/hypr/input.lua|repeat_rate|lua-int|Key repeat rate|/s|1|100||Characters a held key sends per second|hyprctl reload||1|"
  "input.repeatDelay|Input|$HOME/.config/hypr/input.lua|repeat_delay|lua-int|Key repeat delay|ms|100|2000||How long a key is held before it starts repeating|hyprctl reload||1|"
  "input.kbLayout|Input|$HOME/.config/hypr/input.lua|kb_layout|lua-enum|Keyboard layout||||es,us,gb,de,fr,it,pt,latam|X11 layout code for the keyboard|hyprctl reload||1|"
  "input.numlock|Input|$HOME/.config/hypr/input.lua|numlock_by_default|lua-bool|Num lock at login|||||Turn the numeric keypad on when the session starts|hyprctl reload||1|"
  "input.naturalScroll|Input|$HOME/.config/hypr/input.lua|natural_scroll|lua-bool|Natural scrolling|||||Touchpad: two fingers down moves the page up|hyprctl reload||1|"
  "input.tapToClick|Input|$HOME/.config/hypr/input.lua|tap_to_click|lua-bool|Tap to click|||||Touchpad: a tap counts as a click|hyprctl reload||1|"
  "input.disableWhileTyping|Input|$HOME/.config/hypr/input.lua|disable_while_typing|lua-bool|Ignore touchpad while typing|||||Stops the cursor jumping mid-sentence|hyprctl reload||1|"
  # ── Lid & sleep — /etc/systemd/logind.conf.d/, root-owned, laptop only.
  # These are the three questions a laptop actually asks. logind's own built-in
  # default for all three is 'suspend'; the fallback field records that so the
  # panel can show a value even before a drop-in exists.
  "lid.close|Lid & sleep|$LOGIND_DROPIN|Login.HandleLidSwitch|ini-enum|Closing the lid||||suspend,suspend-then-hibernate,hibernate,lock,ignore,poweroff|What happens on battery when the lid closes|systemctl reload systemd-logind|suspend|1|"
  "lid.closeAc|Lid & sleep|$LOGIND_DROPIN|Login.HandleLidSwitchExternalPower|ini-enum|Closing the lid on AC||||suspend,suspend-then-hibernate,hibernate,lock,ignore,poweroff|What happens while plugged in — many people want 'ignore' here and 'suspend' on battery|systemctl reload systemd-logind|suspend|1|"
  "lid.closeDocked|Lid & sleep|$LOGIND_DROPIN|Login.HandleLidSwitchDocked|ini-enum|Closing the lid when docked||||ignore,suspend,suspend-then-hibernate,hibernate,lock,ignore,poweroff|What happens with an external monitor attached; 'ignore' is clamshell mode|systemctl reload systemd-logind|ignore|1|"
  # ── Defaults
  "default.editor|Defaults|$HOME/.local/state/omarchy/defaults/editor|-|line-enum|Default editor||||nvim,code,hx,micro,nano,zed|Editor Omarchy opens config files with||nvim|1|"
)

# Settings groups, in panel order: "name|icon|description"
SETTING_GROUPS=(
  "Idle & power|󰐥|When the screen dims, locks and the machine suspends"
  "Appearance|󰏘|Theme, bar and how large everything is drawn"
  "Input|󰌌|Keyboard and touchpad behaviour"
  "Lid & sleep|󰌢|What closing the lid does — shown on laptops only"
  "Defaults|󰒓|Which program Omarchy reaches for"
)


# Pure bash: `cut` here meant a fork per field, and the panel reads fifteen
# fields from twenty-odd settings on every refresh — three hundred processes
# for a string split.
setting_field() { local -a f; IFS='|' read -ra f <<<"$1"; printf '%s' "${f[$(($2 - 1))]:-}"; }

find_setting() {
  local id="$1" entry
  for entry in "${SETTINGS[@]}"; do
    [[ "$(setting_field "$entry" 1)" == "$id" ]] && { printf '%s\n' "$entry"; return 0; }
  done
  return 1
}

# ── TOML helpers ────────────────────────────────────────────────────────────
# Deliberately minimal: they target flat "key = value" lines inside a
# "[section]" of a small, hand-written config (shell.toml). They are not a TOML
# parser and are not meant to grow into one; anything more complex stays a
# whole-file entry in MANIFEST and is edited in a real editor.
toml_get() {
  local file="$1" section="${2%%.*}" key="${2#*.}"
  [[ -f "$file" ]] || return 1
  awk -v sect="[$section]" -v key="$key" '
    $0 ~ /^[[:space:]]*\[/ { in_sect = ($0 ~ "^[[:space:]]*\\" sect) ; next }
    in_sect && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      sub(/^[^=]*=[[:space:]]*/, ""); gsub(/[[:space:]]*$/, ""); print; exit
    }
  ' "$file"
}

# ─── systemd drop-ins (root-owned) ──────────────────────────────────────────
# A laptop's lid behaviour lives in /etc/systemd/logind.conf.d/, which is the
# one thing worth configuring here that is not ours to write. The shape of the
# file is close enough to TOML that the same reader works: [Section] headers and
# Key=Value lines, whitespace around '=' ignored by systemd either way.
ini_get() { toml_get "$1" "$2"; }

# root_apply <destination> <staged file> [command to run afterwards]
# Writes a staged file into a root-owned path, keeping the same .bak.<epoch>
# every other write in this plugin makes, and runs the reload in the SAME
# privileged call so the user is asked at most once.
#
# There is no silent path here. It tries, in order:
#   1. pkexec  — a graphical prompt, when the session runs a polkit agent
#   2. sudo -n — only if this user already has passwordless rights for it
#   3. nothing — prints the exact command and fails, leaving /etc untouched
# Omarchy ships no polkit agent by default, so (3) is the common outcome in the
# panel and (2)/(1) the common one from a terminal. Saying so is the point:
# a settings control that quietly does nothing is worse than one that explains.
root_apply() {
  local dst="$1" staged="$2" after="${3:-}" script rc=0
  script='dst="$1"; staged="$2"; after="$3";
    if [ -f "$dst" ]; then cp -a "$dst" "$dst.bak.$(date +%s)" || exit 1; fi
    install -D -m 644 -o root -g root "$staged" "$dst" || exit 1
    [ -n "$after" ] && { sh -c "$after" || exit 2; }
    exit 0'
  if command -v pkexec >/dev/null 2>&1 && [[ -n "${XDG_SESSION_ID:-}${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    if pkexec /bin/sh -c "$script" _ "$dst" "$staged" "$after" 2>/dev/null; then return 0; fi
    rc=1
  fi
  if sudo -n true 2>/dev/null; then
    if sudo -n /bin/sh -c "$script" _ "$dst" "$staged" "$after" 2>/dev/null; then return 0; fi
    rc=1
  fi
  echo "This one needs root, and nothing on this session could ask for it." >&2
  echo "Nothing was changed. To apply it yourself:" >&2
  echo "  sudo install -D -m 644 $staged $dst" >&2
  [[ -n "$after" ]] && echo "  sudo $after" >&2
  return "${rc:-1}"
}

# ini_set <file> <Section.Key> <value> [reload command]
# Stages the whole edited file under $HOME first, so the privileged step is a
# single copy of a file the user could have inspected, not an editor run as root.
ini_set() {
  local file="$1" path="$2" value="$3" after="${4:-}" staged
  staged=$(mktemp "${TMPDIR:-/tmp}/replicant-lid.XXXXXX") || return 1
  if [[ -f "$file" ]]; then cp -- "$file" "$staged"; else printf '[%s]\n' "${path%%.*}" > "$staged"; fi
  toml_set "$staged" "$path" "$value" || { rm -f "$staged"; return 1; }
  # toml_set keeps whatever spacing surrounded the '='; TOML writes `key = v`
  # and systemd writes `Key=v`. Normalise to systemd's idiom so a drop-in this
  # plugin has touched still reads like every other one on the machine.
  local k="${path#*.}"
  sed -i -E "s|^([[:space:]]*)${k}[[:space:]]*=[[:space:]]*|\1${k}=|" "$staged"
  if [[ -w "$file" || ( ! -e "$file" && -w "$(dirname "$file")" ) ]]; then
    backup_before_write "$file"
    install -D -m 644 "$staged" "$file" || { rm -f "$staged"; return 1; }
    [[ -n "$after" ]] && bash -c "$after" >/dev/null 2>&1
    rm -f "$staged"; return 0
  fi
  root_apply "$file" "$staged" "$after" || { rm -f "$staged"; return 1; }
  rm -f "$staged"
}

# Only a machine with a lid should be offered lid settings. On a desktop the
# group is not greyed out, it is absent — an irrelevant control is clutter.
is_laptop() {
  if command -v omarchy-hw-laptop >/dev/null 2>&1; then omarchy-hw-laptop >/dev/null 2>&1; return; fi
  [[ -d /proc/acpi/button/lid ]]
}

# Writes key = value, creating the [section] and/or the key when either is
# absent — shell.toml ships nearly empty, so "the key isn't there yet" is the
# normal first write for most appearance settings, not an error.
toml_set() {
  local file="$1" section="${2%%.*}" key="${2#*.}" value="$3" tmp
  [[ -f "$file" ]] || printf '' > "$file"
  tmp=$(mktemp)
  awk -v sect="[$section]" -v key="$key" -v val="$value" '
    BEGIN { done_it = 0; seen_sect = 0 }
    $0 ~ /^[[:space:]]*\[/ {
      if (in_sect && !done_it) { print key " = " val; done_it = 1 }
      in_sect = ($0 ~ "^[[:space:]]*\\" sect)
      if (in_sect) seen_sect = 1
      print; next
    }
    in_sect && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      if (done_it) next
      sub(/=[[:space:]]*.*/, "= " val); done_it = 1; print; next
    }
    { print }
    END {
      if (!done_it) {
        if (!seen_sect) { print ""; print sect }
        print key " = " val
      }
    }
  ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  [[ -s "$tmp" ]] || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$file"
}

# ── Hyprland Lua helpers ────────────────────────────────────────────────────
# Narrow on purpose. They match an uncommented "key = value" line and only act
# when that key appears EXACTLY ONCE in the file. A key that is absent, that
# only appears inside a `--` comment, or that appears in two different tables
# reads as missing, and the panel greys the control out.
#
# Refusing beats guessing here: these files decide whether the graphical session
# starts at all, and a generic nested-table editor would need a real Lua parser
# to be safe. Everything a single key can't express stays a whole-file entry in
# MANIFEST, edited in a real editor.
lua_key_hits() { grep -cE "^[[:space:]]*$2[[:space:]]*=" "$1" 2>/dev/null || true; }

lua_get() {
  local file="$1" key="$2" raw
  [[ -f "$file" ]] || return 1
  [[ "$(lua_key_hits "$file" "$key")" == "1" ]] || return 1
  raw=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" | head -n1)
  raw=${raw#*=}
  printf '%s\n' "$raw" | sed -e 's/--.*$//' -e 's/[[:space:]]*$//' -e 's/,$//' \
                             -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
                             -e 's/^"//' -e 's/"$//'
}

lua_set() {
  local file="$1" key="$2" value="$3" tmp
  [[ -f "$file" ]] || return 1
  [[ "$(lua_key_hits "$file" "$key")" == "1" ]] || return 1
  tmp=$(mktemp)
  awk -v key="$key" -v val="$value" '
    !done_it && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      line = $0; comment = ""
      ci = index(line, "--")
      if (ci > 0) { comment = substr(line, ci); line = substr(line, 1, ci - 1) }
      match(line, /^[[:space:]]*/); indent = substr(line, 1, RLENGTH)
      comma = (line ~ /,[[:space:]]*$/) ? "," : ""
      out = indent key " = " val comma
      if (comment != "") out = out " " comment
      print out; done_it = 1; next
    }
    { print }
    END { if (!done_it) exit 3 }
  ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  [[ -s "$tmp" ]] || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$file"
}

# backup_before_write <file> — the .bak.<epoch> every write owes the user,
# minus the litter. Editing one setting is a small, repeated act (dragging the
# density slider is a dozen writes), and one backup per write buried the real
# config under a heap of near-identical copies in the same directory. Keep the
# three most recent per file: enough to walk back a bad afternoon, few enough
# that `ls ~/.config/omarchy` still reads.
BACKUPS_KEPT=${REPLICANT_BACKUPS_KEPT:-3}
backup_before_write() {
  local file="$1" old
  [[ -f "$file" ]] || return 0
  cp -a "$file" "$file.bak.$(date +%s)" || return 1
  # shellcheck disable=SC2012  # names are ours: <file>.bak.<epoch>, no spaces
  while read -r old; do
    [[ -n "$old" ]] && rm -f -- "$old"
  done < <(ls -1t -- "$file".bak.* 2>/dev/null | tail -n +$((BACKUPS_KEPT + 1)))
}

# ── read / write one setting ────────────────────────────────────────────────
setting_options() {
  # The only dynamic option list: whatever themes are installed right now.
  local entry="$1"
  if [[ "$(setting_field "$entry" 5)" == "theme" ]]; then
    omarchy-theme-list 2>/dev/null | paste -sd, - || true
  else
    setting_field "$entry" 10
  fi
}

get_setting_value() {
  local entry; entry=$(find_setting "$1") || return 1
  local file path type raw
  file=$(setting_field "$entry" 3); path=$(setting_field "$entry" 4); type=$(setting_field "$entry" 5)
  case "$type" in
    theme)
      omarchy-theme-current 2>/dev/null || return 1
      ;;
    line-enum)
      [[ -f "$file" ]] || return 1
      raw=$(head -n1 "$file" 2>/dev/null | tr -d '[:space:]')
      [[ -n "$raw" ]] || return 1
      printf '%s\n' "$raw"
      ;;
    toml-int|toml-float)
      [[ -f "$file" ]] || return 1
      raw=$(toml_get "$file" "$path") || return 1
      [[ -n "$raw" ]] || return 1
      printf '%s\n' "$raw"
      ;;
    ini-enum)
      # No drop-in yet means logind is on its built-in default, which is what
      # the fallback field records — so report that rather than "missing".
      if [[ -f "$file" ]]; then
        raw=$(ini_get "$file" "$path" 2>/dev/null || true)
        [[ -n "$raw" ]] && { printf '%s\n' "$raw"; return 0; }
      fi
      raw=$(setting_field "$entry" 13)
      [[ -n "$raw" ]] || return 1
      printf '%s\n' "$raw"
      ;;
    lua-int|lua-bool|lua-enum)
      lua_get "$file" "$path"
      ;;
    *)
      [[ -f "$file" ]] || return 1
      # Not `// empty`: jq's alternative operator fires on `false` as well as
      # `null`, so a boolean setting that is genuinely off would read as missing.
      raw=$(jq -r "$path" "$file" 2>/dev/null) || return 1
      [[ "$raw" == "null" ]] && return 1
      printf '%s\n' "$raw"
      ;;
  esac
}

# numeric guard that also works for floats (bash arithmetic is integer-only)
num_in_range() {
  # Callers have already checked the shape of $1; this only bounds it, in awk
  # because bash arithmetic cannot compare floats.
  awk -v v="$1" -v lo="$2" -v hi="$3" '
    BEGIN {
      if (lo != "" && v + 0 < lo + 0) exit 1
      if (hi != "" && v + 0 > hi + 0) exit 1
      exit 0
    }' </dev/null
}

set_setting_value() {
  local entry; entry=$(find_setting "$1") || { echo "unknown setting: $1" >&2; return 1; }
  local file path type label unit min max options apply value="$2"
  file=$(setting_field "$entry" 3);    path=$(setting_field "$entry" 4)
  type=$(setting_field "$entry" 5);    label=$(setting_field "$entry" 6)
  unit=$(setting_field "$entry" 7);    min=$(setting_field "$entry" 8)
  max=$(setting_field "$entry" 9);     apply=$(setting_field "$entry" 12)
  options=$(setting_options "$entry")

  # ── validate before touching anything
  case "$type" in
    number|toml-int|lua-int)
      [[ "$value" =~ ^-?[0-9]+$ ]] || { echo "$1: '$value' is not a whole number" >&2; return 1; }
      num_in_range "$value" "$min" "$max" || { echo "$1: $value$unit is outside ${min:-?}–${max:-?}$unit" >&2; return 1; }
      ;;
    toml-float)
      [[ "$value" =~ ^-?[0-9]*\.?[0-9]+$ ]] || { echo "$1: '$value' is not a number" >&2; return 1; }
      num_in_range "$value" "$min" "$max" || { echo "$1: $value$unit is outside ${min:-?}–${max:-?}$unit" >&2; return 1; }
      ;;
    bool|lua-bool)
      [[ "$value" == "true" || "$value" == "false" ]] || { echo "$1: '$value' must be true or false" >&2; return 1; }
      ;;
    enum|lua-enum|line-enum|theme|ini-enum)
      [[ -n "$options" ]] || { echo "$1: no options available on this machine" >&2; return 1; }
      [[ ",$options," == *",$value,"* ]] || { echo "$1: '$value' is not one of: ${options//,/, }" >&2; return 1; }
      ;;
  esac

  # ── write
  case "$type" in
    theme)
      omarchy-theme-set "$value" >/dev/null 2>&1 || { echo "$1: omarchy-theme-set failed" >&2; return 1; }
      ;;
    line-enum)
      backup_before_write "$file"
      mkdir -p "$(dirname "$file")"
      printf '%s\n' "$value" > "$file" || { echo "$1: could not write $file" >&2; return 1; }
      ;;
    toml-int|toml-float)
      backup_before_write "$file"
      toml_set "$file" "$path" "$value" || { echo "$1: could not write '$path' in $file — left untouched" >&2; return 1; }
      ;;
    ini-enum)
      # The reload is part of the privileged write, so root is asked once, not
      # twice — hence apply is consumed here and cleared before the tail below.
      ini_set "$file" "$path" "$value" "$apply" || { echo "$1: $file was left untouched" >&2; return 1; }
      apply=""
      ;;
    lua-int|lua-bool)
      [[ -f "$file" ]] || { echo "file not found: $file" >&2; return 1; }
      backup_before_write "$file"
      lua_set "$file" "$path" "$value" || { echo "$1: '$path' is missing or ambiguous in $file — left untouched" >&2; return 1; }
      ;;
    lua-enum)
      [[ -f "$file" ]] || { echo "file not found: $file" >&2; return 1; }
      backup_before_write "$file"
      lua_set "$file" "$path" "\"$value\"" || { echo "$1: '$path' is missing or ambiguous in $file — left untouched" >&2; return 1; }
      ;;
    number|bool)
      [[ -f "$file" ]] || { echo "file not found: $file" >&2; return 1; }
      backup_before_write "$file"
      local tmp; tmp=$(mktemp)
      jq --argjson v "$value" "$path = \$v" "$file" > "$tmp" 2>/dev/null
      [[ -s "$tmp" ]] || { echo "$1: write failed, left $file untouched" >&2; rm -f "$tmp"; return 1; }
      mv "$tmp" "$file"
      ;;
    *)
      [[ -f "$file" ]] || { echo "file not found: $file" >&2; return 1; }
      backup_before_write "$file"
      local tmp; tmp=$(mktemp)
      jq --arg v "$value" "$path = \$v" "$file" > "$tmp" 2>/dev/null
      [[ -s "$tmp" ]] || { echo "$1: write failed, left $file untouched" >&2; rm -f "$tmp"; return 1; }
      mv "$tmp" "$file"
      ;;
  esac

  # ── make it take effect, when the target isn't watching its own file
  if [[ -n "$apply" ]]; then
    bash -c "$apply" >/dev/null 2>&1 || echo "$1: written, but '$apply' failed — it may need a manual reload" >&2
  fi
  echo "$label -> $value$unit" >&2
}

# ── humanising values ───────────────────────────────────────────────────────
# Omarchy stores idle timers in seconds and densities as bare multipliers.
# Those are the right things to store and the wrong things to *read*: "600"
# tells you nothing, "10 min" tells you everything. Every number the panel
# shows goes through here, and the CLI keeps speaking the stored unit.
human_duration() {
  local s="$1" h m
  [[ "$s" =~ ^[0-9]+$ ]] || { printf '%s\n' "$s"; return; }
  (( s == 0 )) && { echo "never"; return; }
  (( s < 60 )) && { echo "${s} s"; return; }
  if (( s < 3600 )); then
    m=$(( s / 60 ))
    if (( s % 60 == 0 )); then echo "${m} min"; else echo "${m} min $(( s % 60 )) s"; fi
    return
  fi
  h=$(( s / 3600 )); m=$(( (s % 3600) / 60 ))
  if (( m == 0 )); then echo "${h} h"; else echo "${h} h ${m} min"; fi
}

# "1" and "1.0" are the same density; printing them differently made the panel
# offer a "back to the Omarchy default" button that would have changed nothing.
canon_number() {
  local v="$1"
  [[ "$v" == *.* ]] || { printf '%s\n' "$v"; return; }
  v="${v%"${v##*[!0]}"}"   # drop trailing zeros
  v="${v%.}"               # and a bare trailing dot
  printf '%s\n' "${v:-0}"
}

# human_value <type> <unit> <scale> <display_unit> <raw>
human_value() {
  local type="$1" unit="$2" scale="$3" disp="$4" raw="$5"
  [[ -n "$raw" ]] || { echo "—"; return; }
  case "$type" in
    bool|lua-bool) [[ "$raw" == "true" ]] && echo "on" || echo "off"; return ;;
    toml-float)    raw=$(canon_number "$raw") ;;
  esac
  if [[ "$scale" == "60" ]]; then human_duration "$raw"; return; fi
  case "$unit" in
    "")  printf '%s\n' "$raw" ;;
    "×") printf '%s×\n' "$raw" ;;
    "/s") printf '%s/s\n' "$raw" ;;
    *)   printf '%s %s\n' "$raw" "${disp:-$unit}" ;;
  esac
}

# ── where a setting's value came from, and what to put back ─────────────────
# rel_for_src is the reverse of resolve_manifest_src: it answers "which repo
# path holds the saved copy of this file", so a single setting can be reverted
# to what the repo has without restoring the whole file.
rel_for_src() {
  local src="$1" entry
  for entry in "${TRACKED[@]}" "${TRACKED_SECRETS[@]}"; do
    [[ "${entry%%:*}" == "$src" ]] && { printf '%s\n' "${entry##*:}"; return 0; }
  done
  return 1
}

repo_copy_for_rel() {
  case "$1" in
    ssh/*|env/*) printf '%s\n' "$SECRETS_DIR/$1" ;;
    *)           repo_path_for "$1" ;;
  esac
}

# read_setting_from <entry> <file> — the same getter as get_setting_value, but
# pointed at any file. Used to read the key out of Omarchy's shipped default
# and out of the repo's saved copy, which is what makes the two revert buttons
# possible without a second parser.
read_setting_from() {
  local entry="$1" file="$2" path type raw
  path=$(setting_field "$entry" 4); type=$(setting_field "$entry" 5)
  [[ -f "$file" ]] || return 1
  case "$type" in
    line-enum)
      raw=$(head -n1 "$file" 2>/dev/null | tr -d '[:space:]')
      [[ -n "$raw" ]] && printf '%s\n' "$raw" || return 1 ;;
    toml-int|toml-float)
      raw=$(toml_get "$file" "$path") || return 1
      [[ -n "$raw" ]] && printf '%s\n' "$raw" || return 1 ;;
    lua-int|lua-bool|lua-enum)
      lua_get "$file" "$path" ;;
    number|bool|enum)
      raw=$(jq -r "$path" "$file" 2>/dev/null) || return 1
      [[ "$raw" == "null" ]] && return 1
      printf '%s\n' "$raw" ;;
    *) return 1 ;;
  esac
}

# The value this setting would have on a machine that had never been touched.
# Read out of the file Omarchy actually ships where there is one; otherwise the
# registry's `fallback`, which is the shell's own built-in default.
setting_default_value() {
  local entry; entry=$(find_setting "$1") || return 1
  local file def
  file=$(setting_field "$entry" 3)
  if [[ "$file" != "-" ]] && def=$(default_for_src "$file" 2>/dev/null) && [[ -n "$def" ]]; then
    read_setting_from "$entry" "$def" && return 0
  fi
  def=$(setting_field "$entry" 13)
  [[ -n "$def" ]] && { printf '%s\n' "$def"; return 0; }
  return 1
}

# The value saved in the user's own repo — "what my other machine has".
setting_repo_value() {
  local entry; entry=$(find_setting "$1") || return 1
  local file rel copy
  file=$(setting_field "$entry" 3)
  [[ "$file" != "-" ]] || return 1
  rel=$(rel_for_src "$file") || return 1
  copy=$(repo_copy_for_rel "$rel")
  read_setting_from "$entry" "$copy"
}

# core_revert <id> <default|repo> — put one setting back without touching the
# rest of the file it lives in. The whole-file equivalents (`reset`, `restore`)
# are still there; this is the small, everyday one.
core_revert() {
  local id="$1" to="${2:-default}" value
  case "$to" in
    default) value=$(setting_default_value "$id") || { echo "no Omarchy default known for $id" >&2; return 1; } ;;
    repo)    value=$(setting_repo_value "$id")    || { echo "$id is not saved in your repo yet" >&2; return 1; } ;;
    *)       echo "revert: --to must be 'default' or 'repo'" >&2; return 1 ;;
  esac
  set_setting_value "$id" "$value"
}

# Numbers the panel can show without the user doing arithmetic. `value` stays
# the stored value (what the CLI reads and writes); `display_*` is the same
# quantity in the unit a person thinks in, and `value_text` is the exact
# current value written out in full, which is what the Overview table shows.
settings_display_step() {
  local scale="$1" dmax="$2" unit="$3"
  if [[ "$scale" != "1" && -n "$scale" ]]; then
    if [[ -n "$dmax" ]] && (( dmax > 60 )); then echo 5; else echo 1; fi
  elif [[ "$unit" == "ms" ]]; then echo 50
  else echo 1
  fi
}

build_settings_json() {
  # One jq invocation for the whole array, not one per setting. The panel polls
  # status once a minute and refreshes after every write, and twenty-odd `jq -n`
  # spawns per build were most of the time that took.
  local entry id group file path type label unit min max options hint value available fallback implicit
  local scale disp dvalue dmin dmax dstep vtext defval deftext repoval repotext canrd canrr numeric boolean
  {
  local laptop=1; is_laptop || laptop=0
  for entry in "${SETTINGS[@]}"; do
    id=$(setting_field "$entry" 1);      group=$(setting_field "$entry" 2)
    # A desktop has no lid. The group is absent rather than greyed out.
    [[ "$group" == "Lid & sleep" && "$laptop" == 0 ]] && continue
    file=$(setting_field "$entry" 3);    path=$(setting_field "$entry" 4)
    type=$(setting_field "$entry" 5);    label=$(setting_field "$entry" 6)
    unit=$(setting_field "$entry" 7);    min=$(setting_field "$entry" 8)
    max=$(setting_field "$entry" 9);     hint=$(setting_field "$entry" 11)
    fallback=$(setting_field "$entry" 13)
    scale=$(setting_field "$entry" 14);  disp=$(setting_field "$entry" 15)
    [[ -n "$scale" ]] || scale=1
    [[ -n "$disp" ]] || disp="$unit"
    options=$(setting_options "$entry")
    value=$(get_setting_value "$id" 2>/dev/null) || value=""
    implicit=false
    if [[ -z "$value" && -n "$fallback" ]]; then value="$fallback"; implicit=true; fi
    if [[ -n "$value" ]]; then available=true; else available=false; fi

    # Shape check per type — a malformed value is "not available", never a
    # control bound to a value it cannot render.
    numeric=false; boolean=false
    case "$type" in
      number|toml-int|lua-int)
        numeric=true; [[ "$value" =~ ^-?[0-9]+$ ]] || { value=""; available=false; } ;;
      toml-float)
        numeric=true; [[ "$value" =~ ^-?[0-9]*\.?[0-9]+$ ]] || { value=""; available=false; } ;;
      bool|lua-bool)
        boolean=true; [[ "$value" == "true" || "$value" == "false" ]] || { value="false"; available=false; } ;;
    esac

    dvalue=""; dmin=""; dmax=""; dstep=1
    if [[ "$numeric" == true ]]; then
      if [[ "$scale" == "1" ]]; then
        dvalue="$value"; dmin="$min"; dmax="$max"
      else
        [[ -n "$value" ]] && dvalue=$(( (value + scale / 2) / scale ))
        [[ -n "$min" ]] && dmin=$(( (min + scale - 1) / scale ))
        [[ -n "$max" ]] && dmax=$(( max / scale ))
      fi
      dstep=$(settings_display_step "$scale" "$dmax" "$unit")
    fi

    vtext=$(human_value "$type" "$unit" "$scale" "$disp" "$value")
    defval=$(setting_default_value "$id" 2>/dev/null) || defval=""
    repoval=$(setting_repo_value "$id" 2>/dev/null) || repoval=""
    deftext=$(human_value "$type" "$unit" "$scale" "$disp" "$defval")
    repotext=$(human_value "$type" "$unit" "$scale" "$disp" "$repoval")
    # Compare the rendered text, not the raw string: shell.toml holding "1" and
    # a fallback of "1.0" are the same density, and offering a revert button
    # that would change nothing is worse than offering none.
    canrd=false; canrr=false
    [[ -n "$defval"  && "$deftext"  != "$vtext" && "$available" == true ]] && canrd=true
    [[ -n "$repoval" && "$repotext" != "$vtext" && "$available" == true ]] && canrr=true

    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
      "$id" "$group" "$label" "$type" "$unit" "$min" "$max" "$options" "$hint" "$file" \
      "$available" "$implicit" "$value" "$scale" "$disp" "$dvalue" "$dmin" "$dmax" "$dstep" \
      "$vtext" "$defval" "$deftext" "$repoval" "$repotext" "$canrd" "$canrr" "$numeric" "$boolean"
  done
  } | jq -Rsc '
    def num: if . == "" then null else (tonumber? // null) end;
    def flag: . == "true";
    split("\n") | map(select(length > 0) | split("\u001f") | {
      id: .[0], group: .[1], label: .[2], type: .[3], unit: .[4],
      min: (.[5]|num), max: (.[6]|num),
      options: (if .[7] == "" then [] else (.[7]|split(",")) end),
      hint: .[8], file: .[9],
      available: (.[10]|flag), implicit: (.[11]|flag),
      value: (if (.[27]|flag) then (.[12] == "true")
              elif (.[26]|flag) then (.[12]|num)
              else .[12] end),
      scale: (.[13]|num), display_unit: .[14],
      display_value: (.[15]|num), display_min: (.[16]|num),
      display_max: (.[17]|num), display_step: ((.[18]|num) // 1),
      value_text: .[19],
      default_value: .[20], default_text: .[21],
      repo_value: .[22], repo_text: .[23],
      can_revert_default: (.[24]|flag), can_revert_repo: (.[25]|flag)
    })' | jq -c '
    # A second pass, because a notice is about how settings sit RELATIVE to each
    # other and the per-setting record cannot see its siblings.
    #
    # Exactly one rule, on purpose. A screensaver set at or after the lock timer
    # can never appear — the setting silently does nothing, which is worth
    # saying. The other orderings people assume are wrong are not: a display that
    # sleeps long before the lock is a normal power choice, and suspending before
    # the lock timer is fine because Omarchy locks on suspend. Warning about
    # those fires on a perfectly good config and teaches people to ignore
    # notices, which costs more than it saves.
    #
    # A notice, never a refusal. A deliberate 0 ("never") is a real answer.
    def val($id): [ .[] | select(.id == $id) | .value ][0];
    (val("idle.screensaver")) as $ss
    | (val("idle.lock")) as $lock
    | map(. + { notice: (
        if .id == "idle.screensaver" and ($ss != null and $lock != null and $lock > 0 and $ss >= $lock)
          then "The screen locks first, so this screensaver never appears."
        else "" end) })'
}

build_setting_groups_json() {
  local entries=() entry
  local laptop=1; is_laptop || laptop=0
  for entry in "${SETTING_GROUPS[@]}"; do
    [[ "${entry%%|*}" == "Lid & sleep" && "$laptop" == 0 ]] && continue
    entries+=("$(jq -nc --arg name "$(printf '%s' "$entry" | cut -d'|' -f1)" \
      --arg icon "$(printf '%s' "$entry" | cut -d'|' -f2)" \
      --arg description "$(printf '%s' "$entry" | cut -d'|' -f3)" \
      '{name:$name,icon:$icon,description:$description}')")
  done
  printf '%s\n' "${entries[@]}" | jq -s '.'
}

build_configs_json() {
  # One jq for the whole list. Same reason as build_settings_json: this runs on
  # every panel refresh and there are forty-odd rows.
  local entry src rel label category exists is_default has_default default_src config_rel
  local dirty unpushed sync_state saved synced source scope repo_path git_rel unsaved is_dir nfiles
  {
  for entry in "${TRACKED[@]}"; do
    src="${entry%%:*}"; rel="${entry##*:}"; label="$rel"
    category=$(category_for_rel "$rel")
    is_dir=false; nfiles=0
    is_dir_entry "$rel" && is_dir=true
    if [[ "$is_dir" == true ]]; then
      [[ -d "${src%/}" ]] && exists=true || exists=false
      [[ "$exists" == true ]] && nfiles=$(tree_count "$src")
    else
      [[ -f "$src" ]] && exists=true || exists=false
    fi
    has_default=false; default_src=""
    if [[ "$is_dir" == false ]] && default_src=$(default_for_src "$src" 2>/dev/null) && [[ -n "$default_src" ]]; then has_default=true; fi
    config_rel=""
    [[ "$is_dir" == false ]] && config_rel=$(config_rel_for_src "$src" 2>/dev/null || true)
    if [[ "$exists" == true && "$has_default" == true ]] && cmp -s "$src" "$default_src" 2>/dev/null; then
      is_default=true
    else
      is_default=false
    fi
    scope=$(scope_for "$rel")
    repo_path=$(repo_path_for "$rel")
    git_rel="${repo_path#"$REPO_DIR"/}"
    saved=false
    if [[ "$is_dir" == true ]]; then
      [[ -d "${repo_path%/}" ]] && saved=true
    else
      [[ -f "$repo_path" ]] && saved=true
    fi
    # "Unsaved" is a question about CONTENT: does the file on this machine differ
    # from the copy the repo holds? Asking git instead only ever sees files
    # core_backup has already copied in, so a file edited on the machine and
    # never saved reported itself as "saved on GitHub" — a backup tool claiming
    # a change was safe when it was nowhere.
    #
    # Comparing content is also what makes the warning self-healing: edit a file
    # and put it back, and cmp matches again, so the badge clears on its own with
    # no flag to go stale.
    #
    # A directory answers the same question the same way, file by file:
    # tree_same is cmp over the whole tree, so adding, editing or deleting
    # anything inside a tracked directory shows up, and undoing it clears.
    unsaved=false
    if [[ "$exists" == true ]]; then
      if [[ "$is_dir" == true ]]; then
        tree_same "$src" "$repo_path" || unsaved=true
      elif [[ "$saved" == false ]] || ! cmp -s "$src" "$repo_path" 2>/dev/null; then
        unsaved=true
      fi
    fi
    # Copied into the repo but not committed is unsaved too — same word, same
    # button. Content and git each catch a case the other misses.
    dirty=false
    git -C "$REPO_DIR" status --porcelain -- "$git_rel" 2>/dev/null | grep -q . && dirty=true
    [[ "$dirty" == true ]] && unsaved=true
    unpushed=false
    path_unpushed "$git_rel" && unpushed=true
    synced=true
    [[ "$scope" == "off" ]] && synced=false
    # off > missing > unsaved > default > unpushed > saved.
    #
    # unsaved MUST outrank default. Putting a customised file back to Omarchy's
    # default is itself a change that still needs saving, and it used to show the
    # calm "default" badge while the repo still held the old customised version —
    # the pending change hidden behind the tidiest-looking state.
    #
    # default outranks unpushed the other way round, and deliberately. Before the
    # first push nothing is on GitHub, so every untouched default file would
    # light up as "to push" and drown the handful of rows that actually changed.
    # Pushing is a repo-level act the header already prompts for; per file, what
    # matters is whether THIS machine has something the repo does not.
    if [[ "$synced" == false ]]; then sync_state="off"
    elif [[ "$exists" == false ]]; then sync_state="missing"
    elif [[ "$unsaved" == true ]]; then sync_state="unsaved"
    elif [[ "$is_default" == true ]]; then sync_state="default"
    elif [[ "$unpushed" == true ]]; then sync_state="unpushed"
    else sync_state="saved"
    fi
    # A shipped entry this machine has never had, and the repo has never held,
    # is not a row worth drawing. The core list is written for every Omarchy
    # user, so any one machine is expected to be missing part of it — showing
    # ghost rows for a terminal you don't use buries the files you do. It stays
    # in the list, so the day you create the file it appears; and one the repo
    # HAS a copy of always shows, because "it was here and now it isn't" is
    # exactly the kind of thing a backup tool must not hide.
    source=manifest
    is_user_entry "$rel" && source=user
    if [[ "$source" == manifest && "$exists" == false && "$saved" == false ]]; then continue; fi
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
      "$rel" "$label" "$src" "$category" "$exists" "$is_default" "$has_default" \
      "$config_rel" "$dirty" "$unpushed" "$sync_state" "$saved" "$synced" "$source" "$scope" "$unsaved" \
      "$is_dir" "$nfiles"
  done
  # Auto-detected entries from other plugins. No Omarchy default ships for
  # these, so they can never read as "default".
  local psrc prel pname
  while IFS=$'\t' read -r psrc prel pname; do
    [[ -n "$psrc" ]] || continue
    saved=false
    [[ -f "$CONFIG_DIR/$prel" ]] && saved=true
    unsaved=false
    if [[ "$saved" == false ]] || ! cmp -s "$psrc" "$CONFIG_DIR/$prel" 2>/dev/null; then unsaved=true; fi
    dirty=false
    git -C "$REPO_DIR" status --porcelain -- "config/$prel" 2>/dev/null | grep -q . && dirty=true
    [[ "$dirty" == true ]] && unsaved=true
    unpushed=false
    path_unpushed "config/$prel" && unpushed=true
    synced=true
    is_excluded "$prel" && synced=false
    if [[ "$synced" == false ]]; then sync_state="off"
    elif [[ "$unsaved" == true ]]; then sync_state="unsaved"
    elif [[ "$unpushed" == true ]]; then sync_state="unpushed"
    else sync_state="saved"
    fi
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
      "$prel" "$pname" "$psrc" "plugins" "true" "false" "false" \
      "omarchy/${psrc##*/}" "$dirty" "$unpushed" "$sync_state" "$saved" "$synced" "auto" "$(scope_for "$prel")" "$unsaved" \
      "false" "0"
  done < <(discover_plugin_entries)
  } | jq -Rsc '
    def flag: . == "true";
    split("\n") | map(select(length > 0) | split("\u001f") | {
      id: .[0], label: .[1], src: .[2],
      category: .[3], group: .[3],
      exists: (.[4]|flag), is_default: (.[5]|flag), has_default: (.[6]|flag),
      config_rel: .[7], dirty: (.[8]|flag), unpushed: (.[9]|flag),
      sync_state: .[10], saved: (.[11]|flag), synced: (.[12]|flag),
      source: .[13], scope: .[14], unsaved: (.[15]|flag),
      is_dir: (.[16]|flag), nfiles: (.[17]|tonumber? // 0)
    })'
}

# Secrets get their own shape, and deliberately never their own content. What
# the panel needs is "is it here, is it saved, are the permissions right" — a
# preview of an SSH private key on screen is a way to leak it over a shoulder or
# a screen share, so the only thing read out of an env file is the NAMES of the
# variables it defines.
build_secrets_json() {
  local entry src rel exists mode kind dirty unpushed saved synced sync_state vars nvars unsaved
  {
  for entry in "${TRACKED_SECRETS[@]}"; do
    src="${entry%%:*}"; rel="${entry##*:}"
    [[ -f "$src" ]] && exists=true || exists=false
    mode=""
    [[ "$exists" == true ]] && mode=$(stat -c '%a' "$src" 2>/dev/null || echo "")
    case "$rel" in
      *.pub)  kind="public key" ;;
      ssh/*)  kind="private key" ;;
      env/*)  kind="environment" ;;
      *)      kind="secret" ;;
    esac
    vars=""; nvars=0
    if [[ "$exists" == true && "$rel" == env/* ]]; then
      vars=$(grep -oE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*(?==)' "$src" 2>/dev/null \
             | sed -e 's/^[[:space:]]*//' -e 's/^export[[:space:]]*//' | sort -u | paste -sd, - || true)
      [[ -z "$vars" ]] && vars=$(grep -oE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' "$src" 2>/dev/null \
             | sed -e 's/^[[:space:]]*//' -e 's/^export[[:space:]]*//' -e 's/=$//' | sort -u | paste -sd, - || true)
      [[ -n "$vars" ]] && nvars=$(printf '%s' "$vars" | tr ',' '\n' | grep -c .)
    fi
    saved=false
    [[ -f "$SECRETS_DIR/$rel" ]] && saved=true
    # Same content-first rule as the config rows. cmp reads both files but says
    # only whether they differ — no secret is read INTO a variable, printed, or
    # put in the JSON. Comparing is not revealing.
    unsaved=false
    if [[ "$exists" == true ]]; then
      if [[ "$saved" == false ]] || ! cmp -s "$src" "$SECRETS_DIR/$rel" 2>/dev/null; then unsaved=true; fi
    fi
    dirty=false
    git -C "$REPO_DIR" status --porcelain -- "secrets/$rel" 2>/dev/null | grep -q . && dirty=true
    [[ "$dirty" == true ]] && unsaved=true
    unpushed=false
    path_unpushed "secrets/$rel" && unpushed=true
    synced=true
    is_excluded "$rel" && synced=false
    if [[ "$synced" == false ]]; then sync_state="off"
    elif [[ "$exists" == false ]]; then sync_state="missing"
    elif [[ "$unsaved" == true ]]; then sync_state="unsaved"
    elif [[ "$unpushed" == true ]]; then sync_state="unpushed"
    else sync_state="saved"
    fi
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
      "$rel" "$src" "$exists" "$mode" "$kind" "$dirty" "$unpushed" "$saved" \
      "$synced" "$sync_state" "$vars" "$nvars"
  done
  } | jq -Rsc '
    def flag: . == "true";
    split("\n") | map(select(length > 0) | split("\u001f") | {
      id: .[0], src: .[1], exists: (.[2]|flag), mode: .[3], kind: .[4],
      dirty: (.[5]|flag), unpushed: (.[6]|flag), saved: (.[7]|flag),
      synced: (.[8]|flag), sync_state: .[9],
      vars: (if .[10] == "" then [] else (.[10]|split(",")) end),
      var_count: ((.[11]|tonumber?) // 0)
    })'
}

# core_shortcuts — the keyboard, in two halves. Omarchy's model is "defaults,
# plus your overrides in hypr/bindings.lua", so the backup tracks the overrides
# (a snapshot of every active binding would go stale with the next update) while
# the panel shows both: what you changed, and what is actually bound right now.
core_shortcuts() {
  local own_file="$HOME/.config/hypr/bindings.lua"
  local own active
  own=$(awk '
    /^[[:space:]]*--/ { next }
    match($0, /o\.bind\(/) {
      line = $0
      n = split(line, parts, /"/)
      if (n >= 3) {
        key = parts[2]
        # o.bind(keys, description, command) — but the description is often
        # written as a bare `nil`, and then the second quoted string is the
        # COMMAND. Counting quotes alone labels every such binding with its own
        # command as its name.
        if (parts[3] ~ /,[[:space:]]*nil[[:space:]]*,/) {
          desc = ""
          cmd  = (n >= 5) ? parts[4] : ""
        } else {
          desc = (n >= 5) ? parts[4] : ""
          cmd  = (n >= 7) ? parts[6] : ""
        }
        printf "%s\t%s\t%s\tbind\n", key, desc, cmd
      }
      next
    }
    match($0, /hl\.unbind\(/) {
      n = split($0, parts, /"/)
      if (n >= 3) printf "%s\t%s\t%s\tunbind\n", parts[2], "removed", "", ""
    }
  ' "$own_file" 2>/dev/null | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t")
      | {key: .[0], description: .[1], command: .[2], kind: .[3]})')
  [[ -n "$own" ]] || own='[]'
  active=$(omarchy menu keybindings --print 2>/dev/null |
    sed -e 's/[[:space:]]*→[[:space:]]*/\t/' |
    jq -Rsc 'split("\n") | map(select(length > 0) | split("\t")
      | {key: (.[0] // "" | sub("[[:space:]]+$";"")), description: (.[1] // "")})')
  [[ -n "$active" ]] || active='[]'
  jq -nc --argjson own "$own" --argjson active "$active" --arg file "$own_file" \
    '{file:$file, own:$own, active:$active, own_count:($own|length), active_count:($active|length)}'
}

# How often status may hit the network on its own. The bar widget polls this
# every minute; fetching on every poll meant a git fetch a minute, forever, on
# a laptop. An explicit refresh (opening the panel, pressing the refresh
# button, finishing a write) passes --fetch and is never throttled.
FETCH_MAX_AGE=${REPLICANT_FETCH_MAX_AGE:-300}

should_fetch() {
  local stamp="$REPLICANT_HOME/.last-fetch" now age
  now=$(date +%s)
  [[ -f "$stamp" ]] || return 0
  age=$(( now - $(cat "$stamp" 2>/dev/null || echo 0) ))
  (( age >= FETCH_MAX_AGE ))
}

core_status() {
  local json=0 force_fetch=0 arg
  for arg in "$@"; do
    case "$arg" in
      --json) json=1 ;;
      --fetch) force_fetch=1 ;;
      --no-fetch) force_fetch=-1 ;;
    esac
  done
  if [[ ! -d "$REPO_DIR/.git" ]]; then
    if (( json )); then echo '{"initialized":false}'; else echo "not initialized — run omarchy-replicant init --savegame"; fi
    return 0
  fi
  # Best-effort refresh of origin/HEAD so unpushed/ahead/behind are accurate.
  # Never blocks when there is no network, and never runs more often than
  # FETCH_MAX_AGE unless explicitly asked.
  if (( force_fetch >= 0 )) && { (( force_fetch == 1 )) || should_fetch; }; then
    timeout 3 git -C "$REPO_DIR" fetch --quiet 2>/dev/null || true
    date +%s > "$REPLICANT_HOME/.last-fetch" 2>/dev/null || true
  fi
  local branch remote dirty untracked ahead behind
  branch=$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
  remote=$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || echo "")
  dirty=$(git -C "$REPO_DIR" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  untracked=$(git -C "$REPO_DIR" status --porcelain 2>/dev/null | grep -c '^??' || true)
  ahead=0; behind=0
  if git -C "$REPO_DIR" rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
    ahead=$(git -C "$REPO_DIR" rev-list --count @{u}..HEAD 2>/dev/null || echo 0)
    behind=$(git -C "$REPO_DIR" rev-list --count HEAD..@{u} 2>/dev/null || echo 0)
  fi
  local pending_groups=""
  if git -C "$REPO_DIR" status --porcelain -- config/ 2>/dev/null | grep -q .; then pending_groups="$pending_groups config"; fi
  if git -C "$REPO_DIR" status --porcelain -- secrets/ 2>/dev/null | grep -q .; then pending_groups="$pending_groups secrets"; fi
  if git -C "$REPO_DIR" status --porcelain -- state/ 2>/dev/null | grep -q .; then pending_groups="$pending_groups state"; fi
  if (( json )); then
    local configs_json secrets_json settings_json categories_json groups_json machines_json
    configs_json=$(build_configs_json)
    secrets_json=$(build_secrets_json)
    settings_json=$(build_settings_json)
    categories_json=$(build_categories_json)
    groups_json=$(build_setting_groups_json)
    # Every machine that has ever saved into this repo, newest first. With one
    # machine it is a footnote; with two it is the answer to "did the desktop
    # actually push?", which is the whole reason the repo exists.
    machines_json=$(
      { for d in "$STATE_ROOT"/*/; do
          [[ -d "$d" ]] || continue
          local mname mwhen
          mname=$(basename "$d")
          mwhen=$(git -C "$REPO_DIR" log -1 --date=format:'%d %b %H:%M' --format='%ad' -- "state/$mname" 2>/dev/null || true)
          local mprof; mprof=$(profile_for_machine "$mname" 2>/dev/null || echo "")
          printf '%s\t%s\t%s\t%s\n' "$mname" "$mwhen" \
            "$( [[ "$mname" == "$MACHINE" ]] && echo true || echo false )" "$mprof"
        done; } | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t")
          | {name: .[0], last_save: .[1], current: (.[2] == "true"), profile: (.[3] // "")})'
    )
    # Which profiles exist, and how many files each one is actually holding —
    # the answer to "did scoping that file to a profile do anything?".
    local profiles_json
    profiles_json=$(
      { local pr pn
        while IFS= read -r pr; do
          [[ -n "$pr" ]] || continue
          pn=$(find "$REPO_DIR/profiles/$pr/config" -type f 2>/dev/null | wc -l || true)
          printf '%s\t%s\t%s\n' "$pr" "$pn" "$( [[ "$pr" == "$(current_profile)" ]] && echo true || echo false )"
        done < <(list_profiles); } | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t")
          | {name: .[0], files: (.[1]|tonumber? // 0), current: (.[2] == "true")})'
    )
    local remote_name="" last_save="" last_subject="" plugin_version=""
    [[ -n "$remote" ]] && remote_name="${remote##*/}" && remote_name="${remote_name%.git}"
    last_save=$(git -C "$REPO_DIR" log -1 --date=format:'%d %b %H:%M' --format='%ad' 2>/dev/null || true)
    last_subject=$(git -C "$REPO_DIR" log -1 --format='%s' 2>/dev/null || true)
    plugin_version=$(jq -r '.version // ""' "$PLUGIN_DIR/manifest.json" 2>/dev/null || true)
    jq -nc --arg branch "$branch" --arg remote "$remote" --arg remote_name "$remote_name" \
      --arg repo_dir "$REPO_DIR" --arg machine "$MACHINE" --arg plugin_version "$plugin_version" \
      --arg last_save "$last_save" --arg last_subject "$last_subject" \
      --argjson dirty "$dirty" --argjson untracked "$untracked" --argjson ahead "$ahead" --argjson behind "$behind" \
      --arg pending "$pending_groups" --argjson configs "$configs_json" --argjson secrets "$secrets_json" \
      --argjson settings "$settings_json" --argjson categories "$categories_json" \
      --argjson setting_groups "$groups_json" --argjson machines "$machines_json" \
      --arg profile "$(current_profile)" --argjson profiles "$profiles_json" \
      '{initialized:true, branch:$branch, remote:$remote, remote_name:$remote_name,
        repo_dir:$repo_dir, machine:$machine, plugin_version:$plugin_version,
        profile:$profile, profiles:$profiles,
        last_save:$last_save, last_subject:$last_subject,
        dirty:$dirty, untracked:$untracked, ahead:$ahead, behind:$behind, pending:$pending,
        configs:$configs, secrets:$secrets, settings:$settings,
        categories:$categories, setting_groups:$setting_groups, machines:$machines}'
  else
    echo "branch: $branch"
    echo "remote: ${remote:-<none>}"
    echo "dirty: $dirty pending:$pending_groups ahead/behind: $ahead/$behind"
    if (( dirty > 0 )); then git -C "$REPO_DIR" status --short 2>/dev/null | head -n 30; fi
  fi
}

# resolve_manifest_src <repo-relative-id> — the real file on this machine that
# a tracked id refers to ("hypr/input.lua" -> ~/.config/hypr/input.lua). Lives
# here rather than in the CLI so the CLI, the diff view and the panel all agree
# on one answer; auto-detected plugin configs resolve too.
resolve_manifest_src() {
  local id="$1" entry rel psrc prel _pname
  for entry in "${TRACKED[@]}" "${TRACKED_SECRETS[@]}"; do
    rel="${entry##*:}"
    [[ "$rel" == "$id" ]] && { printf '%s\n' "${entry%%:*}"; return 0; }
  done
  while IFS=$'\t' read -r psrc prel _pname; do
    [[ "$prel" == "$id" ]] && { printf '%s\n' "$psrc"; return 0; }
  done < <(discover_plugin_entries)
  return 1
}

# ─── Restore planning — derived from MANIFEST, never hand-listed ────────────
# The restore plan used to be a second, hand-written copy of the manifest inside
# the CLI. Adding a file to MANIFEST then silently did not restore it, which is
# the worst kind of backup bug: it looks like it worked right up until you need
# it. Everything below is computed from the one list.
#
# Mode is decided by where the file goes, not by what it is called:
# secrets are 600, anything under bin/ or a hooks/ directory has to stay
# executable, and everything else is 644.
restore_mode_for() {
  case "$1" in
    *.pub)                   echo 644 ;;
    ssh/id_*|env/*)          echo 600 ;;
    ssh/config)              echo 600 ;;
    bin/*|*/hooks/*|*.hook)  echo 755 ;;
    *)                       echo 644 ;;
  esac
}

# plan_for_category <category> — "repo-path|destination|mode" per line.
# Skips what the user switched off, what the repo does not have a copy of, and
# theme.name (a theme is replayed through omarchy-theme-set, not copied).
plan_for_category() {
  local want="$1" entry src rel cat repo_path mode
  for entry in "${TRACKED[@]}"; do
    src="${entry%%:*}"; rel="${entry##*:}"
    [[ "$rel" == "omarchy/theme.name" ]] && continue
    cat=$(category_for_rel "$rel")
    [[ "$cat" == "$want" ]] || continue
    is_excluded "$rel" && continue
    repo_path=$(repo_path_for "$rel")
    # A directory keeps its trailing slash all the way through the plan, which
    # is how the restore loop knows to walk a tree instead of copying a file.
    if is_dir_entry "$rel"; then
      [[ -d "${repo_path%/}" ]] || continue
      printf '%s|%s|%s\n' "${repo_path%/}/" "${src%/}/" "$(restore_mode_for "$rel")"
      continue
    fi
    [[ -f "$repo_path" ]] || continue
    printf '%s|%s|%s\n' "$repo_path" "$src" "$(restore_mode_for "$rel")"
  done
  [[ "$want" == "secrets" ]] || return 0
  for entry in "${TRACKED_SECRETS[@]}"; do
    src="${entry%%:*}"; rel="${entry##*:}"
    is_excluded "$rel" && continue
    repo_path="$SECRETS_DIR/$rel"
    [[ -f "$repo_path" ]] || continue
    printf '%s|%s|%s\n' "$repo_path" "$src" "$(restore_mode_for "$rel")"
  done
}

# What has to run for a restored category to actually take effect. Copying a
# file into ~/.config and calling it done is the difference between a backup
# tool and a restore tool.
apply_for_category() {
  case "$1" in
    shortcuts|hyprland) echo "hyprctl reload" ;;
    terminal)           echo "omarchy restart terminal" ;;
    system)             echo "systemctl daemon-reload" ;;
    *)                  echo "" ;;
  esac
}

# core_restore_file <rel> — put one tracked file back from the repo, with the
# same .bak.<epoch> every other write makes. The per-file counterpart of
# `reset`, which goes to Omarchy's default instead.
core_restore_file() {
  local rel="$1" src repo_path mode
  src=$(resolve_manifest_src "$rel") || { echo "unknown id: $rel" >&2; return 1; }
  repo_path=$(repo_copy_for_rel "$rel")
  if is_dir_entry "$rel"; then
    [[ -d "${repo_path%/}" ]] || { echo "$rel is not saved in your repo yet" >&2; return 1; }
    if tree_same "$repo_path" "$src"; then
      echo "$rel already matches the copy in your repo" >&2; return 0
    fi
    DRY=0 install_tree "$repo_path" "$src" "$(restore_mode_for "$rel")"
    local dapply; dapply=$(apply_for_category "$(category_for_rel "$rel")")
    [[ -n "$dapply" ]] && bash -c "$dapply" >/dev/null 2>&1 || true
    return 0
  fi
  [[ -f "$repo_path" ]] || { echo "$rel is not saved in your repo yet" >&2; return 1; }
  if [[ -f "$src" ]] && cmp -s "$repo_path" "$src"; then
    echo "$rel already matches the copy in your repo" >&2
    return 0
  fi
  mode=$(restore_mode_for "$rel")
  DRY=0 install_file "$repo_path" "$src" "$mode"
  local apply; apply=$(apply_for_category "$(category_for_rel "$rel")")
  [[ -n "$apply" ]] && bash -c "$apply" >/dev/null 2>&1 || true
  return 0
}

# Where a plugin came from, when nothing records it directly.
#
# Omarchy does not store an origin: `omarchy plugin list --json` has no such
# field and `omarchy plugin update` simply skips anything without a .git, so a
# plugin copied into place has no trail of its own. It still usually HAS a
# home — you just have to work it out. In order:
#
#   1. a git remote on the installed copy                        -> add
#   2. a remote on the local checkout that remote points at       -> add
#   3. `clonedFrom` in the manifest, i.e. an edited copy of a
#      built-in Omarchy plugin                                    -> clone
#   4. a checkout on this machine whose manifest carries the same
#      id — how a plugin you wrote yourself gets installed         -> add
#
# (4) only resolves on the machine that holds the checkout, which is exactly
# the machine recording the inventory. The URL it finds travels in the repo, so
# the other machine reads a URL and never needs the checkout.
PLUGIN_SOURCE_ROOTS=("$HOME/dev" "$HOME/src" "$HOME/code" "$HOME/projects" "$HOME/Projects" "$HOME/git" "$HOME/work")

resolve_plugin_origin() {
  local pdir="$1" pid="$2" pmf="$3" origin from m mid mroot
  origin=$(git -C "$pdir" remote get-url origin 2>/dev/null || true)

  # 1 & 2 — a remote, possibly via a local checkout it points at.
  if [[ -n "$origin" ]]; then
    if [[ "$origin" == /* && -d "$origin/.git" ]]; then
      # Resolve THROUGH the checkout: its own remote is where this really lives.
      # Accepted even when that is itself a path (a bare repo on a NAS, say) —
      # a path is at least a lead, and recording nothing makes the plugin
      # disappear silently. `doctor` is what says a path may not resolve
      # elsewhere; the inventory's job is to not lose the trail.
      from=$(git -C "$origin" remote get-url origin 2>/dev/null || true)
      [[ -n "$from" ]] && { printf '%s\tadd\n' "$from"; return 0; }
    elif [[ "$origin" != /* ]]; then
      printf '%s\tadd\n' "$origin"; return 0
    fi
  fi

  # 3 — a clone of a built-in. Restores the built-in, not the edits; the
  # inventory says so in its header rather than implying a full recovery.
  from=$(jq -r '.omarchy.clonedFrom // empty' "$pmf" 2>/dev/null || true)
  [[ -n "$from" ]] && { printf '%s\tclone\n' "$from"; return 0; }

  # 4 — a checkout of your own on this machine that builds this same plugin.
  for mroot in "${PLUGIN_SOURCE_ROOTS[@]}"; do
    [[ -d "$mroot" ]] || continue
    while IFS= read -r m; do
      [[ -n "$m" ]] || continue
      mid=$(jq -r '.id // empty' "$m" 2>/dev/null) || continue
      [[ "$mid" == "$pid" ]] || continue
      from=$(git -C "$(dirname "$m")" rev-parse --show-toplevel 2>/dev/null) || continue
      from=$(git -C "$from" remote get-url origin 2>/dev/null || true)
      [[ -n "$from" ]] && { printf '%s\tadd\n' "$from"; return 0; }
    done < <(find "$mroot" -maxdepth 4 -name manifest.json -not -path '*/node_modules/*' 2>/dev/null)
  done

  printf -- '-\t-\n'
}

# Plugins that exist ONLY on this machine: no git origin, so nothing can rebuild
# them anywhere. They are usually the user's own, written in place. Worth naming
# rather than skipping in silence, because shell.json lists them in the bar
# layout — restore it on a machine that lacks them and the bar comes back with
# holes in it.
local_only_plugins() {
  local pmf pid pdir porigin pmethod
  for pmf in "$HOME/.config/omarchy/plugins"/*/manifest.json; do
    [[ -f "$pmf" ]] || continue
    pdir="$(dirname "$pmf")"
    pid=$(jq -r '.id // empty' "$pmf" 2>/dev/null) || continue
    [[ -n "$pid" ]] || continue
    IFS=$'\t' read -r porigin pmethod < <(resolve_plugin_origin "$pdir" "$pid" "$pmf")
    [[ "$porigin" == "-" ]] && printf '%s\n' "$pid"
  done
}

# Plugins are not files to copy back — they are repos to reinstall. The saved
# inventory records each one's id and git origin so a second machine can be
# rebuilt with the command Omarchy itself provides.
missing_plugins() {
  local inv="$STATE_DIR/omarchy-plugins.txt" pid pver porigin pmethod
  [[ -f "$inv" ]] || { for inv in "$STATE_ROOT"/*/omarchy-plugins.txt; do [[ -f "$inv" ]] && break; done; }
  [[ -f "$inv" ]] || return 0
  while IFS=$'\t' read -r pid pver porigin pmethod; do
    [[ -n "$pid" && "$pid" != \#* ]] || continue
    [[ -d "$HOME/.config/omarchy/plugins/$pid" ]] && continue
    [[ "$porigin" == "-" || -z "$porigin" ]] && continue
    # An inventory written before the method column existed only ever meant add.
    [[ -z "$pmethod" || "$pmethod" == "-" ]] && pmethod=add
    printf '%s\t%s\t%s\n' "$pid" "$porigin" "$pmethod"
  done < "$inv"
}

# The same question about themes: which of the ones recorded in the repo is not
# on this machine, and where does it come from. Any machine's inventory will
# do — unlike a package list, a theme is not machine-specific, and the whole
# point is that the laptop can install what the desktop had.
missing_themes() {
  local inv tname torigin
  for inv in "$STATE_DIR/omarchy-themes.txt" "$STATE_ROOT"/*/omarchy-themes.txt; do
    [[ -f "$inv" ]] || continue
    while IFS=$'\t' read -r tname torigin; do
      [[ -n "$tname" && "$tname" != \#* ]] || continue
      [[ -d "$HOME/.config/omarchy/themes/$tname" ]] && continue
      [[ "$torigin" == "-" || -z "$torigin" ]] && continue
      printf '%s\t%s\n' "$tname" "$torigin"
    done < "$inv"
  done | sort -u
}

# A theme installed here that no origin can be worked out for — a hand-made one
# in ~/.config/omarchy/themes. Nothing reinstalls it, so `doctor` says so and
# the answer is to track that directory in .replicant-track.
local_only_themes() {
  local tdir tname
  for tdir in "$HOME/.config/omarchy/themes"/*/; do
    [[ -d "$tdir" ]] || continue
    tname=$(basename "${tdir%/}")
    git -C "${tdir%/}" remote get-url origin >/dev/null 2>&1 && continue
    is_tracked_path "${tdir%/}/" && continue
    printf '%s\n' "$tname"
  done
}

# core_diff <id> [default|repo|auto] — plain unified diff on stdout, for the
# panel to render inline. The panel used to shell out to a floating terminal
# for this; a diff is something you read, not something you interact with, so
# it belongs in the panel next to the file it describes.
core_diff() {
  local id="$1" against="${2:-auto}" src repo_copy def
  src=$(resolve_manifest_src "$id") || { echo "unknown id: $id"; return 1; }
  # A diff is rendered in the panel, on screen, possibly while sharing it. An
  # SSH private key or a file of API tokens has no business being drawn there,
  # so secrets report whether they changed and never what changed. Public keys
  # are fine.
  case "$id" in
    *.pub) ;;
    ssh/id_*|env/*)
      repo_copy=$(repo_copy_for_rel "$id")
      if [[ ! -f "$repo_copy" ]]; then echo "not saved in your repo yet"; return 0; fi
      if cmp -s "$src" "$repo_copy" 2>/dev/null; then
        echo "identical to the copy in your repo"
      else
        echo "This file differs from the copy in your repo."
        echo
        echo "Its contents are not shown: it holds a key or a token, and a diff"
        echo "on screen is a diff on any screen share or over any shoulder."
        echo "Open it yourself if you need to see it."
      fi
      return 0 ;;
  esac
  # A directory's "diff" is which files moved, not which bytes: a tree is too
  # big to render in the panel, and the useful answer is the file list.
  if is_dir_entry "$id"; then
    repo_copy=$(repo_copy_for_rel "$id")
    [[ -d "${src%/}" ]] || { echo "$src does not exist on this machine"; return 0; }
    [[ -d "${repo_copy%/}" ]] || { echo "not saved in the repo yet — press Save to GitHub to add it"; return 0; }
    if tree_same "$repo_copy" "$src"; then
      echo "identical to the copy in your repo — $(tree_count "$src") files"; return 0
    fi
    echo "# what is in your repo, next to what is on this machine"
    echo
    tree_diff_summary "$repo_copy" "$src"
    return 0
  fi
  [[ -f "$src" ]] || { echo "$src does not exist on this machine"; return 0; }
  repo_copy="$CONFIG_DIR/$id"
  [[ "$id" == ssh/* || "$id" == env/* ]] && repo_copy="$SECRETS_DIR/$id"
  def=$(default_for_src "$src" 2>/dev/null || true)

  if [[ "$against" == "auto" ]]; then
    if [[ -f "$repo_copy" ]] && ! cmp -s "$src" "$repo_copy"; then against="repo"; else against="default"; fi
  fi

  case "$against" in
    repo)
      [[ -f "$repo_copy" ]] || { echo "not saved in the repo yet — press Save to GitHub to add it"; return 0; }
      echo "# saved in your repo (-)  vs  this machine (+)"
      diff -u --label "repo" --label "this machine" "$repo_copy" "$src" || true
      ;;
    default)
      [[ -n "$def" ]] || { echo "no Omarchy default ships for this file — all of it is yours"; return 0; }
      if cmp -s "$src" "$def"; then echo "identical to Omarchy's default"; return 0; fi
      echo "# Omarchy default (-)  vs  this machine (+)"
      diff -u --label "omarchy default" --label "this machine" "$def" "$src" || true
      ;;
  esac
}

# core_log [n] — recent saves as JSON, for the panel's activity list.
core_log() {
  local n="${1:-8}"
  [[ -d "$REPO_DIR/.git" ]] || { echo '[]'; return 0; }
  git -C "$REPO_DIR" log -n "$n" --date=format:'%d %b %H:%M' \
      --pretty=format:'%H%x1f%ad%x1f%s%x1f%an' 2>/dev/null |
    jq -Rsc 'split("\n") | map(select(length > 0) | split("\u001f")
             | {sha: .[0][0:7], date: .[1], subject: .[2], author: .[3]})'
}

# Used by the omarchy-replicant CLI wrapper
if [[ "${1:-}" == "backup" ]]; then core_backup
elif [[ "${1:-}" == "status" ]]; then shift; core_status "$@"
elif [[ "${1:-}" == "diff" ]]; then core_diff "${2:-}" "${3:-auto}"
elif [[ "${1:-}" == "log" ]]; then core_log "${2:-8}"
elif [[ "${1:-}" == "shortcuts" ]]; then core_shortcuts
elif [[ "${1:-}" == "sync" ]]; then core_sync "${2:-}" "${3:-}"
elif [[ "${1:-}" == "revert" ]]; then core_revert "${2:-}" "${3:-default}"
elif [[ "${1:-}" == "restore-file" ]]; then core_restore_file "${2:-}"
elif [[ "${1:-}" == "scope" ]]; then core_scope "${2:-}" "${3:-}"
elif [[ "${1:-}" == "profile-set" ]]; then core_profile_set "${2:-}"
elif [[ "${1:-}" == "profile-get" ]]; then current_profile
elif [[ "${1:-}" == "profile-list" ]]; then list_profiles
elif [[ "${1:-}" == "local-only-plugins" ]]; then local_only_plugins
elif [[ "${1:-}" == "local-only-themes" ]]; then local_only_themes
elif [[ "${1:-}" == "track" ]]; then shift; core_track "$@"
elif [[ "${1:-}" == "untrack" ]]; then core_untrack "${2:-}"
elif [[ "${1:-}" == "suggest" ]]; then core_suggest "${2:-}"
fi
