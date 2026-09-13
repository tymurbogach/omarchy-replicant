# shellcheck shell=bash disable=SC2034
# manifest.sh: what is tracked: the shipped lists, the user's list, Omarchy's defaults and the repo version guard.
# Sourced by replicant-core.sh, which sets the paths it uses. It defines
# functions and data and runs nothing. Other modules read its data.
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

is_user_entry() {
  local rel="$1" entry
  for entry in ${USER_MANIFEST[@]+"${USER_MANIFEST[@]}"} ${USER_SECRETS[@]+"${USER_SECRETS[@]}"}; do
    [[ "${entry##*:}" == "$rel" ]] && return 0
  done
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
