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
# all. Anything personal lives in the user's own entries, inside their own
# repo, where it travels between their machines without being published to
# everybody else's.
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

# ─── THE USER'S OWN LIST ────────────────────────────────────────────────────
# Everything above ships with the plugin. Everything a particular person wants
# backed up on top of it lives in their own entries in the repo: "back up my
# audit script" is a decision about the setup, not about one machine, so
# making it once is enough for both.

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
# clients that write the version record. An already-released client that does
# not check has no protection — the honest answer is to upgrade it, and doctor
# says so.
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

rebuild_tracked() {
  TRACKED=("${MANIFEST[@]}" ${USER_MANIFEST[@]+"${USER_MANIFEST[@]}"} ${AUTO_MANIFEST[@]+"${AUTO_MANIFEST[@]}"})
  TRACKED_SECRETS=("${SECRETS_MANIFEST[@]}" ${USER_SECRETS[@]+"${USER_SECRETS[@]}"})
}

load_user_manifest() {
  USER_MANIFEST=(); USER_SECRETS=()
  if repo_is_ready; then load_user_entries || return 1; fi
  rebuild_tracked
}

# records. Config entries come from .replicant/entries.json with source
# user; secret entries come from the decrypted vault index. A locked vault
# contributes no secrets: those rows render locked from the index state, not
# from this list.
load_user_entries() {
  local id p k s o vidx
  if [[ -f "$REPO_DIR/.replicant/entries.json" ]]; then
    local rows
    rows=$(load_entries 2>/dev/null) || return 1
    while IFS=$'\t' read -r id p k s o; do
      [[ -n "${id:-}" && "$o" == user ]] || continue
      USER_MANIFEST+=("$p:$id")
    done <<<"$rows"
  fi
  vidx=$(vault_index_decrypt 2>/dev/null || true)
  if [[ -n "$vidx" ]]; then
    while IFS=$'\t' read -r id p s o; do
      [[ -n "${id:-}" && "$o" == user ]] || continue
      USER_SECRETS+=("$p:$id")
    done < <(vault_index_user_entries "$vidx")
  fi
  return 0
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
