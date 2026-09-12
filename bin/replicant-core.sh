#!/bin/bash
# replicant-core.sh: the logic of the omarchy-replicant plugin. It holds the
# tracked lists (MANIFEST, SECRETS_MANIFEST), install with backup, the secret
# scan, and backup, savegame and restore. The CLI and the panel call it.
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

# Which tracked entries the last pull brought a newer copy of. Machine-local on
# purpose: it is a fact about what THIS machine has not caught up with yet, not
# about the setup, so it has no business travelling in the repo.
#
# It exists because "does the file on this machine differ from the copy in the
# repo" cannot tell you WHICH way the difference points, and the two answers ask
# for opposite buttons. Before this, pulling a change the laptop had made left
# the desktop showing the calm red "unsaved" badge — press Save and the laptop's
# work is quietly committed away. The direction is only knowable at the moment
# the commits arrive, so that is where it is written down.
INCOMING_FILE="$REPLICANT_HOME/incoming"

# Overridable so the tests can exercise the reader and the writer without a
# root-owned file; in normal use it is exactly where logind looks.
LOGIND_DROPIN="${REPLICANT_LOGIND_DROPIN:-/etc/systemd/logind.conf.d/99-lid.conf}"

# plural <n> <singular> [plural] — "1 file", "4 files". Every count this tool
# prints used to read "4 file(s)", including in the panel, where it appeared
# eleven times on one screen. Nothing about the parenthesis was ever needed:
# the number is right there.
plural() {
  local n="$1" one="$2" many="${3:-$2s}"
  if [[ "$n" == 1 ]]; then printf '%s %s\n' "$n" "$one"; else printf '%s %s\n' "$n" "$many"; fi
}

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
  # Written by Omarchy's own commands and by the settings plugins, not only by
  # hand: `omarchy font set` makes fonts.conf the source of truth for the font,
  # and OmaSettings edits tmux and Herdr in place. Omarchy ships the last two.
  "$HOME/.config/fontconfig/fonts.conf:fontconfig/fonts.conf"
  "$HOME/.config/tmux/tmux.conf:tmux/tmux.conf"
  "$HOME/.config/herdr/config.toml:herdr/config.toml"
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
# a fresh install. `~/Projects/mise.toml` is deliberately absent — it is a project
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
  "$HOME/Projects/portfolio/.env:env/portfolio.env"
  "$HOME/Projects/lazytripz/backend/.env:env/lazytrip-backend.env"
)

# Entries that an earlier release shipped and this one does not, because they
# are not what every Omarchy machine has. If the repo holds a copy, the entry
# moves into the user's own list once. Without that step, the prune pass would
# delete the copy on the next save. A machine that only has the file does not
# start to track it.
RETIRED_SHIPPED=(
  "$HOME/.claude/.mcp.json:claude/mcp.json"
)

migrate_retired_shipped() {
  [[ -f "$USER_TRACK_FILE" ]] || return 0
  local entry src rel moved=0
  for entry in "${RETIRED_SHIPPED[@]}"; do
    src="${entry%%:*}"; rel="${entry##*:}"
    is_user_entry "$rel" && continue
    [[ -e "$(repo_path_for "$rel")" ]] || continue
    track_line_for "$src" "$rel" config >> "$USER_TRACK_FILE"
    moved=$((moved + 1))
  done
  (( moved )) || return 0
  load_user_manifest
  echo "  · $(plural "$moved" entry entries) that the plugin no longer ships moved into your .replicant-track" >&2
}

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
#   secret ~/Projects/app/.env                   stored 600, contents never rendered
#
USER_TRACK_FILE="$REPO_DIR/.replicant-track"

# ─── WHICH VERSION LAST WROTE THIS REPO ─────────────────────────────────────
# Two machines share one repo and they are not upgraded on the same day. The
# prune pass deletes whatever is not in the running version's list — so the
# machine still on the old release silently deletes every file the upgraded one
# tracks, on its next save. This is not hypothetical: it happened here, and the
# reproduction is in tests/test-core.sh.
#
# So the repo records the highest version that has ever written it, and a client
# older than that REFUSES TO PRUNE. It still copies its own files in; it just
# does not get to decide that somebody else's are stale.
#
# This can only protect against versions that know about the file, which means
# 0.7.0 onwards. There is no way to teach an already-released client to check —
# the honest answer for a 0.6 machine is to upgrade it, and doctor says so.
REPO_VERSION_FILE="$REPO_DIR/.replicant-version"

running_version() { jq -r '.version // "0"' "$PLUGIN_DIR/manifest.json" 2>/dev/null || echo 0; }
repo_written_by() { [[ -f "$REPO_VERSION_FILE" ]] && head -n1 "$REPO_VERSION_FILE" | tr -d '[:space:]' || echo ""; }

# version_lt <a> <b> — true when a is strictly older than b.
version_lt() {
  [[ "$1" == "$2" ]] && return 1
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$1" ]]
}

# The recorded version only ever goes up: an older client saving must not lower
# it, or the next save from that client would prune after all.
record_repo_version() {
  local running seen
  running=$(running_version); seen=$(repo_written_by)
  [[ -n "$running" && "$running" != "0" ]] || return 0
  if [[ -z "$seen" ]] || version_lt "$seen" "$running"; then
    printf '%s\n' "$running" > "$REPO_VERSION_FILE"
  fi
}

# May this client delete files it does not recognise?
may_prune() {
  local running seen
  running=$(running_version); seen=$(repo_written_by)
  [[ -n "$seen" && -n "$running" && "$running" != "0" ]] || return 0
  version_lt "$running" "$seen" && return 1
  return 0
}
USER_MANIFEST=()
USER_SECRETS=()
# Entries found rather than listed: other plugins' configs and the Hyprland
# modules hyprland.lua loads. They join TRACKED like every other entry, so the
# copy, prune, restore and badge passes cannot treat them differently. See
# load_auto_manifest.
AUTO_MANIFEST=()
# -g on every top-level associative array. The CLI sources this file inside a
# function, and a plain `declare` there makes a local of that function: the
# array was gone as soon as the function returned.
declare -gA AUTO_LABEL=()

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
  TRACKED=("${MANIFEST[@]}" ${USER_MANIFEST[@]+"${USER_MANIFEST[@]}"} ${AUTO_MANIFEST[@]+"${AUTO_MANIFEST[@]}"})
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
  "shortcuts|󰌌|Shortcuts|Your keybinding overrides, on top of Omarchy's defaults|Copied back, then hyprctl reload"
  "appearance|󰏘|Appearance|Theme, look & feel, fonts, interface density and branding|Theme re-applied with omarchy theme set"
  "desktop|󰍹|Desktop & bar|The Omarchy shell: bar layout, widgets, menu and idle|Written to shell.json / shell.toml, which the shell watches live"
  "hyprland|󰖯|Hyprland|Input, monitors, autostart, lock screen and night light|Copied back, then hyprctl reload and a config-error check"
  "terminal|󰆍|Terminal & shell|Alacritty, foot, tmux, bashrc and which terminal opens|Copied back, then omarchy restart terminal"
  "development|󰅴|Development|git, editors, Claude and opencode, mise, VS Code|Copied back; nothing needs restarting"
  "secrets|󰌆|Secrets & keys|SSH keys, tokens and .env files — private, mode 600|Copied back as mode 600; contents are never printed"
  "plugins|󰐱|Plugins|Plugin settings, plus every plugin's id and git origin|Plugin settings copied back; third-party plugins are installed only on request"
  "scripts|󰈙|Scripts|Your helper scripts under ~/.local/bin and Omarchy hooks|Copied back with the executable bit kept"
  "system|󰋊|System|systemd drop-ins for lid and sleep|Needs root: one file asks for it, a full restore prints sudo"
  "other|󰈔|Other|Anything else you asked Replicant to track|Copied back as-is"
)
CATEGORY_ORDER=(shortcuts appearance desktop hyprland terminal development secrets plugins scripts system other)

# `fields`, not `f`. Bash scopes dynamically, so a local named `f` here is
# visible inside anything this calls — and `f` means "the file being examined"
# in three other functions in this file. That collision is what made
# suggest_skip_reason work by accident for four releases.
category_field() { local -a fields; IFS='|' read -ra fields <<<"$1"; printf '%s' "${fields[$(($2 - 1))]:-}"; }
find_category() {
  local id="$1" entry
  # A prefix match, as in find_setting: no fork per line.
  for entry in "${CATEGORIES[@]}"; do
    [[ "${entry%%|*}" == "$id" ]] && { printf '%s\n' "$entry"; return 0; }
  done
  return 1
}

# category_for_rel <repo-relative-id> — one place deciding where a tracked file
# shows up. It used to live inline in build_configs_json, which meant the CLI
# and the panel could disagree about what "appearance" meant.
category_for_rel() {
  case "$1" in
    hypr/bindings.lua)                                 echo shortcuts ;;
    hypr/looknfeel.lua|omarchy/theme.name|omarchy/shell.toml|branding/*|fontconfig/*|omarchy/themed/*) echo appearance ;;
    omarchy/shell.json|omarchy/extensions/*)           echo desktop ;;
    hypr/*)                                            echo hyprland ;;
    alacritty/*|foot/*|kitty/*|ghostty/*|xdg-terminals.list|home/*) echo terminal ;;
    # nvim/ is not listed separately: `nvim/*` already matches it, since * matches
    # the empty string. Having both said the author was unsure which one worked.
    git/*|vscode/*|mise/*|claude/*|opencode/*|dev/*|nvim/*|omarchy/defaults/*) echo development ;;
    ssh/*|env/*)                                       echo secrets ;;
    plugins/*)                                         echo plugins ;;
    bin/*|omarchy/hooks/*|omarchy-audit-ignore)        echo scripts ;;
    etc/*|uwsm/*|systemd/*)                            echo system ;;
    mimeapps.list)                                     echo desktop ;;
    starship.toml|btop/*|lazygit/*|tmux/*|herdr/*)     echo terminal ;;
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

# ensure_profile_recorded — write down which profile THIS machine is in, once,
# if nobody has said.
#
# guess_profile asks the chassis, so every laptop guesses `laptop`. Two laptops
# on one repo therefore both wrote profiles/laptop/config/hypr/monitors.lua and
# the second save silently overwrote the first machine's only backup of its
# screen layout — reproduced, and it eats the one file that is profile-scoped
# out of the box. This is the bug state/<hostname>/ was introduced to fix, one
# level up: profiles are named by ROLE, and roles collide.
#
# Recording the guess makes the collision visible to the next machine, which
# then falls back to its hostname — unique by construction. It only ever ASSIGNS
# and never reassigns, so an existing machine keeps the profile it already has
# and nothing moves in a repo that is already working.
ensure_profile_recorded() {
  [[ -d "$REPO_DIR/.git" ]] || return 0
  [[ -n "${REPLICANT_PROFILE:-}" ]] && return 0
  profile_for_machine "$MACHINE" >/dev/null 2>&1 && return 0
  local want taken=0 line k v d
  want=$(guess_profile)

  # Claimed by name: another machine is recorded under this role.
  while IFS= read -r line; do
    k="${line%%=*}"; v="${line#*=}"
    k="${k//[[:space:]]/}"; v="${v//[[:space:]]/}"
    [[ -z "$k" ]] && continue
    [[ "$v" == "$want" && "$k" != "$MACHINE" ]] && { taken=1; break; }
  done < <(read_profile_map)

  # Claimed by occupancy: the tree exists but nobody is recorded under it —
  # which is every repo written before this check existed. The tree is only
  # SOMEBODY ELSE'S if somebody else has actually saved here; on a repo with one
  # machine it is that machine's own, and taking a different name would orphan
  # its backup instead of protecting it.
  if (( ! taken )) && [[ -d "$REPO_DIR/profiles/$want" ]]; then
    for d in "$STATE_ROOT"/*/; do
      [[ -d "$d" ]] || continue
      [[ "$(basename "$d")" == "$MACHINE" ]] && continue
      taken=1; break
    done
  fi

  (( taken )) && want="$MACHINE"
  core_profile_set "$want" >/dev/null 2>&1 || true
  return 0
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

# The scope list is read at least three times per row — once directly and twice
# more through repo_path_for — and it used to spawn a sed for every one of them.
# On fifty rows that is a hundred and fifty processes to answer a question about
# a file of a dozen lines. It is read once per process instead.
SCOPES_CACHE=""; SCOPES_CACHED=0
invalidate_scopes_cache() { SCOPES_CACHED=0; SCOPES_CACHE=""; }
read_scopes() {
  if (( ! SCOPES_CACHED )); then
    SCOPES_CACHED=1
    [[ -f "$SCOPE_FILE" ]] && SCOPES_CACHE=$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$SCOPE_FILE" 2>/dev/null || true)
  fi
  [[ -n "$SCOPES_CACHE" ]] && printf '%s\n' "$SCOPES_CACHE"
  return 0
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

# print_lines <line>... — one line each, and nothing at all for no lines. The
# writers ended in `(( n )) && printf`, so with nothing to keep a writer returned
# 1, and set -e ended the first layout on a new machine with no message.
print_lines() { (( $# )) || return 0; printf '%s\n' "$@"; }

write_scope_file() {
  local -a keep=("$@")
  {
    echo "# What Replicant does with each tracked file, one per line:"
    echo "#   <path> = shared    one copy, every machine saves and restores it"
    echo "#   <path> = profile   a copy per profile, under profiles/<profile>/config/"
    echo "#   <path> = off       never saved from or restored onto any machine"
    echo "# A path that is not listed is shared. Written by the panel; safe to edit."
    print_lines "${keep[@]}"
  } > "$SCOPE_FILE"
  invalidate_scopes_cache
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

# move_repo_copy <from> <to> — carry the copy the repo holds to its new path.
#
# The guard here used to be `-f`, so a tracked DIRECTORY was never moved: the
# tree stayed at the old path while repo_path_for pointed at the new one, and
# until the next save the panel called a saved tree unsaved and revert-to-repo
# could not find it. Both sides are inside the repo, which is the only reason
# clearing the destination first is safe — and it is checked, not assumed.
move_repo_copy() {
  local from="${1%/}" to="${2%/}"
  [[ -e "$from" ]] || return 0
  case "$to/" in "$REPO_DIR"/*) ;; *) echo "refusing to move outside the repo: $to" >&2; return 1 ;; esac
  mkdir -p "$(dirname "$to")"
  rm -rf -- "$to"
  mv -f -- "$from" "$to"
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
      move_repo_copy "$from" "$to" ;;
    profile:shared)
      from="$REPO_DIR/profiles/$(current_profile)/config/$rel"; to="$CONFIG_DIR/$rel"
      move_repo_copy "$from" "$to" ;;
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
    echo "#   secret ~/Projects/app/.env                   stored 600, never rendered"
    echo "#"
    echo "# This file lives in the repo, so both your machines honour it."
    echo "# Written by the panel and by 'omarchy-replicant track'; safe to edit."
    print_lines "${keep[@]}"
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

  local entry esrc
  for entry in "${TRACKED[@]}" "${TRACKED_SECRETS[@]}"; do
    esrc="${entry%%:*}"
    if [[ "$esrc" == "$path" || "${entry##*:}" == "$rel" ]]; then
      echo "track: already tracked as '${entry##*:}'" >&2; return 0
    fi
    # A file inside a tracked directory is already tracked BY it. Accepting it
    # again gave two entries the same path in the repo, so the panel drew the
    # row twice and untracking the file would have deleted the copy the
    # directory still owns.
    if [[ "$esrc" == */ && "$path" == "$esrc"* ]]; then
      echo "track: already covered by the tracked directory '${entry##*:}'" >&2; return 0
    fi
    # And the other way round: a directory that swallows something already
    # listed would take over its copy without anyone saying so.
    if [[ "$path" == */ && "$esrc" == "$path"* ]]; then
      echo "track: '$rel' would swallow '${entry##*:}', which is tracked on its own" >&2
      echo "       untrack that first, or track a narrower directory" >&2
      return 1
    fi
  done

  # Tracking a big tree is a foot-gun with a quiet failure mode: it works, and
  # the repo grows by a hundred megabytes nobody meant to push. Say the number
  # rather than guessing an acceptable one.
  if [[ "$path" == */ ]]; then
    local n; n=$(tree_count "$path")
    if (( n > 400 )); then
      echo "track: ${path/#$HOME/\~} holds $n files — that is a lot to put in a git repo." >&2
      echo "       If it is a git clone (a theme, a plugin), it is already recorded by URL." >&2
      echo "       Track a narrower directory, or the handful of files you actually edit." >&2
      return 1
    fi
    (( n > 100 )) && echo "track: note — ${path/#$HOME/\~} holds $n files" >&2
  fi

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
SUGGEST_EXTENSIONS="conf toml ini yml yaml lua json jsonc rc list css scss sh bash fish zsh service timer socket desktop kdl nix editorconfig theme vim tpl"

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
  # TWO `local` statements, and that is not style. Bash expands every word on a
  # `local` line BEFORE performing any of its assignments, so in
  # `local f="$1" base="${f##*/}"` the `$f` that `base` reads is NOT the one
  # being assigned on the same line — it is whatever `f` meant in the caller.
  #
  # This worked, and only by accident: bash scopes dynamically, the sole caller
  # is core_suggest, and core_suggest's loop variable is also called `f` and
  # holds the same path. Rename it there and every test in this function goes
  # quietly dead — symlinks, .bak files, oversized files, binaries, application
  # state, package-manager files, runtime state, mise shims, plugin-installed
  # scripts and files identical to Omarchy's default would all start being
  # offered, which is the opposite of what the README promises, with no error
  # anywhere. Called on its own under `set -u` it aborts outright on this line.
  #
  # Found by shellcheck (SC2318/SC2178) the first time it was ever installed.
  local f="$1"
  local base="${f##*/}" ext="${f##*.}"
  [[ -L "$f" ]]                             && { echo "a symlink"; return 0; }
  [[ "$base" == *.bak.* || "$base" == *~ ]] && { echo "a backup"; return 0; }
  [[ $(stat -c%s "$f" 2>/dev/null || echo 0) -gt $SUGGEST_MAX_BYTES ]] && { echo "too big to be hand-written"; return 0; }
  grep -Iq . "$f" 2>/dev/null || { echo "not a text file"; return 0; }
  is_app_state_dir "$(dirname "$f")" && { echo "an application's own state"; return 0; }
  case "$base" in
    package.json|package-lock.json|yarn.lock|pnpm-lock.yaml|composer.lock)
      { echo "a package manager's file"; return 0; } ;;
    *session*|*state*|*.log|*.pid|*.sock*|*.db|*.lock)
      { echo "runtime state, not config"; return 0; } ;;
  esac
  # A script has no extension to go by, so it is judged by living where you put
  # scripts: ~/.local/bin, or an Omarchy hook directory. Everything else must
  # look like config.
  if [[ "$f" != "$HOME/.local/bin/"* && "$f" != "$HOME/.config/omarchy/hooks/"* ]]; then
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

# ─── incoming: what another machine changed and this one has not caught up ──
# Read through one assoc array, filled once. Every row in the panel asks, so a
# per-row re-read of the file is fifty reads of the same six lines.
declare -gA INCOMING=()
INCOMING_LOADED=0
read_incoming() {
  (( INCOMING_LOADED )) && return 0
  INCOMING_LOADED=1
  INCOMING=()
  [[ -f "$INCOMING_FILE" ]] || return 0
  local line
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    INCOMING["$line"]=1
  done < "$INCOMING_FILE"
  return 0
}

# is_incoming_rel <rel> — 0 when the last pull brought a newer copy of this
# entry. The CALLER still has to check the file actually differs: an entry that
# has since been restored, or deliberately saved over, matches again and must
# stop claiming anything. That is the same self-healing rule the unsaved badge
# follows, and it is why no pass has to remember to clear this flag.
is_incoming_rel() {
  read_incoming
  [[ -n "${INCOMING[$1]:-}" ]]
}

# record_incoming <rel>... — replace the list with exactly these entries.
# Called by `pull`, which is the one moment the direction of a difference is
# known for certain.
record_incoming() {
  mkdir -p "$REPLICANT_HOME" 2>/dev/null || return 0
  if (( $# == 0 )); then rm -f "$INCOMING_FILE" 2>/dev/null || true
  else printf '%s\n' "$@" | sort -u > "$INCOMING_FILE"
  fi
  INCOMING_LOADED=0
  return 0
}

# entry_differs <src> <repo-copy> <is-dir> — 0 when what is on this machine is
# not what the repo holds. This is the CONTENT half of "unsaved", factored out
# because two callers need it: the row payload the panel draws, and the cheap
# count the bar icon polls. A second copy of this comparison is exactly how a
# badge and a bar icon come to disagree about the same file.
#
# A file that is not on this machine does NOT differ — that is "missing", a
# different row and a different answer.
entry_differs() {
  local src="$1" repo_path="$2" is_dir="${3:-false}"
  if [[ "$is_dir" == true ]]; then
    [[ -d "${src%/}" ]] || return 1
    tree_same "$src" "$repo_path" && return 1
    return 0
  fi
  [[ -f "$src" ]] || return 1
  [[ -f "$repo_path" ]] || return 0
  cmp -s "$src" "$repo_path" 2>/dev/null && return 1
  return 0
}

# count_changes — prints "<unsaved> <incoming>" over every tracked entry.
#
# The bar icon used to read repoState.dirty, which counts what git sees in the
# REPO working tree — files core_backup has already copied in. Edit a config and
# never save it and the icon sat at the calm "in sync" hexagon all day, which is
# the one thing this plugin exists to tell you. The panel was fixed for this in
# 0.6.1 and the bar was not.
#
# It answers with content only. The git half ("copied in, not committed") is
# already in the brief payload as `dirty`, and the icon ORs the two. Fifty cmps
# take a few milliseconds; building the full row payload for the same answer
# took 1.4 s of CPU once a minute.
count_changes() {
  local entry src rel repo_path is_dir n_unsaved=0 n_incoming=0
  read_scopes >/dev/null
  read_incoming
  for entry in "${TRACKED[@]}"; do
    src="${entry%%:*}"; rel="${entry##*:}"
    [[ "$(scope_for "$rel")" == "off" ]] && continue
    is_dir=false; is_dir_entry "$rel" && is_dir=true
    repo_path=$(repo_path_for "$rel")
    entry_differs "$src" "$repo_path" "$is_dir" || continue
    # Exclusive, exactly as the badge precedence is: a file the repo has a newer
    # copy of is asking for Restore, not for Save, and counting it in both
    # totals put the same file behind two contradictory buttons.
    if [[ -n "${INCOMING[$rel]:-}" ]]; then n_incoming=$(( n_incoming + 1 ))
    else n_unsaved=$(( n_unsaved + 1 )); fi
  done
  for entry in "${TRACKED_SECRETS[@]}"; do
    src="${entry%%:*}"; rel="${entry##*:}"
    is_excluded "$rel" && continue
    entry_differs "$src" "$SECRETS_DIR/$rel" false || continue
    if [[ -n "${INCOMING[$rel]:-}" ]]; then n_incoming=$(( n_incoming + 1 ))
    else n_unsaved=$(( n_unsaved + 1 )); fi
  done
  printf '%s %s\n' "$n_unsaved" "$n_incoming"
}

# ─── the safety net, made visible ───────────────────────────────────────────
# Every write to the real machine leaves the previous version beside it as
# <file>.bak.<epoch>. That net existed from the first release and nothing could
# see it: `purge` was the only code that knew how to find one, and purge deletes
# the whole plugin. Eleven of them were sitting on this machine, unnamed and
# unreachable, which makes them a mess rather than a net — a backup you cannot
# find is not a backup.
#
# list_backups [rel] — one line per backup, newest first:
#     <rel> \t <live path> \t <backup path> \t <epoch> \t <same|differs|gone>
#
# The trailing slash comes off FIRST. install_tree backs a directory up as
# `<dir>.bak.<epoch>` beside it, so globbing "$src".bak.* on a tracked directory
# looks INSIDE the directory and finds nothing — the bug hard rule 8 was written
# for, and the reason this lives in one function instead of two copies.
list_backups() {
  local only="${1:-}" entry src rel b epoch state
  for entry in "${TRACKED[@]}" "${TRACKED_SECRETS[@]}"; do
    rel="${entry##*:}"
    [[ -n "$only" && "$rel" != "$only" ]] && continue
    src="${entry%%:*}"; src="${src%/}"
    while IFS= read -r b; do
      [[ -n "$b" ]] || continue
      epoch="${b##*.bak.}"
      [[ "$epoch" =~ ^[0-9]+$ ]] || continue
      if [[ ! -e "$src" ]]; then state=gone
      elif [[ -d "$b" ]]; then
        tree_same "$src" "$b" && state=same || state=differs
      elif cmp -s "$src" "$b" 2>/dev/null; then state=same
      else state=differs
      fi
      printf '%s\t%s\t%s\t%s\t%s\n' "$rel" "$src" "$b" "$epoch" "$state"
    done < <(ls -1d "$src".bak.* 2>/dev/null || true)
  done | sort -t$'\t' -k4,4nr
}

# build_pending_reinstalls_json — third-party themes/plugins the inventory
# knows about but this machine does not have. `restore` never installs these
# on its own (restore_themes/restore_plugins in the CLI only report them) —
# this is the list the panel renders as its own row, one Install button per
# item, so fetching someone else's current code is always a decision made in
# the moment, not a side effect of "bring my stuff back".
build_pending_reinstalls_json() {
  # One TSV stream for both kinds, one jq — the same shape build_backups_json
  # below uses, instead of one jq process per pending item.
  {
    while IFS=$'\t' read -r tname torigin; do
      [[ -n "$tname" ]] || continue
      printf 'theme\t%s\t%s\t\n' "$tname" "$torigin"
    done < <(missing_themes)
    while IFS=$'\t' read -r pid porigin pmethod; do
      [[ -n "$pid" ]] || continue
      printf 'plugin\t%s\t%s\t%s\n' "$pid" "$porigin" "$pmethod"
    done < <(missing_plugins)
  } | jq -Rsc '
    split("\n") | map(select(length > 0) | split("\t") | {
      kind: .[0], id: .[1], origin: .[2], method: (.[3] // "")
    })'
}

# build_backups_json — what the panel renders. One entry per backup, carrying
# the id it belongs to so the panel can put an Undo next to the right name.
build_backups_json() {
  list_backups | jq -Rsc '
    split("\n") | map(select(length > 0) | split("\t") | {
      id: .[0], src: .[1], path: .[2],
      epoch: (.[3]|tonumber? // 0), state: .[4],
      name: (.[2] | split("/") | last)
    })'
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
        */omarchy/hooks/*) reason="an Omarchy hook you added" ;;
        */omarchy/themed/*) reason="a theme template you changed" ;;
      esac
      kind=$(suggest_kind "$f")
      [[ "$kind" == secret ]] && reason="holds a credential — track it as a secret"
      printf '%s\t%s\t%s\t%s\n' "$f" "$(derive_rel "$f")" "$reason" "$kind"
    done < <({
      find "$HOME/.config" -maxdepth 2 -type f 2>/dev/null
      find "$HOME/.config/systemd/user" -maxdepth 1 -type f 2>/dev/null
      find "$HOME/.local/bin" -maxdepth 1 -type f -executable 2>/dev/null
      # Omarchy's two extension points, both deeper than the scan above. It
      # ships a .sample in each, which is Omarchy's file and not the user's.
      find "$HOME/.config/omarchy/hooks" -mindepth 2 -maxdepth 2 -type f ! -name '*.sample' 2>/dev/null
      find "$HOME/.config/omarchy/themed" -maxdepth 1 -type f ! -name '*.sample' 2>/dev/null
    } | sort -u)
  # Credentials first — "secret" sorts after "config", hence -r — and stably,
  # so everything else keeps path order. The list is long and, in the panel,
  # lives at the bottom of a longer one: a row buried at position fourteen is a
  # row nobody reads, and this is the one whose cost of being missed is an OAuth
  # token sitting world-readable in a git checkout.
  } | sort -s -t$'\t' -k4,4r | if (( as_json )); then
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
  # A config symlinked into a dotfiles repo is still that config, so the write
  # goes through the link. `install` onto the name itself replaces the link with
  # a plain file, and the dotfiles repo silently stops seeing the change. The
  # backup is a copy of what the link points at, kept next to the tracked name,
  # where list_backups and undo look.
  local target=$dst
  if [[ -L $dst ]]; then
    target=$(readlink -f -- "$dst" 2>/dev/null) && [[ -f $target ]] || target=$dst
  fi
  if [[ -f $target ]] && cmp -s "$src" "$target"; then
    run chmod "$mode" "$target"
    ok "$short_path (already matches, mode $mode)"
    return
  fi
  if [[ -e $dst ]]; then
    run cp -a -- "$target" "$dst.bak.$(date +%s)"
    skip "$short_path — previous version saved as .bak.<epoch>"
  fi
  run install -D -m "$mode" "$src" "$target"
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
#
# Other tools' safety copies are skipped too. OmaSettings leaves
# `<file>.omasettings.bak` beside a file it edits for the first time (Neovim's
# options.lua, inside the tracked nvim/ tree), and `omarchy refresh config`
# leaves `<file>.bak.<epoch>`. Neither is configuration.
TREE_EXCLUDES=(".git" "node_modules" "__pycache__" ".cache" "*.omasettings.bak" "*.bak.[0-9]*")

# -H: a tracked directory that is itself a symlink into a dotfiles repo is still
# that directory. Without it find lists nothing under the link, and the
# two-way mirror then empties the repo's copy on the next save.
tree_find() {
  local root="${1%/}" e
  local -a prune=()
  for e in "${TREE_EXCLUDES[@]}"; do prune+=(-name "$e" -o); done
  find -H "$root" \( "${prune[@]}" -false \) -prune -o -type f -print 2>/dev/null
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
  # Resolved first: `cp -a` of a symlinked directory copies the link, and a
  # backup that points at the tree about to be overwritten keeps nothing.
  if [[ -e $dst ]]; then
    run cp -a -- "$(readlink -f -- "$dst")" "$dst.bak.$(date +%s)"
    skip "$short_path/ — previous version saved as .bak.<epoch>"
  fi
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    run install -D -m "$mode" "$src/$f" "$dst/$f"
  done < <(tree_files "$src")
  ok "$short_path/ ($(tree_count "$src") files, $mode)"
}

# The pre-commit hook of the data repo. It fails closed: if it cannot find the
# scanner, it blocks the commit. It used to exit 0 in that case, and the
# scanner is the last check between a token and GitHub.
precommit_hook_text() {
  cat <<'HOOK'
#!/bin/bash
set -uo pipefail
REPO=$(git rev-parse --show-toplevel)
files=$(git diff --cached --name-only --diff-filter=ACM)
[[ -z $files ]] && exit 0
SCAN="$REPO/bin/scan-secrets.sh"
[[ -x "$SCAN" ]] || SCAN="$HOME/.config/omarchy/plugins/io.github.tymurbogach.omarchy-replicant/bin/scan-secrets.sh"
if [[ ! -x "$SCAN" ]]; then
  echo "COMMIT BLOCKED: the secret scanner is missing. Run 'omarchy-replicant backup' to put it back." >&2
  exit 1
fi
fail=0
while IFS= read -r file; do
  [[ -f $file ]] || continue
  [[ $file == secrets/* ]] && continue
  git show ":$file" 2>/dev/null | "$SCAN" --stdin "$file" || fail=1
done <<<"$files"
if (( fail )); then
  echo "COMMIT BLOCKED: possible credential in config/state/templates." >&2
  exit 1
fi
HOOK
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
  migrate_retired_shipped
  record_repo_version
  mkdir -p "$REPO_DIR/profiles/$(current_profile)/config" 2>/dev/null || true
  install -d -m 700 "$SECRETS_DIR" 2>/dev/null || mkdir -p "$SECRETS_DIR"
  # The hook is kept in step with the plugin, like the scanner below. It was
  # written once, so a repo made by an old release kept that hook forever.
  mkdir -p "$GITHOOKS_DIR"
  if ! cmp -s <(precommit_hook_text) "$GITHOOKS_DIR/pre-commit" 2>/dev/null; then
    precommit_hook_text > "$GITHOOKS_DIR/pre-commit"
  fi
  chmod +x "$GITHOOKS_DIR/pre-commit"
  # scan-secrets bin — kept in step with the plugin, not just seeded once.
  #
  # The repo's pre-commit hook runs THIS copy, so a repo created in June was
  # still checking for the four credential shapes the plugin knew about then.
  # Teaching the plugin a new one has to reach the repos that already exist, or
  # the improvement only ever protects people who install for the first time.
  # It is plugin-provided infrastructure, not the user's data, and every
  # version of it is in git — so replacing it is safe and is the point.
  if [[ -f "$PLUGIN_DIR/bin/scan-secrets.sh" ]]; then
    if ! cmp -s "$PLUGIN_DIR/bin/scan-secrets.sh" "$REPO_DIR/bin/scan-secrets.sh" 2>/dev/null; then
      mkdir -p "$REPO_DIR/bin"
      [[ -f "$REPO_DIR/bin/scan-secrets.sh" ]] &&
        echo "  · updating the repo's secret scanner to this version's" >&2
      cp -a "$PLUGIN_DIR/bin/scan-secrets.sh" "$REPO_DIR/bin/scan-secrets.sh"
    fi
  fi
  chmod +x "$REPO_DIR/bin/scan-secrets.sh" 2>/dev/null || true
  # .gitignore — savegame style (state/ is generated, .bak.* ignored, secrets/ tracked)
  if [[ ! -f "$REPO_DIR/.gitignore" ]]; then
    cat >"$REPO_DIR/.gitignore" <<'GI'
# — replicant savegame —
*.bak.*
*.bak
**/.cache/
**/Cache/
GI
  fi
  # git init if needed
  if [[ ! -d "$REPO_DIR/.git" ]]; then
    git -C "$REPO_DIR" init -q -b main
    git -C "$REPO_DIR" config init.defaultBranch main 2>/dev/null || true
    # $USER is not set everywhere (a container, a systemd unit). Under set -u its
    # absence wrote an empty identity, and every commit after it failed. Ask the
    # system instead.
    local who; who=$(id -un)
    git -C "$REPO_DIR" config user.name  "${GIT_AUTHOR_NAME:-$(git config --global user.name 2>/dev/null || echo "$who")}"
    git -C "$REPO_DIR" config user.email "${GIT_AUTHOR_EMAIL:-$(git config --global user.email 2>/dev/null || echo "$who@omarchy-replicant")}"
    git -C "$REPO_DIR" config core.hooksPath .githooks 2>/dev/null || true
  else
    git -C "$REPO_DIR" config core.hooksPath .githooks 2>/dev/null || true
  fi
}

core_backup() {
  # Bash scopes dynamically, and the CLI sources this file, so a name assigned
  # here without `local` leaked into the caller: src, rel, entry and twelve more.
  local entry src rel dst f d copied=0 missing=0 scopied=0 known name \
        base_omarchy other_omarchy NOISE SCAN
  ensure_repo_layout
  # Before anything is copied, because it decides WHERE profile-scoped copies
  # go. Called here and not from ensure_repo_layout, which core_profile_set
  # calls itself.
  ensure_profile_recorded
  echo "→ Copying configuration (fixed MANIFEST, savegame)" >&2
  copied=0; missing=0
  local skipped=0 held=0
  local -a held_rels=()
  read_incoming
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
    # The repo holds a newer copy that came down from another machine, and this
    # machine has not caught up with it. Copying over it is never what the
    # sweeping "save everything" action means: this machine's version is the
    # STALE one, and one press of Save would commit it over work done elsewhere.
    #
    # Held, not refused, and it clears itself: restore the file and the copies
    # match again, so the next save treats it like any other row. The escape
    # hatch, for the day this machine's version really should win, is naming it:
    # `save-file <id>` saves one file the user asked for by name.
    if [[ -n "${INCOMING[$rel]:-}" ]] && entry_differs "$src" "$dst" "$(is_dir_entry "$rel" && echo true || echo false)"; then
      held=$((held + 1)); held_rels+=("$rel")
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
    echo "  $copied copied, $missing missing, $skipped switched off" >&2
  else
    echo "  $copied copied, $missing missing" >&2
  fi
  if (( held > 0 )); then
    echo "  · held back $(plural "$held" file) another machine changed — 'restore --apply' brings them here:" >&2
    printf '      %s\n' "${held_rels[@]}" >&2
    echo "    (to save this machine's version instead: 'save-file <id>')" >&2
  fi

  # Prune what is no longer tracked. Without this, dropping a line from MANIFEST
  # (or uninstalling a plugin) leaves its last copy in config/ forever — the
  # repo slowly fills with files that describe a machine that no longer exists,
  # and the panel has no row to act on them with. Nothing is actually lost:
  # every removal lands in a commit, and git keeps the content.
  # A file is expected at exactly one path: the one repo_path_for() gives it.
  # So the prune pass asks the same function the copy pass did, and a file that
  # moved between scopes is cleaned up at its old path by core_scope(), not here.
  # A client older than whatever last wrote this repo copies its own files in
  # and stops there. Everything it does not recognise belongs to a version that
  # knows more than it does, and deleting that is how one machine's upgrade
  # becomes another machine's data loss.
  if ! may_prune; then
    echo "  · this repo was last written by Replicant $(repo_written_by); this machine has $(running_version)" >&2
    echo "    nothing was pruned — upgrade this machine so it can see everything the other one tracks" >&2
  else
  local -a expected=()
  local _e
  for entry in "${TRACKED[@]}"; do
    _e="${entry##*:}"
    is_excluded "$_e" && continue
    expected+=("$(repo_path_for "$_e")")
  done
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
  (( pruned > 0 )) && echo "  $(plural "$pruned" "stale file") pruned" >&2
  fi

  echo "→ Copying secrets (private repo, 600)" >&2
  install -d -m 700 "$SECRETS_DIR" 2>/dev/null || true
  scopied=0
  for entry in "${TRACKED_SECRETS[@]}"; do
    src=${entry%%:*}
    rel="${entry##*:}"
    dst="$SECRETS_DIR/$rel"
    is_excluded "$rel" && continue
    if [[ -f $src && ! -r $src ]]; then
      # Readable by root only, which is common under /etc. The copy failed
      # under set -e and ended the whole backup. Name it and go on.
      echo "  · ${src/#$HOME/\~} is readable by root only. To save it: sudo install -D -m600 -o $(id -un) -g $(id -gn) $src $dst" >&2
    elif [[ -f $src ]]; then
      install -d -m 700 "$(dirname "$dst")" 2>/dev/null || mkdir -p "$(dirname "$dst")"
      install -m 600 "$src" "$dst"
      ((scopied++)) || true
    else
      echo "  · missing: ${src/#$HOME/\~}" >&2
    fi
  done
  echo "  $(plural "$scopied" secret) copied" >&2

  echo "→ Regenerating state/ inventory" >&2
  mkdir -p "$STATE_DIR"
  # There is no system.txt any more. It carried hostname, kernel, the Omarchy
  # version and a tool version: four lines, three of which move on every system
  # update, and NOTHING in this plugin ever read one of them back. An inventory
  # earns its place by being what a restore uses or what a person rebuilds from;
  # a version string that is already out of date by the time you read it is
  # neither. Losing its `date:` line was the first half of this; the file was
  # the other half.
  #
  # What survives the same test: the package lists (that IS how you rebuild a
  # machine), the plugin and theme inventories (restore genuinely consumes
  # them), and drift-vs-omarchy (what you changed, which changes rarely).
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
    echo "# A restore never fetches one. Install it yourself, one at a time:"
    echo "#   omarchy-replicant install-plugin <id>     (asks first, every time)"
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
    echo "# name<TAB>origin — user-installed themes. A restore never fetches one."
    echo "#   omarchy-replicant install-theme <name>    (asks first, every time)"
    echo "# Local edits to a theme are NOT here: this installs the upstream copy."
    local tdir tname torigin
    for tdir in "$HOME/.config/omarchy/themes"/*/; do
      [[ -d "$tdir" ]] || continue
      tname=$(basename "${tdir%/}")
      torigin=$(git -C "${tdir%/}" remote get-url origin 2>/dev/null || true)
      [[ -n "$torigin" ]] || torigin="-"
      printf '%s\t%s\n' "$tname" "$torigin"
    done
  } > "$STATE_DIR/omarchy-themes.txt"

  # `mise ls` marks stale installs "(pruned in 9h)" — a COUNTDOWN, so the file
  # differs from itself every hour and every save committed it. That is the
  # `date:` line this inventory already lost once, wearing a different hat.
  # Those rows are a version on its way out; what belongs in an inventory is
  # what is installed, so they are dropped and the countdown with them.
  # Names this inventory used to write and no longer does. A generator that
  # simply stops leaves its last output in the repo forever — the prune pass
  # sweeps config/ and the profile tree, never state/ — so a retired file would
  # sit there looking current. Only THIS machine's directory is touched; another
  # machine's inventory is not ours to tidy.
  # Only names a RELEASED version wrote. Two more were in this list — sistema.txt
  # and packages.txt — from before the plugin was published, so no user's repo
  # can contain them and no upgrade path leads through them. One of them was
  # also the only Spanish string left in the source.
  local _retired
  for _retired in system.txt mise.txt npm-global.txt containers.txt system-services.txt; do
    rm -f "$STATE_DIR/$_retired"
  done

  # Only the units the USER wrote. `systemctl --user list-unit-files --state=enabled`
  # returns eighteen here and fifteen of them are the distribution's decisions —
  # pipewire, wireplumber, gnome-keyring — which change on package updates, are
  # nobody's setup, and cost a commit every time. What is worth recording is the
  # service you wrote yourself and switched on; paired with the unit file, which
  # is tracked as ordinary config, that is enough to bring it back.
  #
  # A unit is yours when its file is in ~/.config/systemd/user. One systemctl
  # call plus a file test each, so it stays cheap on every save.
  {
    systemctl --user list-unit-files --state=enabled --no-pager --no-legend 2>/dev/null |
      awk '{print $1}' |
      while read -r _u; do
        [[ -f "$HOME/.config/systemd/user/$_u" ]] && printf '%s\n' "$_u"
      done
  } > "$STATE_DIR/user-services.txt" || true
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
  # This profile's tree too. A file kept per profile is copied there, and a
  # token in it went unscanned until the pre-commit hook, if the hook ran.
  local -a scan_dirs=("$CONFIG_DIR" "$STATE_DIR")
  [[ -d "$REPO_DIR/profiles/$(current_profile)/config" ]] &&
    scan_dirs+=("$REPO_DIR/profiles/$(current_profile)/config")
  if [[ -x "$SCAN" ]]; then
    if ! "$SCAN" "${scan_dirs[@]}" 2>&1; then
      echo "  ✗ POSSIBLE SECRET — DO NOT commit" >&2
      return 1
    fi
    echo "  ✓ clean" >&2
  else
    echo "  · scan-secrets.sh not found, skipping" >&2
  fi
  # Only when `backup` is the whole of what the user asked for. savegame calls
  # this on its way to committing, and the advice landed one line above its own
  # commit — the panel's log pane showed "commit with a why" immediately
  # followed by the commit. Telling someone to do the thing you are about to do
  # for them reads as if neither of you did it.
  if [[ "${1:-}" != "--for-savegame" ]]; then
    echo "Done. Review with 'git -C $REPO_DIR diff' and commit with a why." >&2
  fi
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
# ─── One git call, not one per row ──────────────────────────────────────────
# Every row asked git twice — "is this dirty" and "is this unpushed" — and the
# second re-checked whether an upstream exists each time. Fifty rows came to a
# hundred and eighty git processes per panel refresh, and the panel refreshes
# every sixty seconds. Both questions are answered for the whole repo in one
# call each, and the per-row lookups are then plain string matching.
#
# Cached per process, which is safe because the only thing that reads them is
# status/JSON building. Anything that writes the repo runs in its own command.
GIT_CACHE_READY=0
GIT_DIRTY_SET=""
GIT_UNPUSHED_SET=""
# Cached for the length of one build, not one process. Two commands in the same
# process — which is exactly what the test suite is — must not see the first
# one's answer after the second has committed.
GIT_HAS_UPSTREAM=0
invalidate_git_cache() { GIT_CACHE_READY=0; GIT_DIRTY_SET=""; GIT_UNPUSHED_SET=""; GIT_HAS_UPSTREAM=0; }
load_git_cache() {
  (( GIT_CACHE_READY )) && return 0
  GIT_CACHE_READY=1
  [[ -d "$REPO_DIR/.git" ]] || return 0
  # -uall so an untracked DIRECTORY is listed as its files: git collapses one to
  # "config/nvim/" otherwise, and a per-file lookup would miss every file in it.
  # -z so a path with a space or a quote arrives intact; a rename yields both
  # of its sides, and counting both as dirty is the safe direction.
  local rec
  while IFS= read -r -d '' rec; do
    [[ ${#rec} -gt 3 ]] && rec="${rec:3}"
    [[ -n "$rec" ]] && GIT_DIRTY_SET+="$rec"$'\n'
  done < <(git -C "$REPO_DIR" status --porcelain -z -uall 2>/dev/null || true)
  if git -C "$REPO_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    GIT_HAS_UPSTREAM=1
    GIT_UNPUSHED_SET=$(git -C "$REPO_DIR" diff --name-only '@{u}' 2>/dev/null || true)
  fi
}

# set_has <set> <path> — exact match, or prefix match when the path is a
# directory id (trailing slash), which is how a tracked tree asks "did anything
# under me change".
set_has() {
  local hay="$1" p="$2" line
  [[ -n "$hay" ]] || return 1
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ "$p" == */ ]]; then [[ "$line" == "$p"* ]] && return 0
    else [[ "$line" == "$p" ]] && return 0; fi
  done <<<"$hay"
  return 1
}

path_dirty() { load_git_cache; set_has "$GIT_DIRTY_SET" "$1"; }
# No upstream at all means nothing has ever been pushed, so everything is
# unpushed. Losing that case made a repo before its first push claim every file
# was already safe on GitHub.
path_unpushed() {
  load_git_cache
  (( GIT_HAS_UPSTREAM )) || return 0
  set_has "$GIT_UNPUSHED_SET" "$1"
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
  local -a mfs=()
  local mf pid pname short src
  for mf in "$plugins_dir"/*/manifest.json; do [[ -f "$mf" ]] && mfs+=("$mf"); done
  (( ${#mfs[@]} )) || return 0
  # One jq for every manifest. This runs each time the core is loaded, which
  # includes the bar's once-a-minute poll, and a process per plugin added up.
  while IFS=$'\t' read -r pid pname; do
    [[ -n "$pid" ]] || continue
    [[ "$pid" == "io.github.tymurbogach.omarchy-replicant" ]] && continue
    short="${pid##*.}"
    src="$HOME/.config/omarchy/$short.json"
    [[ -f "$src" ]] || continue
    printf '%s\t%s\t%s\n' "$src" "plugins/$short.json" "$pname"
  done < <(jq -r '[.id // "", .name // .id // ""] | @tsv' "${mfs[@]}" 2>/dev/null)
}

# discover_kept_plugin_configs — plugin configs the repo holds for a plugin this
# machine does not have, but some machine that writes this repo does.
#
# Discovery used to be only what is installed HERE. The prune pass removes
# whatever is not tracked, so a laptop without a plugin deleted the desktop's
# settings for it on every save, and the desktop put them back on its next one.
# That is the "older machine deletes what a newer one tracks" bug, one level
# down. Which plugins exist on the other machine is a question for its
# inventory, state/<machine>/omarchy-plugins.txt, not for this machine's
# plugins directory.
#
# When no inventory records the plugin any more, the config is not kept and
# the next save prunes it. git still has it.
discover_kept_plugin_configs() {
  local -A recorded=()
  local short id f root
  while IFS=$'\t' read -r short id; do
    [[ -n "$short" ]] && recorded["$short"]="$id"
  done < <(awk -F'\t' '!/^#/ && $1 != "" { n = split($1, a, "."); print a[n] "\t" $1 }' \
             "$STATE_ROOT"/*/omarchy-plugins.txt 2>/dev/null)
  (( ${#recorded[@]} )) || return 0
  local -a roots=("$CONFIG_DIR/plugins")
  [[ -d "$REPO_DIR/profiles" ]] && roots+=("$REPO_DIR/profiles/$(current_profile)/config/plugins")
  for root in "${roots[@]}"; do
    for f in "$root"/*.json; do
      [[ -f "$f" ]] || continue
      short="${f##*/}"; short="${short%.json}"
      id="${recorded[$short]:-}"
      [[ -n "$id" && "$id" != "io.github.tymurbogach.omarchy-replicant" ]] || continue
      printf '%s\t%s\t%s\n' "$HOME/.config/omarchy/$short.json" "plugins/$short.json" "$id"
    done
  done
}

# ─── The Hyprland modules hyprland.lua loads ────────────────────────────────
# MANIFEST names the five modules Omarchy's own hyprland.lua loads. It cannot
# name the others: OmaSettings appends `require("hypr.omasettings")` and writes
# everything its window sets into ~/.config/hypr/omasettings.lua, and people
# split their own config into modules the same way. The repo then held a
# hyprland.lua loading a file the repo did not have. Restored on another
# machine, that is a Hyprland config error, and every setting in the module is
# gone.
#
# "What does my Hyprland config consist of" is answered by the config: every
# require of a `hypr.` module, followed through the modules it loads, in both
# the live file and the repo's copy. The repo's copy counts because a machine
# restoring for the first time has Omarchy's stock hyprland.lua, which loads
# nothing of the user's.

# lua_hypr_requires <file> — one `hypr.` module name per line. Comments are
# stripped first: a require that is commented out is not a load.
lua_hypr_requires() {
  sed -e 's/--.*$//' -- "$1" 2>/dev/null |
    grep -oE "require[[:space:]]*\(?[[:space:]]*[\"']hypr\.[A-Za-z0-9_.-]+[\"']" |
    sed -E "s/.*[\"']hypr\.([A-Za-z0-9_.-]+)[\"'].*/\1/" |
    grep -vE '(^\.|\.$|\.\.)' || true
}

# hypr_module_rel <module> — its tracked id, as Lua's path would find it on this
# machine or in the repo: hypr/<a/b>.lua, else hypr/<a/b>/init.lua.
hypr_module_rel() {
  local base="hypr/${1//.//}" cand
  for cand in "$base.lua" "$base/init.lua"; do
    [[ -f "$HOME/.config/$cand" || -f "$(repo_path_for "$cand")" ]] && { printf '%s\n' "$cand"; return 0; }
  done
  return 1
}

discover_hypr_modules() {
  local -a queue=("hypr/hyprland.lua")
  local -A seen=(["hypr/hyprland.lua"]=1)
  local rel f mod mrel
  while (( ${#queue[@]} )); do
    rel="${queue[0]}"; queue=("${queue[@]:1}")
    for f in "$HOME/.config/$rel" "$(repo_path_for "$rel")"; do
      [[ -f "$f" ]] || continue
      while IFS= read -r mod; do
        [[ -n "$mod" ]] || continue
        mrel=$(hypr_module_rel "$mod") || continue
        [[ -n "${seen[$mrel]:-}" ]] && continue
        seen["$mrel"]=1; queue+=("$mrel")
        printf '%s\t%s\t%s\n' "$HOME/.config/$mrel" "$mrel" "$mrel"
      done < <(lua_hypr_requires "$f")
    done
  done
}

# unresolved_hypr_modules — `hypr.` modules the LIVE config loads that exist
# nowhere on this machine. Hyprland reports each one as an error on every
# reload, and a module nobody has cannot be backed up.
unresolved_hypr_modules() {
  local f mod
  for f in "$HOME/.config/hypr/hyprland.lua" "$HOME"/.config/hypr/*.lua; do
    [[ -f "$f" ]] || continue
    while IFS= read -r mod; do
      [[ -f "$HOME/.config/hypr/${mod//.//}.lua" || -f "$HOME/.config/hypr/${mod//.//}/init.lua" ]] && continue
      printf 'hypr.%s\n' "$mod"
    done < <(lua_hypr_requires "$f")
  done | sort -u
}

is_auto_entry() { [[ -n "${AUTO_LABEL[$1]+x}" ]]; }

# load_auto_manifest — fill AUTO_MANIFEST and fold it into TRACKED. An entry a
# person already listed wins: a path they track by hand, or one inside a
# directory they track, is theirs and is not found a second time.
load_auto_manifest() {
  local src rel label entry taken
  AUTO_MANIFEST=(); AUTO_LABEL=()
  rebuild_tracked
  read_scopes >/dev/null
  while IFS=$'\t' read -r src rel label; do
    [[ -n "$rel" ]] || continue
    is_auto_entry "$rel" && continue
    is_tracked_path "$src" && continue
    taken=0
    for entry in "${TRACKED[@]}"; do [[ "${entry##*:}" == "$rel" ]] && { taken=1; break; }; done
    (( taken )) && continue
    AUTO_MANIFEST+=("$src:$rel"); AUTO_LABEL["$rel"]="$label"
  done < <(discover_plugin_entries; discover_kept_plugin_configs; discover_hypr_modules)
  rebuild_tracked
}
load_auto_manifest

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
#            the Hyprland option ("input:repeat_rate") for lua-*, whose last
#            segment is the Lua key and whose whole name is what Hyprland is
#            asked for the value in force | "-" for theme
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
  "bar.sizeHorizontal|Appearance|$HOME/.config/omarchy/shell.toml|bar.size-horizontal|toml-int|Bar thickness (top/bottom)|px|16|80||Bar height on a horizontal edge; setting it stops the font scaling it||26|1|"
  "bar.sizeVertical|Appearance|$HOME/.config/omarchy/shell.toml|bar.size-vertical|toml-int|Bar thickness (left/right)|px|16|120||Bar width on a vertical edge; setting it stops the font scaling it||28|1|"
  "bar.iconFont|Appearance|$HOME/.config/omarchy/shell.toml|bar.icon-font|toml-int|Bar icon size|px|8|28||How large the glyphs in the bar are drawn||13|1|"
  # ── Input — Hyprland reads Lua at startup, so these need an explicit reload
  "input.repeatRate|Input|$HOME/.config/hypr/input.lua|input:repeat_rate|lua-int|Key repeat rate|/s|1|100||Characters a held key sends per second|hyprctl reload||1|"
  "input.repeatDelay|Input|$HOME/.config/hypr/input.lua|input:repeat_delay|lua-int|Key repeat delay|ms|100|2000||How long a key is held before it starts repeating|hyprctl reload||1|"
  "input.kbLayout|Input|$HOME/.config/hypr/input.lua|input:kb_layout|lua-enum|Keyboard layout||||@x11-layouts|X11 layout code for the keyboard|hyprctl reload||1|"
  "input.numlock|Input|$HOME/.config/hypr/input.lua|input:numlock_by_default|lua-bool|Num lock at login|||||Turn the numeric keypad on when the session starts|hyprctl reload||1|"
  "input.naturalScroll|Input|$HOME/.config/hypr/input.lua|input:touchpad:natural_scroll|lua-bool|Natural scrolling|||||Touchpad: two fingers down moves the page up|hyprctl reload||1|"
  "input.tapToClick|Input|$HOME/.config/hypr/input.lua|input:touchpad:tap_to_click|lua-bool|Tap to click|||||Touchpad: a tap counts as a click|hyprctl reload||1|"
  "input.disableWhileTyping|Input|$HOME/.config/hypr/input.lua|input:touchpad:disable_while_typing|lua-bool|Ignore touchpad while typing|||||Stops the cursor jumping mid-sentence|hyprctl reload||1|"
  # ── Lid & sleep — /etc/systemd/logind.conf.d/, root-owned, laptop only.
  # These are the three questions a laptop actually asks. logind's own built-in
  # default for all three is 'suspend'; the fallback field records that so the
  # panel can show a value even before a drop-in exists.
  "lid.close|Lid & sleep|$LOGIND_DROPIN|Login.HandleLidSwitch|ini-enum|Closing the lid||||suspend,suspend-then-hibernate,hibernate,lock,ignore,poweroff|What happens on battery when the lid closes|systemctl reload systemd-logind|suspend|1|"
  "lid.closeAc|Lid & sleep|$LOGIND_DROPIN|Login.HandleLidSwitchExternalPower|ini-enum|Closing the lid on AC||||suspend,suspend-then-hibernate,hibernate,lock,ignore,poweroff|What happens while plugged in; many people want 'ignore' here|systemctl reload systemd-logind|suspend|1|"
  "lid.closeDocked|Lid & sleep|$LOGIND_DROPIN|Login.HandleLidSwitchDocked|ini-enum|Closing the lid when docked||||ignore,suspend,suspend-then-hibernate,hibernate,lock,poweroff|What happens with an external monitor attached; 'ignore' is clamshell mode|systemctl reload systemd-logind|ignore|1|"
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
setting_field() { local -a fields; IFS='|' read -ra fields <<<"$1"; printf '%s' "${fields[$(($2 - 1))]:-}"; }

find_setting() {
  local id="$1" entry
  # The id is the first field, so a prefix match finds it without a fork.
  # `$(setting_field ...)` here was one fork per registry line, and the panel
  # payload looks up every setting three times: hundreds of forks, and about
  # half of the time that `status --json` took.
  for entry in "${SETTINGS[@]}"; do
    [[ "${entry%%|*}" == "$id" ]] && { printf '%s\n' "$entry"; return 0; }
  done
  return 1
}

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
  local dst="$1" staged="$2" after="${3:-}" script
  script='dst="$1"; staged="$2"; after="$3";
    if [ -f "$dst" ]; then cp -a "$dst" "$dst.bak.$(date +%s)" || exit 1; fi
    install -D -m 644 -o root -g root "$staged" "$dst" || exit 1
    [ -n "$after" ] && { sh -c "$after" || exit 2; }
    exit 0'
  if command -v pkexec >/dev/null 2>&1 && [[ -n "${XDG_SESSION_ID:-}${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    pkexec /bin/sh -c "$script" _ "$dst" "$staged" "$after" 2>/dev/null && return 0
  fi
  if sudo -n true 2>/dev/null; then
    sudo -n /bin/sh -c "$script" _ "$dst" "$staged" "$after" 2>/dev/null && return 0
  fi
  echo "This one needs root, and nothing on this session could ask for it." >&2
  echo "Nothing was changed. To apply it yourself:" >&2
  echo "  sudo install -D -m 644 $staged $dst" >&2
  [[ -n "$after" ]] && echo "  sudo $after" >&2
  # Always a failure. This read `return "${rc:-1}"` with rc starting at 0, so
  # the path above returned success: `set` printed the new value, exited 0,
  # and the panel reported a write that never happened.
  return 1
}

# ini_set <file> <Section.Key> <value> [reload command]
# Stages the whole edited file under $HOME first, so the privileged step is a
# single copy of a file the user could have inspected, not an editor run as root.
ini_set() {
  invalidate_file_maps
  local file="$1" path="$2" value="$3" after="${4:-}" staged
  # Staged in the plugin's own directory, not in /tmp. When nothing can ask for
  # root, root_apply prints a `sudo install` of this file for the user to run,
  # so the file has to outlive this call. It used to be deleted on the way
  # out, and the printed command named a file that did not exist.
  mkdir -p "$REPLICANT_HOME/staged" || return 1
  staged="$REPLICANT_HOME/staged/$(basename -- "$file")"
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
    # A test redirects $file to a throwaway fixture, but "systemctl reload
    # systemd-logind" still targets the REAL system service — polkit pops a
    # graphical, fingerprint-eligible auth prompt for it even though nothing
    # here calls sudo/pkexec directly. REPLICANT_NO_RELOAD is the test-only
    # escape hatch, the same shape as REPLICANT_MACHINE/OMARCHY_PATH elsewhere.
    [[ -n "$after" && -z "${REPLICANT_NO_RELOAD:-}" ]] && bash -c "$after" >/dev/null 2>&1
    rm -f "$staged"; return 0
  fi
  # On failure the staged file stays: the message names it.
  root_apply "$file" "$staged" "$after" || return 1
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
# ── TOML / INI writing ──────────────────────────────────────────────────────
# Deliberately minimal: these target a flat "key = value" line inside a
# "[section]" of a small, hand-written config (shell.toml, a logind drop-in).
# They are not a TOML parser and are not meant to grow into one; anything more
# complex stays a whole-file MANIFEST entry, edited in a real editor.
# Reading goes through file_map() instead, which parses the whole file once.
toml_set() {
  invalidate_file_maps
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
  invalidate_file_maps
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

# lua_key_of <option> — the Lua key of a registry path: "input:touchpad:
# natural_scroll" is the line `natural_scroll = …` in the file.
lua_key_of() { printf '%s\n' "${1##*:}"; }

# hypr_in_force <option> — the value Hyprland is using now, as the file would
# spell it ("40", "true", "es"). Fails when there is no Hyprland to ask.
# `has()`, never `//`: jq's alternative operator treats false as missing, so a
# switch that is off would read as unknown.
hypr_in_force() {
  command -v hyprctl >/dev/null 2>&1 || return 1
  local out
  out=$(timeout 2 hyprctl getoption "$1" -j 2>/dev/null) || return 1
  jq -er 'if has("int") then .int elif has("float") then .float
          elif has("bool") then .bool elif has("str") then .str else empty end
          | tostring' <<<"$out" 2>/dev/null
}

# hypr_overrider <key> <own-file> — the tracked Hyprland file, other than the
# setting's own, with an uncommented `<key> =` line. Found modules are asked
# first: OmaSettings' omasettings.lua is loaded last, which is why it wins.
hypr_overrider() {
  local key="$1" own="$2" entry src
  for entry in ${AUTO_MANIFEST[@]+"${AUTO_MANIFEST[@]}"} "${TRACKED[@]}"; do
    src="${entry%%:*}"
    [[ "$src" == "$HOME/.config/hypr/"*.lua && "$src" != "$own" && -f "$src" ]] || continue
    [[ "$(lua_key_hits "$src" "$key")" -ge 1 ]] && { printf '%s\n' "${entry##*:}"; return 0; }
  done
  return 1
}

# backup_before_write <file> — the .bak.<epoch> every write owes the user,
# minus the litter. Editing one setting is a small, repeated act (dragging the
# density slider is a dozen writes), and one backup per write buried the real
# config under a heap of near-identical copies in the same directory. Keep the
# three most recent per file: enough to walk back a bad afternoon, few enough
# that `ls ~/.config/omarchy` still reads.
BACKUPS_KEPT=${REPLICANT_BACKUPS_KEPT:-3}
# The backups that this function made, one path per line. Pruning uses this
# list and never the glob alone: `<file>.bak.*` also matches the backup that a
# restore made (install_file) and the ones that `omarchy refresh config` makes.
# The glob made three edits to a setting after a restore delete the undo for
# that restore.
SETTING_BACKUPS_FILE="$REPLICANT_HOME/setting-backups"
backup_before_write() {
  local file="$1" b old kept
  [[ -f "$file" ]] || return 0
  b="$file.bak.$(date +%s)"
  cp -a "$file" "$b" || return 1
  mkdir -p "$REPLICANT_HOME" 2>/dev/null || return 0
  printf '%s\n' "$b" >> "$SETTING_BACKUPS_FILE"
  # shellcheck disable=SC2012,SC2010  # names are ours: <file>.bak.<epoch>, no spaces
  while read -r old; do
    [[ -n "$old" ]] && rm -f -- "$old"
  done < <(ls -1t -- "$file".bak.* 2>/dev/null | grep -Fxf "$SETTING_BACKUPS_FILE" | tail -n +$((BACKUPS_KEPT + 1)))
  # Forget what no longer exists, so that the list cannot grow without end.
  kept=$(sort -u "$SETTING_BACKUPS_FILE" | while read -r old; do
           if [[ -e "$old" ]]; then printf '%s\n' "$old"; fi
         done)
  printf '%s\n' "$kept" | sed '/^$/d' > "$SETTING_BACKUPS_FILE"
}

# ── read / write one setting ────────────────────────────────────────────────
setting_options() {
  # Two option lists are not fixed: the themes installed now, and the keyboard
  # layouts this machine knows (`@x11-layouts` in the registry). A fixed list
  # of eight layouts left anyone outside it with a control that could not show
  # or keep the value.
  local entry="$1" opts
  if [[ "$(setting_field "$entry" 5)" == "theme" ]]; then
    omarchy-theme-list 2>/dev/null | paste -sd, - || true
    return 0
  fi
  opts=$(setting_field "$entry" 10)
  if [[ "$opts" == "@x11-layouts" ]]; then
    opts=$(localectl list-x11-keymap-layouts 2>/dev/null | paste -sd, - || true)
    [[ -n "$opts" ]] || opts="us,es,gb,de,fr,it,pt,latam"
  fi
  printf '%s\n' "$opts"
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
      raw=$(map_lookup "$file" toml "$path") || return 1
      [[ -n "$raw" ]] || return 1
      printf '%s\n' "$raw"
      ;;
    ini-enum)
      # No drop-in yet means logind is on its built-in default, which is what
      # the fallback field records — so report that rather than "missing".
      if [[ -f "$file" ]]; then
        raw=$(map_lookup "$file" toml "$path" 2>/dev/null || true)
        [[ -n "$raw" ]] && { printf '%s\n' "$raw"; return 0; }
      fi
      raw=$(setting_field "$entry" 13)
      [[ -n "$raw" ]] || return 1
      printf '%s\n' "$raw"
      ;;
    lua-int|lua-bool|lua-enum)
      map_lookup "$file" lua "$(lua_key_of "$path")"
      ;;
    *)
      [[ -f "$file" ]] || return 1
      # A missing key reads as absent, but `false` must not: jq's `//` fires on
      # false as well as null, so a boolean setting that is genuinely off would
      # look like a setting that is not there.
      raw=$(map_lookup "$file" json "$path") || return 1
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
  invalidate_file_maps
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
      lua_set "$file" "$(lua_key_of "$path")" "$value" || { echo "$1: '$path' is missing or ambiguous in $file — left untouched" >&2; return 1; }
      ;;
    lua-enum)
      [[ -f "$file" ]] || { echo "file not found: $file" >&2; return 1; }
      backup_before_write "$file"
      lua_set "$file" "$(lua_key_of "$path")" "\"$value\"" || { echo "$1: '$path' is missing or ambiguous in $file — left untouched" >&2; return 1; }
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

# is_secret_rel <rel> — is this entry a secret? A question about the ENTRY, not
# about how it happens to be spelled.
#
# Everything that protects a secret used to key on the path prefix ssh/ or env/,
# which was true for the three the plugin ships. Then `track --secret` let a user
# add one under any name: ~/.config/gh/hosts.yml derives to "gh/hosts.yml", and
# every one of those rules quietly stopped applying to it. It was copied INTO
# secrets/ and read back OUT of config/ (so the panel called a saved file
# unsaved and revert-to-repo could never find it), it would have been restored
# at mode 644 with an OAuth token in it, and core_diff's refusal to render a
# secret did not recognise it as one.
is_secret_rel() {
  local rel="$1" entry
  for entry in "${TRACKED_SECRETS[@]}"; do
    [[ "${entry##*:}" == "$rel" ]] && return 0
  done
  return 1
}

repo_copy_for_rel() {
  if is_secret_rel "$1"; then printf '%s\n' "$SECRETS_DIR/$1"; else repo_path_for "$1"; fi
}

# read_setting_from <entry> <file> — the same getter as get_setting_value, but
# pointed at any file. Used to read the key out of Omarchy's shipped default
# and out of the repo's saved copy, which is what makes the two revert buttons
# possible without a second parser.
# ─── One pass per file, not one process per value ───────────────────────────
# Every setting is read three times — the live file, Omarchy's default, and the
# copy in the repo — and each read forked at least one process. lua_get forked
# FOUR (two greps, a head and a sed). Twenty-four settings came to something
# like seventy processes per panel refresh, which was two thirds of the time
# `status --json` took.
#
# Each file is now parsed once, whole, into "path<TAB>value" lines, and the
# per-setting reads are lookups in a string. Parsing the whole file costs the
# same as parsing one key out of it: the process was the expense, not the work.
declare -gA FILE_MAP_CACHE=()
declare -gA FILE_MAP_LOADED=()
invalidate_file_maps() { FILE_MAP_CACHE=(); FILE_MAP_LOADED=(); }

# Command substitution forks, and a fork copies the caches rather than sharing
# them: a map built inside `$(file_map ...)` dies with the subshell, so the
# first version of this parsed every file on every single lookup and saved
# almost nothing. The parse therefore has to happen in the PARENT — warm_*
# below does that once, and the subshells then inherit a populated map.
#
# load_file_map is the half that may be called in the parent: it prints nothing.
load_file_map() {
  local file="$1" kind="$2" key="$1|$2"
  if [[ -z "${FILE_MAP_LOADED[$key]:-}" ]]; then
    FILE_MAP_LOADED[$key]=1
    FILE_MAP_CACHE[$key]=""
    if [[ -f "$file" ]]; then
      case "$kind" in
        json)
          # ".idle.lock<TAB>600" — the same dotted form field 4 uses.
          #
          # NOT paths(scalars): jq's path filter selects on truthiness, so a key
          # whose value is `false` produces no path and vanishes from the map.
          # A boolean setting that is genuinely off would then read as missing,
          # which is the exact bug the comment in get_setting_value warns about.
          FILE_MAP_CACHE[$key]=$(jq -r '
            paths as $p | getpath($p) as $v
            | select(($v|type) != "object" and ($v|type) != "array")
            | "." + ($p|map(tostring)|join(".")) + "\t" + ($v|tostring)
          ' "$file" 2>/dev/null || true) ;;
        toml)
          # The key charset is deliberately "anything that is not whitespace or
          # an equals sign", because that is what the greps this replaces
          # matched. shell.toml's key is `base-size`: an identifier pattern
          # dropped it, and the setting read as missing.
          FILE_MAP_CACHE[$key]=$(awk '
            /^[[:space:]]*\[/ { sect = $0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", sect); next }
            /^[[:space:]]*[^#=[:space:]]+[[:space:]]*=/ {
              k = $0; sub(/[[:space:]]*=.*$/, "", k); gsub(/^[[:space:]]+/, "", k)
              v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); gsub(/[[:space:]]*$/, "", v)
              print (sect == "" ? k : sect "." k) "\t" v
            }' "$file" 2>/dev/null || true) ;;
        lua)
          # lua_get deliberately refuses a key that appears twice — a nested
          # table needs a real parser and these files decide whether the
          # graphical session starts. The map keeps that: a key seen more than
          # once is dropped rather than guessed at.
          FILE_MAP_CACHE[$key]=$(awk '
            /^[[:space:]]*[^#=[:space:]]+[[:space:]]*=/ {
              k = $0; sub(/[[:space:]]*=.*$/, "", k); gsub(/^[[:space:]]+/, "", k)
              v = $0; sub(/^[^=]*=[[:space:]]*/, "", v)
              sub(/--.*$/, "", v); sub(/,[[:space:]]*$/, "", v)
              gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
              gsub(/^"|"$/, "", v)
              n[k]++; val[k] = v
            }
            END { for (k in n) if (n[k] == 1) print k "\t" val[k] }' "$file" 2>/dev/null || true) ;;
      esac
    fi
  fi
}

# file_map <file> <json|toml|lua> — every scalar in the file, keyed the way the
# SETTINGS registry addresses it.
file_map() {
  load_file_map "$1" "$2"
  printf '%s' "${FILE_MAP_CACHE[$1|$2]}"
}

# Parse, in this shell, every file the registry will be read from: the live one,
# Omarchy's default and the copy in the repo. Fourteen files instead of seventy
# lookups, and every lookup after this is a string search.
map_kind_for_type() {
  case "$1" in
    toml-int|toml-float|ini-enum)  echo toml ;;
    lua-int|lua-bool|lua-enum)     echo lua ;;
    number|bool|enum)              echo json ;;
    *)                             echo "" ;;
  esac
}
warm_setting_file_maps() {
  local entry file type kind def rel copy
  for entry in "${SETTINGS[@]}"; do
    file=$(setting_field "$entry" 3); type=$(setting_field "$entry" 5)
    [[ "$file" != "-" ]] || continue
    kind=$(map_kind_for_type "$type"); [[ -n "$kind" ]] || continue
    load_file_map "$file" "$kind"
    def=$(default_for_src "$file" 2>/dev/null || true)
    [[ -n "$def" ]] && load_file_map "$def" "$kind"
    rel=$(rel_for_src "$file" 2>/dev/null || true)
    [[ -n "$rel" ]] && { copy=$(repo_copy_for_rel "$rel"); load_file_map "$copy" "$kind"; }
  done
}

# map_lookup <file> <kind> <key> — the value, or failure when the key is absent.
#
# The obvious spelling, map_get "$(file_map ...)" "$key", is TWO command
# substitutions and therefore two forks per read, three reads per setting,
# twenty-four settings. This is one.
map_lookup() {
  load_file_map "$1" "$2"
  local k v
  while IFS=$'\t' read -r k v; do
    [[ "$k" == "$3" ]] && { printf '%s\n' "$v"; return 0; }
  done <<<"${FILE_MAP_CACHE[$1|$2]}"
  return 1
}

read_setting_from() {
  local entry="$1" file="$2" path type raw
  path=$(setting_field "$entry" 4); type=$(setting_field "$entry" 5)
  [[ -f "$file" ]] || return 1
  case "$type" in
    line-enum)
      raw=$(head -n1 "$file" 2>/dev/null | tr -d '[:space:]')
      [[ -n "$raw" ]] && printf '%s\n' "$raw" || return 1 ;;
    toml-int|toml-float|ini-enum)
      raw=$(map_lookup "$file" toml "$path") || return 1
      [[ -n "$raw" ]] && printf '%s\n' "$raw" || return 1 ;;
    lua-int|lua-bool|lua-enum)
      map_lookup "$file" lua "$(lua_key_of "$path")" ;;
    number|bool|enum)
      raw=$(map_lookup "$file" json "$path") || return 1
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
  # Say which of the two things is wrong. Both failures below assume the id is
  # real, so an id that is not reported "no Omarchy default known for
  # nope.setting" — which reads as a fact about a setting that does not exist.
  find_setting "$id" >/dev/null || { echo "unknown setting: $id" >&2; return 1; }
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
  invalidate_file_maps
  warm_setting_file_maps
  # One jq invocation for the whole array, not one per setting. The panel polls
  # status once a minute and refreshes after every write, and twenty-odd `jq -n`
  # spawns per build were most of the time that took.
  local entry id group file path type label unit min max options hint value available fallback implicit
  local scale disp dvalue dmin dmax dstep vtext defval deftext repoval repotext canrd canrr numeric boolean
  local lnotice inforce by
  {
  local laptop=1; is_laptop || laptop=0
  local -a F
  for entry in "${SETTINGS[@]}"; do
    # Split the line ONCE. Each setting_field call is a command substitution,
    # which is a fork, and thirteen of them per setting across twenty-four
    # settings was three hundred forks to read a string this shell already had.
    IFS='|' read -ra F <<<"$entry"
    id="${F[0]}";        group="${F[1]}"
    # A desktop has no lid. The group is absent rather than greyed out.
    [[ "$group" == "Lid & sleep" && "$laptop" == 0 ]] && continue
    file="${F[2]}";      path="${F[3]}"
    type="${F[4]}";      label="${F[5]}"
    unit="${F[6]}";      min="${F[7]}"
    max="${F[8]}";       hint="${F[10]}"
    fallback="${F[12]:-}"
    scale="${F[13]:-}";  disp="${F[14]:-}"
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

    # Hyprland is asked, not the file. These controls write input.lua, and a
    # module loaded after it that sets the same key wins: OmaSettings keeps
    # its Keyboard and Mouse pages in hypr/omasettings.lua, loaded last. The
    # row then showed what the file says while the session did something else.
    # Said only when Hyprland answers, and only when the two differ.
    lnotice=""
    if [[ "$type" == lua-* && "$available" == true ]] && inforce=$(hypr_in_force "$path"); then
      if [[ "$type" == lua-bool ]]; then
        [[ "$inforce" == 1 ]] && inforce=true
        [[ "$inforce" == 0 ]] && inforce=false
      fi
      if [[ "$inforce" != "$value" ]]; then
        by=$(hypr_overrider "$(lua_key_of "$path")" "$file") || by="a file loaded later"
        lnotice="In force: $(human_value "$type" "$unit" "$scale" "$disp" "$inforce") — set by $by."
      fi
    fi

    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
      "$id" "$group" "$label" "$type" "$unit" "$min" "$max" "$options" "$hint" "$file" \
      "$available" "$implicit" "$value" "$scale" "$disp" "$dvalue" "$dmin" "$dmax" "$dstep" \
      "$vtext" "$defval" "$deftext" "$repoval" "$repotext" "$canrd" "$canrr" "$numeric" "$boolean" \
      "$lnotice"
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
      can_revert_default: (.[24]|flag), can_revert_repo: (.[25]|flag),
      lua_notice: (.[28] // "")
    })' | jq -c --arg lidblock "$(lid_blocked_by)" '
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
        # Not a warning about how you configured it — a statement that what you
        # configured is not what happens. Something else is holding the lid
        # switch and logind is ignoring this file.
        elif (.id | startswith("lid.")) and $lidblock != ""
          # Two lines of about 34 characters is what the row gives it, so the
          # sentence has to fit in ~66 — the first attempt said the same thing
          # in 91 and lost "does nothing" to the ellipsis, which was the half
          # worth reading.
          then "Overridden by \($lidblock) — the lid does nothing."
        # The same statement about Hyprland: what the session uses is not what
        # the file says (see lnotice above).
        elif .lua_notice != "" then .lua_notice
        else "" end) } | del(.lua_notice))'
}

# lid_blocked_by — who, if anyone, is holding a `block` inhibitor on the lid
# switch. Empty when nobody is.
#
# This exists because the panel was telling a confident lie. It reported
# lid.close by reading /etc/systemd/logind.conf.d/99-lid.conf — the file it
# writes itself — while a plugin (Omarchy Sleepwalker) held a block inhibitor
# that makes logind ignore the lid entirely. The config said
# "suspend-then-hibernate"; closing the lid did nothing at all.
#
# Same shape as the bug that opened this whole line of work: answering a
# question about the SYSTEM by reading the ARTIFACT you wrote. A `delay`
# inhibitor is not this — those are normal and transient (NetworkManager and
# UPower each hold one). Only `block` overrides the setting.
lid_blocked_by() {
  # WHO is free text and often contains spaces ("Omarchy Sleepwalker"), so it
  # is neither $1 nor a greedy regex — both got it wrong. Between WHO and WHAT
  # there are exactly four columns (UID USER PID COMM), so WHO is everything
  # up to five fields before the one reading handle-lid-switch.
  # An inhibitor may hold SEVERAL whats at once, and systemd prints them
  # colon-joined in one column: `sleep:idle:handle-lid-switch`. Testing the
  # field for equality missed every one of those — it only ever matched a holder
  # that wanted the lid and nothing else.
  systemd-inhibit --list --no-pager 2>/dev/null | awk '
    $NF == "block" {
      for (i = 1; i <= NF; i++) if ($i ~ /(^|:)handle-lid-switch(:|$)/) {
        who = ""
        for (j = 1; j <= i - 5; j++) who = who (j > 1 ? " " : "") $j
        if (who != "") { print who; exit }
      }
    }'
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
  invalidate_git_cache
  # One jq for the whole list. Same reason as build_settings_json: this runs on
  # every panel refresh and there are forty-odd rows.
  local entry src rel label category exists is_default has_default default_src config_rel
  local dirty unpushed sync_state saved synced source scope repo_path git_rel unsaved is_dir nfiles incoming
  # Fill the scope cache HERE, in this shell. scope_for is reached through
  # $(repo_path_for ...) for every row, and a cache filled inside that
  # substitution is discarded with it — the file was re-read fifty times over.
  read_scopes >/dev/null
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
    entry_differs "$src" "$repo_path" "$is_dir" && unsaved=true
    # Copied into the repo but not committed is unsaved too — same word, same
    # button. Content and git each catch a case the other misses.
    dirty=false
    path_dirty "$git_rel" && dirty=true
    [[ "$dirty" == true ]] && unsaved=true
    unpushed=false
    path_unpushed "$git_rel" && unpushed=true
    # The same difference, pointing the other way. Only meaningful while the
    # file still differs, which is what makes it clear itself once the entry is
    # restored — or once the user knowingly saves over it.
    incoming=false
    [[ "$unsaved" == true ]] && is_incoming_rel "$rel" && incoming=true
    synced=true
    [[ "$scope" == "off" ]] && synced=false
    # off > missing > incoming > unsaved > default > unpushed > saved.
    #
    # incoming MUST outrank unsaved, and it is the only ordering that is about
    # safety rather than tidiness. Both mean "this file and its copy differ";
    # unsaved asks for Save and incoming asks for Restore, and pressing the
    # wrong one commits over work another machine did. When the direction is
    # known, it wins.
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
    elif [[ "$incoming" == true ]]; then sync_state="incoming"
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
    # Found automatically (another plugin's config, a module hyprland.lua
    # loads) is neither shipped nor the user's: no Untrack, and no ghost row.
    source=manifest
    if is_user_entry "$rel"; then source=user
    elif is_auto_entry "$rel"; then source=auto; label="${AUTO_LABEL[$rel]}"; fi
    if [[ "$source" != user && "$exists" == false && "$saved" == false ]]; then continue; fi
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
      "$rel" "$label" "$src" "$category" "$exists" "$is_default" "$has_default" \
      "$config_rel" "$dirty" "$unpushed" "$sync_state" "$saved" "$synced" "$source" "$scope" "$unsaved" \
      "$is_dir" "$nfiles" "$incoming"
  done
  } | jq -Rsc '
    def flag: . == "true";
    split("\n") | map(select(length > 0) | split("\u001f") | {
      id: .[0], label: .[1], src: .[2],
      category: .[3], group: .[3],
      exists: (.[4]|flag), is_default: (.[5]|flag), has_default: (.[6]|flag),
      config_rel: .[7], dirty: (.[8]|flag), unpushed: (.[9]|flag),
      sync_state: .[10], saved: (.[11]|flag), synced: (.[12]|flag),
      source: .[13], scope: .[14], unsaved: (.[15]|flag),
      is_dir: (.[16]|flag), nfiles: (.[17]|tonumber? // 0),
      incoming: (.[18]|flag)
    })'
}

# Secrets get their own shape, and deliberately never their own content. What
# the panel needs is "is it here, is it saved, are the permissions right" — a
# preview of an SSH private key on screen is a way to leak it over a shoulder or
# a screen share, so the only thing read out of an env file is the NAMES of the
# variables it defines.
build_secrets_json() {
  invalidate_git_cache
  local entry src rel exists mode kind dirty unpushed saved synced sync_state vars nvars unsaved incoming
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
    entry_differs "$src" "$SECRETS_DIR/$rel" false && unsaved=true
    dirty=false
    path_dirty "secrets/$rel" && dirty=true
    [[ "$dirty" == true ]] && unsaved=true
    unpushed=false
    path_unpushed "secrets/$rel" && unpushed=true
    incoming=false
    [[ "$unsaved" == true ]] && is_incoming_rel "$rel" && incoming=true
    synced=true
    is_excluded "$rel" && synced=false
    if [[ "$synced" == false ]]; then sync_state="off"
    elif [[ "$exists" == false ]]; then sync_state="missing"
    elif [[ "$incoming" == true ]]; then sync_state="incoming"
    elif [[ "$unsaved" == true ]]; then sync_state="unsaved"
    elif [[ "$unpushed" == true ]]; then sync_state="unpushed"
    else sync_state="saved"
    fi
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
      "$rel" "$src" "$exists" "$mode" "$kind" "$dirty" "$unpushed" "$saved" \
      "$synced" "$sync_state" "$vars" "$nvars" "$incoming"
  done
  } | jq -Rsc '
    def flag: . == "true";
    split("\n") | map(select(length > 0) | split("\u001f") | {
      id: .[0], src: .[1], exists: (.[2]|flag), mode: .[3], kind: .[4],
      dirty: (.[5]|flag), unpushed: (.[6]|flag), saved: (.[7]|flag),
      synced: (.[8]|flag), sync_state: .[9],
      vars: (if .[10] == "" then [] else (.[10]|split(",")) end),
      var_count: ((.[11]|tonumber?) // 0),
      incoming: (.[12]|flag)
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
      | {key: .[0], description: .[1], command: .[2], kind: .[3]})') || true
  [[ -n "$own" ]] || own='[]'
  # `|| true` on both: with set -o pipefail, a missing bindings.lua or a failing
  # `omarchy menu keybindings` ended the whole command with no output at all.
  active=$(omarchy menu keybindings --print 2>/dev/null |
    sed -e 's/[[:space:]]*→[[:space:]]*/\t/' |
    jq -Rsc 'split("\n") | map(select(length > 0) | split("\t")
      | {key: (.[0] // "" | sub("[[:space:]]+$";"")), description: (.[1] // "")})') || true
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
  # --brief answers only what the bar icon needs. The bar polls once a minute
  # and reads six numbers out of it; building forty kilobytes of file rows,
  # settings and categories for those six was most of the plugin's idle cost.
  # The full payload is built when the panel opens and after every write.
  local json=0 force_fetch=0 brief=0 arg
  for arg in "$@"; do
    case "$arg" in
      --json) json=1 ;;
      --fetch) force_fetch=1 ;;
      --no-fetch) force_fetch=-1 ;;
      --brief) brief=1 ;;
    esac
  done
  if [[ ! -d "$REPO_DIR/.git" ]]; then
    if (( json )); then echo '{"initialized":false}'; else echo "not initialized: run 'omarchy-replicant create --push', or 'clone <url>' for a repo you already have"; fi
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
  # One git status for both counts, not one each.
  local porcelain
  porcelain=$(git -C "$REPO_DIR" status --porcelain 2>/dev/null || true)
  dirty=$(grep -c . <<<"$porcelain" || true)
  untracked=$(grep -c '^??' <<<"$porcelain" || true)
  ahead=0; behind=0
  if git -C "$REPO_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    ahead=$(git -C "$REPO_DIR" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
    behind=$(git -C "$REPO_DIR" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)
  fi
  # Content, not git: what is on this machine that the repo has not got, and
  # which of those differences came down from another machine. Both the bar icon
  # and the panel header read these, so they can never disagree.
  local n_unsaved n_incoming
  read -r n_unsaved n_incoming < <(count_changes)
  local pending_groups=""
  path_dirty "config/"  && pending_groups="$pending_groups config"
  path_dirty "secrets/" && pending_groups="$pending_groups secrets"
  path_dirty "state/"   && pending_groups="$pending_groups state"
  if (( json && brief )); then
    jq -nc --arg branch "$branch" --arg remote "$remote" \
      --argjson dirty "$dirty" --argjson untracked "$untracked" \
      --argjson ahead "$ahead" --argjson behind "$behind" \
      --arg pending "$pending_groups" \
      --argjson unsaved "$n_unsaved" --argjson incoming "$n_incoming" \
      '{initialized:true, brief:true, branch:$branch, remote:$remote,
        dirty:$dirty, untracked:$untracked, ahead:$ahead, behind:$behind,
        unsaved:$unsaved, incoming:$incoming,
        pending:$pending}'
    return 0
  fi
  if (( json )); then
    local configs_json secrets_json settings_json categories_json groups_json machines_json pending_reinstalls_json
    configs_json=$(build_configs_json)
    secrets_json=$(build_secrets_json)
    settings_json=$(build_settings_json)
    categories_json=$(build_categories_json)
    groups_json=$(build_setting_groups_json)
    pending_reinstalls_json=$(build_pending_reinstalls_json)
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
      --arg home "$HOME" \
      --arg last_save "$last_save" --arg last_subject "$last_subject" \
      --argjson dirty "$dirty" --argjson untracked "$untracked" --argjson ahead "$ahead" --argjson behind "$behind" \
      --argjson unsaved "$n_unsaved" --argjson incoming "$n_incoming" \
      --arg pending "$pending_groups" --argjson configs "$configs_json" --argjson secrets "$secrets_json" \
      --argjson settings "$settings_json" --argjson categories "$categories_json" \
      --argjson setting_groups "$groups_json" --argjson machines "$machines_json" \
      --arg profile "$(current_profile)" --argjson profiles "$profiles_json" \
      --argjson pending_reinstalls "$pending_reinstalls_json" \
      '{initialized:true, branch:$branch, remote:$remote, remote_name:$remote_name,
        repo_dir:$repo_dir, machine:$machine, plugin_version:$plugin_version, home:$home,
        profile:$profile, profiles:$profiles,
        last_save:$last_save, last_subject:$last_subject,
        dirty:$dirty, untracked:$untracked, ahead:$ahead, behind:$behind, pending:$pending,
        unsaved:$unsaved, incoming:$incoming,
        configs:$configs, secrets:$secrets, settings:$settings,
        categories:$categories, setting_groups:$setting_groups, machines:$machines,
        pending_reinstalls:$pending_reinstalls}'
  else
    echo "branch: $branch"
    echo "remote: ${remote:-<none>}"
    echo "dirty: $dirty pending:$pending_groups ahead/behind: $ahead/$behind"
    # The two lines someone reading this in a terminal is actually looking for,
    # and the button each one asks for.
    (( n_unsaved > 0 ))  && echo "$(plural "$n_unsaved" file) changed here and not saved — 'savegame --auto'"
    (( n_incoming > 0 )) && echo "$(plural "$n_incoming" file) came from another machine — 'restore --apply'"
    if (( dirty > 0 )); then git -C "$REPO_DIR" status --short 2>/dev/null | head -n 30; fi
  fi
}

# resolve_manifest_src <repo-relative-id> — the real file on this machine that
# a tracked id refers to ("hypr/input.lua" -> ~/.config/hypr/input.lua). Lives
# here rather than in the CLI so the CLI, the diff view and the panel all agree
# on one answer. Auto-detected entries are in TRACKED like any other.
resolve_manifest_src() {
  local id="$1" entry rel
  for entry in "${TRACKED[@]}" "${TRACKED_SECRETS[@]}"; do
    rel="${entry##*:}"
    [[ "$rel" == "$id" ]] && { printf '%s\n' "${entry%%:*}"; return 0; }
  done
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
    *.pub) echo 644; return ;;
    ssh/config) echo 600; return ;;
  esac
  # Anything the repo holds as a secret is restored as one, whatever it is
  # called. Keying on the name alone put a tracked API token back at 644.
  is_secret_rel "$1" && { echo 600; return; }
  case "$1" in
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
  # A settings plugin that writes a Hyprland module keeps its own store: the
  # OmaSettings window writes hypr/omasettings.lua from plugins/omasettings.json.
  # Restoring Hyprland alone brought the module back without the store, so the
  # plugin's window showed the old values, and its next write put them back.
  if [[ "$want" == "hyprland" ]]; then
    local mrel prel psrc
    for entry in "${TRACKED[@]}"; do
      mrel="${entry##*:}"
      [[ "$mrel" == hypr/*.lua ]] || continue
      prel="plugins/${mrel##*/}"; prel="${prel%.lua}.json"
      psrc=$(resolve_manifest_src "$prel") || continue
      is_excluded "$prel" && continue
      repo_path=$(repo_path_for "$prel")
      [[ -f "$repo_path" ]] || continue
      printf '%s|%s|%s\n' "$repo_path" "$psrc" "$(restore_mode_for "$prel")"
    done
  fi
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
  # Outside $HOME needs root. install_file failed there on the permission.
  # root_apply asks through pkexec or passwordless sudo, runs the apply step
  # in the same call, and otherwise prints the command and fails.
  if [[ "$src" != "$HOME"/* ]]; then
    root_apply "$src" "$repo_path" "$(apply_for_category "$(category_for_rel "$rel")")"
    return
  fi
  DRY=0 install_file "$repo_path" "$src" "$mode"
  local apply; apply=$(apply_for_category "$(category_for_rel "$rel")")
  [[ -n "$apply" ]] && bash -c "$apply" >/dev/null 2>&1 || true
  return 0
}

# core_undo <rel> — put the newest .bak.<epoch> back, and take the version it
# replaces as the new backup.
#
# A SWAP, not a restore, and that is the whole design. Rule 2 says every write to
# the real machine keeps what it overwrote; obeying it naively here would leave a
# second backup behind on every undo, so undoing twice grows the pile it exists
# to drain. Consuming the backup and writing one in its place obeys the rule and
# stays at net zero — and it means undo can be undone, which is the one thing
# anybody pressing it wants to be sure of.
#
# It deliberately does NOT run the category's apply step. `restore-file` does,
# because it is putting the saved setup back; undo is "that was wrong, give me
# the previous minute" and reloading Hyprland from under a user who has just
# realised they made a mistake is not a favour. The caller says what to run.
core_undo() {
  local rel="$1" src line b epoch tmp now
  src=$(resolve_manifest_src "$rel") || { echo "unknown id: $rel" >&2; return 1; }
  src="${src%/}"
  line=$(list_backups "$rel" | head -1)
  [[ -n "$line" ]] || { echo "no .bak.<epoch> next to $rel — nothing to undo" >&2; return 1; }
  IFS=$'\t' read -r _ _ b epoch _ <<<"$line"
  [[ -e "$b" ]] || { echo "the backup named for $rel is gone: $b" >&2; return 1; }
  now=$(date +%s)
  # An epoch-named path this second is already taken if you undo twice inside one
  # second, which the tests do. Make it unique rather than silently clobbering
  # the very thing this function promises to keep.
  tmp="$src.bak.$now"
  while [[ -e "$tmp" ]]; do now=$((now + 1)); tmp="$src.bak.$now"; done
  if [[ -e "$src" ]]; then
    run mv -T -- "$src" "$tmp" || return 1
    skip "${src/#$HOME/\~} — the version you are replacing is now .bak.$now"
  fi
  run mv -T -- "$b" "$src" || return 1
  ok "${src/#$HOME/\~} restored from .bak.$epoch"
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
PLUGIN_SOURCE_ROOTS=("$HOME/Projects" "$HOME/src" "$HOME/code" "$HOME/projects" "$HOME/git" "$HOME/work")

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

# cloned_plugins — ids whose only origin is `omarchy plugin clone <built-in>`.
#
# These have a recorded origin, so local_only_plugins never names them and
# doctor reported "every installed plugin can be reinstalled from its origin" —
# which is true of the plugin and false of the work in it. `clone` reinstalls
# the BUILT-IN; a clone exists because somebody edited it, and the edits are the
# whole reason it is there. On the machine this was written on that was one
# hand-written indicator and a Matrix-rain lock screen, shader and all, existing
# nowhere else on earth.
#
# No diff against the built-in: `clone` means edited by construction, the built-in
# lives at a path this function would have to go hunting for, and a check that
# can be wrong about whether your work is backed up is worse than one that always
# tells you where it stands. Same answer as a hand-made theme — track the
# directory.
cloned_plugins() {
  local pmf pid pdir porigin pmethod
  for pmf in "$HOME/.config/omarchy/plugins"/*/manifest.json; do
    [[ -f "$pmf" ]] || continue
    pdir="$(dirname "$pmf")"
    pid=$(jq -r '.id // empty' "$pmf" 2>/dev/null) || continue
    [[ -n "$pid" ]] || continue
    IFS=$'\t' read -r porigin pmethod < <(resolve_plugin_origin "$pdir" "$pid" "$pmf")
    # A third column: the command that regenerates this clone, if it says so.
    # `omarchy plugin clone` produces a directory nobody owns, but a pack can
    # own one — omarchy-matrix derives its lock screen from Omarchy's current
    # source on every update precisely so a frozen copy cannot fall behind.
    # Backing that up is worse than not: you freeze the thing it exists to avoid.
    # The convention is `omarchy.derivedBy` in the clone's manifest, naming the
    # command; anything else is hand-made and on its own.
    local pderiv
    pderiv=$(jq -r '.omarchy.derivedBy // empty' "$pmf" 2>/dev/null || true)
    [[ "$pmethod" == "clone" ]] && printf '%s\t%s\t%s\n' "$pid" "$pdir" "$pderiv"
  done
  # The loop's last `&&` decides the exit status, so a run whose final plugin is
  # not a clone "failed" — and under the CLI's `set -e` that killed doctor in
  # the middle, silently, still exiting 0 through a pipe. Same shape as the
  # `grep -q` under pipefail trap: an incidental status read as an error.
  return 0
}

# edited_plugins — "id<TAB>dir<TAB>uncommitted<TAB>local-commits" for every
# installed plugin whose checkout holds work its origin does not have.
#
# The same hole as a clone, behind an origin that looks fine: install-plugin on
# the other machine fetches the ORIGIN's code, so an edit made in place, or a
# commit never pushed, does not come back. Omaplug sorts plugins the same way
# before it offers an update ("local changes").
#
# Offline on purpose: upstream is what the last fetch knew, the remote refs and
# FETCH_HEAD both. Doctor has no business touching the network for every plugin.
# `--no-optional-locks`: the shell watches every plugin directory for writes
# and reloads the plugin on one, and a plain `git status` can rewrite the index.
# A symlinked plugin is a development checkout, the project's business rather
# than the backup's, and Omaplug treats it the same way.
edited_plugins() {
  local pmf pdir pid dirty ahead
  local -a upstream
  for pmf in "$HOME/.config/omarchy/plugins"/*/manifest.json; do
    [[ -f "$pmf" ]] || continue
    pdir="${pmf%/manifest.json}"
    [[ -L "$pdir" || ! -d "$pdir/.git" ]] && continue
    git -C "$pdir" remote get-url origin >/dev/null 2>&1 || continue
    pid=$(jq -r '.id // empty' "$pmf" 2>/dev/null)
    [[ -n "$pid" ]] || continue
    dirty=$(git --no-optional-locks -C "$pdir" status --porcelain --untracked-files=normal 2>/dev/null | grep -c . || true)
    # FETCH_HEAD counts as upstream. `omarchy plugin update` fetches `origin
    # HEAD` into FETCH_HEAD and fast-forwards to it, and never moves
    # refs/remotes: a plugin updated that way looked 36 commits ahead.
    upstream=(--remotes)
    git -C "$pdir" rev-parse -q --verify FETCH_HEAD >/dev/null 2>&1 && upstream+=(FETCH_HEAD)
    ahead=$(git -C "$pdir" rev-list --count HEAD --not "${upstream[@]}" 2>/dev/null || echo 0)
    (( dirty > 0 || ahead > 0 )) || continue
    # HEAD can be behind while the files already match a commit upstream.
    # Porcelain then counts every difference to HEAD as an edit, and doctor
    # called such a plugin "14 uncommitted changes". Files that match an
    # upstream commit hold no work of their own.
    upstream_tree_matches "$pdir" && continue
    printf '%s\t%s\t%s\t%s\n' "$pid" "$pdir" "$dirty" "$ahead"
  done
  return 0
}

# tree_matches_commit <dir> <commit>: are the files of the checkout exactly
# the files of that commit, untracked files included? A temporary index is
# built from the commit, so the checkout's own index is never written. The
# shell reloads a plugin on any write under its directory.
tree_matches_commit() {
  local dir="$1" commit="$2" idx rc=1
  idx=$(mktemp) || return 1
  if GIT_INDEX_FILE="$idx" git -C "$dir" read-tree "$commit" 2>/dev/null \
     && GIT_INDEX_FILE="$idx" git --no-optional-locks -C "$dir" diff --quiet 2>/dev/null \
     && [[ -z "$(GIT_INDEX_FILE="$idx" git --no-optional-locks -C "$dir" ls-files --others --exclude-standard 2>/dev/null)" ]]; then
    rc=0
  fi
  rm -f "$idx"
  return "$rc"
}

# upstream_tree_matches <dir>: do the files match FETCH_HEAD or the tip of any
# remote branch? Offline, like edited_plugins: it asks only what the last
# fetch knew.
upstream_tree_matches() {
  local dir="$1" tip
  local -a tips=()
  mapfile -t tips < <({ git -C "$dir" rev-parse -q --verify FETCH_HEAD 2>/dev/null
                       git -C "$dir" for-each-ref --format='%(objectname)' refs/remotes 2>/dev/null; } | sort -u)
  for tip in ${tips[@]+"${tips[@]}"}; do
    tree_matches_commit "$dir" "$tip" && return 0
  done
  return 1
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

# core_install_theme <name> — install ONE third-party theme from its recorded
# origin, on demand. Never called automatically: `restore` only ever reports
# a theme as pending (see restore_themes in the CLI) and this is the explicit
# action that actually fetches whatever is at that origin right now.
#
# Two machines can record the same theme name with two different origins. A
# name alone then does not say which address the user agreed to, so this
# refuses and prints both rather than install the first match it finds.
core_install_theme() {
  local want="${1:-}" tname torigin
  local -a origins=()
  [[ -n "$want" ]] || { echo "usage: install-theme <name>" >&2; return 1; }
  while IFS=$'\t' read -r tname torigin; do
    [[ "$tname" == "$want" ]] || continue
    origins+=("$torigin")
  done < <(missing_themes)
  local -a unique_origins=()
  if (( ${#origins[@]} > 0 )); then
    mapfile -t unique_origins < <(printf '%s\n' "${origins[@]}" | sort -u)
  fi
  if (( ${#unique_origins[@]} == 0 )); then
    echo "$want is not a pending third-party theme (already installed, or not in the inventory)" >&2
    return 1
  fi
  if (( ${#unique_origins[@]} > 1 )); then
    echo "$want is recorded with more than one origin — refusing to guess which one to install:" >&2
    printf '  %s\n' "${unique_origins[@]}" >&2
    return 1
  fi
  command -v omarchy >/dev/null 2>&1 || { echo "omarchy not found on PATH" >&2; return 1; }
  omarchy theme install "${unique_origins[0]}" || { echo "$want — omarchy theme install failed (${unique_origins[0]})" >&2; return 1; }
  echo "$want installed from ${unique_origins[0]} — this also makes it the active theme" >&2
}

# ─── What the marketplace checked, asked only when a person installs ───────
# Omaplug reads the same catalog fields. The catalog is 7.6 MB, so it is
# fetched at most once an hour, and never by the status poll: only when a
# person asks to install a plugin. It informs and never refuses, because
# `omarchy plugin add` takes no commit to pin to.
MARKETPLACE_CATALOG_URL="${REPLICANT_CATALOG_URL:-https://plugins.omarchy.org/catalog.json}"
CATALOG_CACHE="$REPLICANT_HOME/catalog.json"
CATALOG_MAX_AGE=3600

# marketplace_catalog: print the path of a catalog no older than an hour.
marketplace_catalog() {
  local tmp age
  if [[ -f "$CATALOG_CACHE" ]]; then
    age=$(( $(date +%s) - $(stat -c %Y "$CATALOG_CACHE" 2>/dev/null || echo 0) ))
    if (( age < CATALOG_MAX_AGE )); then printf '%s\n' "$CATALOG_CACHE"; return 0; fi
  fi
  mkdir -p "$REPLICANT_HOME" 2>/dev/null || return 1
  tmp=$(mktemp "$REPLICANT_HOME/catalog.XXXXXX") || return 1
  if curl -fsSL --max-time 20 -o "$tmp" "$MARKETPLACE_CATALOG_URL" 2>/dev/null \
     && jq -e '.plugins | type == "array"' "$tmp" >/dev/null 2>&1; then
    mv -f "$tmp" "$CATALOG_CACHE"
  else
    rm -f "$tmp"
  fi
  [[ -f "$CATALOG_CACHE" ]] || return 1
  printf '%s\n' "$CATALOG_CACHE"
}

normalize_repo_url() { printf '%s\n' "$1" | sed -E 's#\.git$##; s#/$##' | tr '[:upper:]' '[:lower:]'; }

# core_plugin_verification <id> [origin]: the marketplace status of a plugin,
# and where its origin is now, as plain facts on stdout. The origin is asked
# only when the catalog names a commit to compare it with.
core_plugin_verification() {
  local id="$1" origin="${2:-}" catalog entry vstatus vcommit now
  [[ -n "$origin" ]] || origin=$(missing_plugins | awk -F'\t' -v i="$id" '$1 == i { print $2; exit }')
  if ! catalog=$(marketplace_catalog); then
    echo "Marketplace: the catalog could not be read (offline?)."
    return 0
  fi
  entry=$(jq -c --arg id "$id" --arg repo "$(normalize_repo_url "${origin:-none}")" '
    [.plugins[] | select(.id == $id or ((.repo // "") | ascii_downcase
      | sub("\\.git$"; "") | sub("/$"; "")) == $repo)][0] // empty' "$catalog" 2>/dev/null)
  if [[ -z "$entry" ]]; then
    echo "Marketplace: $id is not listed."
    return 0
  fi
  vstatus=$(jq -r '.verificationStatus // "unknown"' <<<"$entry")
  vcommit=$(jq -r '.verificationCommit // .listingValidatedCommit // ""' <<<"$entry")
  echo "Marketplace: $id is listed as $vstatus${vcommit:+, checked at ${vcommit:0:12}}."
  [[ -n "$vcommit" && -n "$origin" && "$origin" != "-" ]] || return 0
  now=$(timeout 15 git ls-remote "$origin" HEAD 2>/dev/null | awk 'NR == 1 { print $1 }')
  if [[ -z "$now" ]]; then
    echo "Origin: $origin could not be reached."
  elif [[ "$now" == "$vcommit" ]]; then
    echo "Origin: $origin is still at the commit that the marketplace checked."
  else
    echo "Origin: $origin is at ${now:0:12} now. It has moved since the marketplace checked it."
  fi
}

# core_install_plugin <id> — the same action for a plugin. `missing_plugins`
# already carries the method column that tells clone (an edited built-in)
# from add (a real third-party plugin) — same two commands restore_plugins
# already knew how to call, just no longer called without being asked.
# Ambiguity is refused here too, on the origin and the method together.
core_install_plugin() {
  local want="${1:-}" pid porigin pmethod
  local -a pairs=()
  [[ -n "$want" ]] || { echo "usage: install-plugin <id>" >&2; return 1; }
  while IFS=$'\t' read -r pid porigin pmethod; do
    [[ "$pid" == "$want" ]] || continue
    pairs+=("$porigin"$'\t'"$pmethod")
  done < <(missing_plugins)
  local -a unique_pairs=()
  if (( ${#pairs[@]} > 0 )); then
    mapfile -t unique_pairs < <(printf '%s\n' "${pairs[@]}" | sort -u)
  fi
  if (( ${#unique_pairs[@]} == 0 )); then
    echo "$want is not a pending third-party plugin (already installed, or not in the inventory)" >&2
    return 1
  fi
  if (( ${#unique_pairs[@]} > 1 )); then
    echo "$want is recorded with more than one origin — refusing to guess which one to install:" >&2
    printf '  %s\n' "${unique_pairs[@]}" | sed 's/\t/ (method: /; s/$/)/' >&2
    return 1
  fi
  local origin="${unique_pairs[0]%%$'\t'*}" method="${unique_pairs[0]#*$'\t'}"
  command -v omarchy >/dev/null 2>&1 || { echo "omarchy not found on PATH" >&2; return 1; }
  # A clone copies Omarchy's own built-in, which has no marketplace entry.
  [[ "$method" == "clone" ]] || core_plugin_verification "$want" "$origin" >&2
  if [[ "$method" == "clone" ]]; then
    omarchy plugin clone "$origin" || { echo "$want — omarchy plugin clone failed" >&2; return 1; }
    echo "$want re-cloned from $origin (any edits you made are not in this)" >&2
  else
    omarchy plugin add "$origin" --enable --yes || { echo "$want — omarchy plugin add failed" >&2; return 1; }
    echo "$want installed from $origin" >&2
  fi
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
  # Not a name test. A user can track any file as a secret, under any name, and
  # the refusal has to follow the entry rather than the spelling.
  if [[ "$id" != *.pub ]] && is_secret_rel "$id"; then
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
    return 0
  fi
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
  repo_copy=$(repo_copy_for_rel "$id")
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
  # Runs of the same subject collapse into one row with a count. A save writes
  # an inventory commit whenever a package list moved, so four of the six rows
  # said "state: … inventory" and the two that recorded a decision the user
  # actually made were what fell off the bottom. Read more than we show, so
  # collapsing lengthens the history instead of shortening the list.
  git -C "$REPO_DIR" log -n "$(( n * 4 ))" --date=format:'%d %b %H:%M' \
      --pretty=format:'%H%x1f%ad%x1f%s%x1f%an' 2>/dev/null |
    jq -Rsc --argjson n "$n" 'split("\n") | map(select(length > 0) | split("\u001f")
             | {sha: .[0][0:7], date: .[1], subject: .[2], author: .[3], count: 1})
             | reduce .[] as $c ([];
                 if (length > 0 and .[-1].subject == $c.subject)
                 then .[0:-1] + [.[-1] * {count: (.[-1].count + 1)}]
                 else . + [$c] end)
             | .[0:$n]'
}

# Used by the omarchy-replicant CLI wrapper
# core_incoming <before-rev> <after-rev> — which tracked entries a pull moved.
# Written down for the panel and printed for the caller.
#
# It lives here rather than in the CLI for the reason everything else does: the
# mapping from a repo path back to the row a person can press a button on is
# business logic, and owning_rel is the only thing that knows a file three
# levels inside a tracked directory belongs to the directory's row.
core_incoming() {
  local before="$1" after="$2" p rel
  local -a rels=()
  while IFS= read -r p; do
    case "$p" in
      config/*)            rel="${p#config/}" ;;
      secrets/*)           rel="${p#secrets/}" ;;
      # Only THIS machine's profile. profiles/laptop/... is the laptop's own copy
      # of a file that is kept per profile precisely so the two machines do not
      # share it — reporting it as incoming here would tell the desktop to
      # restore the laptop's monitor layout onto itself.
      profiles/*/config/*) rel="${p#profiles/}"
                           [[ "${rel%%/*}" == "$(current_profile)" ]] || continue
                           rel="${rel#*/config/}" ;;
      *)                   continue ;;   # state/, .replicant-*: not rows anyone acts on
    esac
    rels+=("$(owning_rel "$rel")")
  done < <(git -C "$REPO_DIR" diff --name-only "$before" "$after" 2>/dev/null)
  if (( ${#rels[@]} == 0 )); then record_incoming; return 0; fi
  local -a uniq=()
  # shellcheck disable=SC2207
  uniq=($(printf '%s\n' "${rels[@]}" | sort -u))
  record_incoming "${uniq[@]}"
  printf '%s\n' "${uniq[@]}"
}

# The commands below run only when this file is executed. A caller that sources
# it for its functions passes its own positional parameters through, so without
# this line `omarchy-replicant path machine` ran the `machine` command first.
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0

# An unknown command is an error. The chain of ifs that this replaces did
# nothing for one and exited 0, which a caller reads as success.
case "${1:-}" in
  backup)             core_backup "${2:-}" ;;
  status)             shift; core_status "$@" ;;
  diff)               core_diff "${2:-}" "${3:-auto}" ;;
  log)                core_log "${2:-8}" ;;
  shortcuts)          core_shortcuts ;;
  sync)               core_sync "${2:-}" "${3:-}" ;;
  revert)             core_revert "${2:-}" "${3:-default}" ;;
  restore-file)       core_restore_file "${2:-}" ;;
  scope)              core_scope "${2:-}" "${3:-}" ;;
  profile-set)        core_profile_set "${2:-}" ;;
  profile-get)        current_profile ;;
  profile-list)       list_profiles ;;
  local-only-plugins) local_only_plugins ;;
  cloned-plugins)     cloned_plugins ;;
  edited-plugins)     edited_plugins ;;
  hypr-unresolved)    unresolved_hypr_modules ;;
  repo-path)          repo_copy_for_rel "${2:-}" ;;
  local-only-themes)  local_only_themes ;;
  track)              shift; core_track "$@" ;;
  untrack)            core_untrack "${2:-}" ;;
  suggest)            core_suggest "${2:-}" ;;
  incoming)           core_incoming "${2:-}" "${3:-}" ;;
  backups)            list_backups "${2:-}" ;;
  backups-json)       build_backups_json ;;
  undo)               core_undo "${2:-}" ;;
  machine)            printf '%s\n' "$MACHINE" ;;
  *)                  echo "replicant-core.sh: unknown command '${1:-}'" >&2; exit 2 ;;
esac
