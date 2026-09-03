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
STATE_DIR="$REPO_DIR/state"
TEMPLATES_DIR="$REPO_DIR/templates"
GITHOOKS_DIR="$REPO_DIR/.githooks"

# ─── MANIFEST — ported from ~/omarchy_thinkpad/bin/backup.sh ────────────────
# One-way direction: system -> repo. Only your own stuff, or what differs from default.
# Anything identical to the default isn't tracked: recover it with omarchy-refresh-config.
MANIFEST=(
  "$HOME/.bashrc:home/bashrc"
  "$HOME/.XCompose:home/XCompose"
  "$HOME/.ssh/config:ssh/config"
  "$HOME/.config/git/config:git/config"
  "$HOME/.claude/settings.json:claude/settings.json"
  "$HOME/.claude/settings.local.json:claude/settings.local.json"
  "$HOME/.claude/hooks/cbm-code-discovery-gate:claude/hooks/cbm-code-discovery-gate"
  "$HOME/.claude/hooks/cbm-session-reminder:claude/hooks/cbm-session-reminder"
  "$HOME/.claude/hooks/cbm-subagent-reminder:claude/hooks/cbm-subagent-reminder"
  "$HOME/.claude/.mcp.json:claude/mcp.json"
  "$HOME/.config/Code/User/settings.json:vscode/settings.json"
  "$HOME/.config/mise/config.toml:mise/config.toml"
  "$HOME/.config/hypr/input.lua:hypr/input.lua"
  "$HOME/.config/hypr/looknfeel.lua:hypr/looknfeel.lua"
  "$HOME/.config/hypr/monitors.lua:hypr/monitors.lua"
  "$HOME/.config/hypr/autostart.lua:hypr/autostart.lua"
  "$HOME/.config/uwsm/env.d/50-local-bin-priority.sh:uwsm/env.d/50-local-bin-priority.sh"
  "$HOME/.config/xdg-terminals.list:xdg-terminals.list"
  "$HOME/.config/opencode/opencode.json:opencode/opencode.json"
  "$HOME/.config/opencode/tui.json:opencode/tui.json"
  "$HOME/.config/opencode/AGENTS.md:opencode/AGENTS.md"
  "$HOME/dev/mise.toml:dev/mise.toml"
  "$HOME/.local/bin/hypr-refresh-auto:bin/hypr-refresh-auto"
  "$HOME/.config/omarchy/branding/screensaver.txt:branding/screensaver.txt"
  "$HOME/.local/bin/omarchy-audit:bin/omarchy-audit"
  "$HOME/.config/omarchy-audit-ignore:omarchy-audit-ignore"
  "$HOME/.config/omarchy/hooks/post-update.d/audit-config.hook:omarchy/hooks/post-update.d/audit-config.hook"
  "$HOME/.config/omarchy/shell.json:omarchy/shell.json"
  "$HOME/.config/omarchy/shell.toml:omarchy/shell.toml"
  # Outside ~/.config, but they are what makes a machine look like yours:
  # the active theme's name and the editor Omarchy opens config files with.
  # theme.name is restored by re-running `omarchy theme set`, not by copying
  # the file back (see the "theme" group in cmd_restore).
  "$HOME/.local/state/omarchy/current/theme.name:omarchy/theme.name"
  "$HOME/.local/state/omarchy/defaults/editor:omarchy/defaults/editor"
  "$HOME/.config/alacritty/alacritty.toml:alacritty/alacritty.toml"
  "$HOME/.config/foot/foot.ini:foot/foot.ini"
  "/etc/systemd/system/fprintd-resume.service:etc/fprintd-resume.service"
  "/etc/systemd/logind.conf.d/99-lid.conf:etc/99-lid.conf"
  "/etc/systemd/sleep.conf.d/99-hibernate-delay.conf:etc/99-hibernate-delay.conf"
  # v2 extra: the replicant plugin itself (so the plugin survives a reinstall)
  "$HOME/.config/omarchy/plugins/io.github.tymurbogach.omarchy-replicant/manifest.json:omarchy-plugin/manifest.json"
  "$HOME/.config/omarchy/plugins/io.github.tymurbogach.omarchy-replicant/BarWidget.qml:omarchy-plugin/BarWidget.qml"
  "$HOME/.config/omarchy/plugins/io.github.tymurbogach.omarchy-replicant/Panel.qml:omarchy-plugin/Panel.qml"
  "$HOME/.config/omarchy/plugins/io.github.tymurbogach.omarchy-replicant/Service.qml:omarchy-plugin/Service.qml"
)

SECRETS_MANIFEST=(
  "$HOME/.ssh/id_ed25519:ssh/id_ed25519"
  "$HOME/.ssh/id_ed25519.pub:ssh/id_ed25519.pub"
  "$HOME/.config/environment.d/60-secrets.conf:env/60-secrets.conf"
  "$HOME/dev/portfolio/.env:env/portfolio.env"
  "$HOME/dev/lazytripz/backend/.env:env/lazytrip-backend.env"
)

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

ensure_repo_layout() {
  mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$TEMPLATES_DIR"
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
  for entry in "${MANIFEST[@]}"; do
    src=${entry%%:*}
    dst="$CONFIG_DIR/${entry##*:}"
    if [[ -f $src ]]; then
      mkdir -p "$(dirname "$dst")"
      cp -f "$src" "$dst"
      ((copied++)) || true
    else
      echo "  · missing: ${src/#$HOME/\~}" >&2
      ((missing++)) || true
    fi
  done
  echo "  $copied copied, $missing missing" >&2

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

  echo "→ Copying secrets (private repo, 600)" >&2
  install -d -m 700 "$SECRETS_DIR" 2>/dev/null || true
  scopied=0
  for entry in "${SECRETS_MANIFEST[@]}"; do
    src=${entry%%:*}
    dst="$SECRETS_DIR/${entry##*:}"
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
# ("default" vs "modified"), Diff (there is nothing to diff against without
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
# Format: "id|group|file|path|type|label|unit|min|max|options|hint|apply|fallback"
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
#   min/max  numeric types only
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
#            value is inherited rather than written down anywhere.
#
# A setting whose file or key is missing on this machine reads as null and the
# panel greys the control out. That is the intended behaviour, not an error:
# these files are the user's own and no two machines carry the same keys.
SETTINGS=(
  # ── Idle & power — ~/.config/omarchy/shell.json, watched live by the shell
  "idle.screensaver|Idle & power|$HOME/.config/omarchy/shell.json|.idle.screensaver|number|Screensaver|s|10|3600||Idle time before the screensaver starts||"
  "idle.lock|Idle & power|$HOME/.config/omarchy/shell.json|.idle.lock|number|Lock screen|s|10|7200||Idle time before the screen locks||"
  "idle.lazyDpms|Idle & power|$HOME/.config/omarchy/shell.json|.idle.lazyDpms|number|Turn off display|s|10|7200||Idle time before the display powers down||"
  "idle.lazySuspendAc|Idle & power|$HOME/.config/omarchy/shell.json|.idle.lazySuspendAc|number|Suspend on AC|s|0|14400||Idle time before suspending on AC power (0 = never)||"
  "idle.lazySuspendBatt|Idle & power|$HOME/.config/omarchy/shell.json|.idle.lazySuspendBatt|number|Suspend on battery|s|0|14400||Idle time before suspending on battery (0 = never)||"
  # ── Appearance
  "theme.current|Appearance|-|-|theme|Theme|||||The theme applied to the shell, terminals and editor||"
  "bar.position|Appearance|$HOME/.config/omarchy/shell.json|.bar.position|enum|Bar position||||top,bottom,left,right|Which screen edge the status bar sits on||"
  "bar.transparent|Appearance|$HOME/.config/omarchy/shell.json|.bar.transparent|bool|Transparent bar|||||Let the wallpaper show through the bar||"
  "font.baseSize|Appearance|$HOME/.config/omarchy/shell.toml|font.base-size|toml-int|Interface font size|pt|8|32||Base size every bar, menu and panel font derives from||12"
  "spacing.scale|Appearance|$HOME/.config/omarchy/shell.toml|spacing.scale|toml-float|Interface density|×|0.5|2||Multiplies every margin, gap and control size||1.0"
  "bar.sizeHorizontal|Appearance|$HOME/.config/omarchy/shell.toml|bar.size-horizontal|toml-int|Bar thickness (top/bottom)|px|16|80||Height of the bar when it sits on a horizontal edge; setting it stops the bar scaling with the font||26"
  "bar.sizeVertical|Appearance|$HOME/.config/omarchy/shell.toml|bar.size-vertical|toml-int|Bar thickness (left/right)|px|16|120||Width of the bar when it sits on a vertical edge; setting it stops the bar scaling with the font||28"
  # ── Input — Hyprland reads Lua at startup, so these need an explicit reload
  "input.repeatRate|Input|$HOME/.config/hypr/input.lua|repeat_rate|lua-int|Key repeat rate|/s|1|100||Characters a held key sends per second|hyprctl reload|"
  "input.repeatDelay|Input|$HOME/.config/hypr/input.lua|repeat_delay|lua-int|Key repeat delay|ms|100|2000||How long a key is held before it starts repeating|hyprctl reload|"
  "input.kbLayout|Input|$HOME/.config/hypr/input.lua|kb_layout|lua-enum|Keyboard layout||||es,us,gb,de,fr,it,pt,latam|X11 layout code for the keyboard|hyprctl reload|"
  "input.naturalScroll|Input|$HOME/.config/hypr/input.lua|natural_scroll|lua-bool|Natural scrolling|||||Touchpad: two fingers down moves the page up|hyprctl reload|"
  "input.tapToClick|Input|$HOME/.config/hypr/input.lua|tap_to_click|lua-bool|Tap to click|||||Touchpad: a tap counts as a click|hyprctl reload|"
  "input.disableWhileTyping|Input|$HOME/.config/hypr/input.lua|disable_while_typing|lua-bool|Ignore touchpad while typing|||||Stops the cursor jumping mid-sentence|hyprctl reload|"
  # ── Defaults
  "default.editor|Defaults|$HOME/.local/state/omarchy/defaults/editor|-|line-enum|Default editor||||nvim,code,hx,micro,nano,zed|Editor Omarchy opens config files with||"
)

SETTING_GROUP_ORDER=("Idle & power" "Appearance" "Input" "Defaults")

setting_field() { printf '%s' "$1" | cut -d'|' -f"$2"; }

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
    enum|lua-enum|line-enum|theme)
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

build_settings_json() {
  local entries=()
  local entry id group file path type label unit min max options hint value opts_json available fallback implicit
  for entry in "${SETTINGS[@]}"; do
    id=$(setting_field "$entry" 1);      group=$(setting_field "$entry" 2)
    file=$(setting_field "$entry" 3);    path=$(setting_field "$entry" 4)
    type=$(setting_field "$entry" 5);    label=$(setting_field "$entry" 6)
    unit=$(setting_field "$entry" 7);    min=$(setting_field "$entry" 8)
    max=$(setting_field "$entry" 9);     hint=$(setting_field "$entry" 11)
    fallback=$(setting_field "$entry" 13)
    options=$(setting_options "$entry")
    value=$(get_setting_value "$id" 2>/dev/null) || value=""
    if [[ -n "$options" ]]; then opts_json=$(printf '%s' "$options" | jq -Rc 'split(",")'); else opts_json='[]'; fi
    implicit=false
    if [[ -z "$value" && -n "$fallback" ]]; then value="$fallback"; implicit=true; fi
    if [[ -n "$value" ]]; then available=true; else available=false; fi
    case "$type" in
      number|toml-int|lua-int)
        [[ "$value" =~ ^-?[0-9]+$ ]] || { value=""; available=false; }
        entries+=("$(jq -nc --arg id "$id" --arg group "$group" --arg label "$label" --arg type "$type" --arg unit "$unit" \
          --argjson min "${min:-null}" --argjson max "${max:-null}" --argjson options "$opts_json" \
          --arg hint "$hint" --arg file "$file" --argjson available "$available" --argjson implicit "$implicit" --argjson value "${value:-null}" \
          '{id:$id,group:$group,label:$label,type:$type,unit:$unit,min:$min,max:$max,options:$options,hint:$hint,file:$file,available:$available,implicit:$implicit,value:$value}')")
        ;;
      toml-float)
        [[ "$value" =~ ^-?[0-9]*\.?[0-9]+$ ]] || { value=""; available=false; }
        entries+=("$(jq -nc --arg id "$id" --arg group "$group" --arg label "$label" --arg type "$type" --arg unit "$unit" \
          --argjson min "${min:-null}" --argjson max "${max:-null}" --argjson options "$opts_json" \
          --arg hint "$hint" --arg file "$file" --argjson available "$available" --argjson implicit "$implicit" --argjson value "${value:-null}" \
          '{id:$id,group:$group,label:$label,type:$type,unit:$unit,min:$min,max:$max,options:$options,hint:$hint,file:$file,available:$available,implicit:$implicit,value:$value}')")
        ;;
      bool|lua-bool)
        [[ "$value" == "true" || "$value" == "false" ]] || { value="false"; available=false; }
        entries+=("$(jq -nc --arg id "$id" --arg group "$group" --arg label "$label" --arg type "$type" --arg unit "$unit" \
          --argjson min null --argjson max null --argjson options "$opts_json" \
          --arg hint "$hint" --arg file "$file" --argjson available "$available" --argjson implicit "$implicit" --argjson value "$value" \
          '{id:$id,group:$group,label:$label,type:$type,unit:$unit,min:$min,max:$max,options:$options,hint:$hint,file:$file,available:$available,implicit:$implicit,value:$value}')")
        ;;
      *)
        entries+=("$(jq -nc --arg id "$id" --arg group "$group" --arg label "$label" --arg type "$type" --arg unit "$unit" \
          --argjson min null --argjson max null --argjson options "$opts_json" \
          --arg hint "$hint" --arg file "$file" --argjson available "$available" --argjson implicit "$implicit" --arg value "${value:-}" \
          '{id:$id,group:$group,label:$label,type:$type,unit:$unit,min:$min,max:$max,options:$options,hint:$hint,file:$file,available:$available,implicit:$implicit,value:$value}')")
        ;;
    esac
  done
  printf '%s\n' "${entries[@]}" | jq -s '.'
}

build_configs_json() {
  local entries=()
  local entry src dst rel label group exists is_default
  for entry in "${MANIFEST[@]}"; do
    src="${entry%%:*}"
    rel="${entry##*:}"
    label="$rel"
    # group by prefix
    case "$rel" in
      home/*) group="shell" ;;
      ssh/*|git/*) group="git/ssh" ;;
      claude/*) group="claude" ;;
      hypr/*) group="hypr" ;;
      uwsm/*|xdg-terminals*) group="session" ;;
      omarchy/theme.name|omarchy/defaults/*) group="appearance" ;;
      omarchy/*|omarchy-audit*|branding/*) group="omarchy" ;;
      alacritty*|foot*|kitty*|ghostty*) group="terminal" ;;
      opencode*|mise*|vscode*|dev/*) group="dev" ;;
      bin/*) group="scripts" ;;
      etc/*) group="system" ;;
      omarchy-plugin/*) group="replicant" ;;
      *) group="other" ;;
    esac
    if [[ -f "$src" ]]; then exists=true; else exists=false; fi
    local default_src="" has_default=false config_rel=""
    if default_src=$(default_for_src "$src"); then has_default=true; fi
    config_rel=$(config_rel_for_src "$src" 2>/dev/null || true)
    if [[ -f "$src" && "$has_default" == true ]] && cmp -s "$src" "$default_src" 2>/dev/null; then is_default=true; else is_default=false; fi
    # does the repo have uncommitted changes for this rel (vs. the last local commit)?
    local dirty=false
    if git -C "$REPO_DIR" status --porcelain -- "config/$rel" 2>/dev/null | grep -q .; then dirty=true; fi
    # is that rel's last local commit not on origin yet (vs. GitHub)?
    local unpushed=false
    if path_unpushed "config/$rel"; then unpushed=true; fi
    # third state: default (○ default) > modified (● changed or not pushed) > saved (◆ on GitHub)
    local sync_state
    if [[ "$is_default" == true ]]; then sync_state="default"
    elif [[ "$dirty" == true || "$unpushed" == true ]]; then sync_state="modified"
    else sync_state="saved"
    fi
    entries+=("$(jq -nc --arg id "$rel" --arg label "$label" --arg src "$src" --arg group "$group" --argjson exists "$exists" --argjson is_default "$is_default" --argjson has_default "$has_default" --arg config_rel "$config_rel" --argjson dirty "$dirty" --argjson unpushed "$unpushed" --arg sync_state "$sync_state" --arg source "manifest" '{id:$id,label:$label,src:$src,group:$group,exists:$exists,is_default:$is_default,has_default:$has_default,config_rel:$config_rel,dirty:$dirty,unpushed:$unpushed,sync_state:$sync_state,source:$source}')")
  done
  # auto-detected entries from other plugins (no known Omarchy default -> never "default")
  local psrc prel pname pdirty punpushed psync
  while IFS=$'\t' read -r psrc prel pname; do
    [[ -n "$psrc" ]] || continue
    pdirty=false
    if git -C "$REPO_DIR" status --porcelain -- "config/$prel" 2>/dev/null | grep -q .; then pdirty=true; fi
    punpushed=false
    if path_unpushed "config/$prel"; then punpushed=true; fi
    if [[ "$pdirty" == true || "$punpushed" == true ]]; then psync="modified"; else psync="saved"; fi
    entries+=("$(jq -nc --arg id "$prel" --arg label "$pname" --arg src "$psrc" --arg group "plugins" --argjson exists true --argjson is_default false --argjson has_default false --arg config_rel "omarchy/${psrc##*/}" --argjson dirty "$pdirty" --argjson unpushed "$punpushed" --arg sync_state "$psync" --arg source "auto" '{id:$id,label:$label,src:$src,group:$group,exists:$exists,is_default:$is_default,has_default:$has_default,config_rel:$config_rel,dirty:$dirty,unpushed:$unpushed,sync_state:$sync_state,source:$source}')")
  done < <(discover_plugin_entries)
  printf '%s\n' "${entries[@]}" | jq -s '.'
}

build_secrets_json() {
  local entries=()
  local entry src rel exists
  for entry in "${SECRETS_MANIFEST[@]}"; do
    src="${entry%%:*}"; rel="${entry##*:}"
    if [[ -f "$src" ]]; then exists=true; else exists=false; fi
    local dirty=false
    if git -C "$REPO_DIR" status --porcelain -- "secrets/$rel" 2>/dev/null | grep -q .; then dirty=true; fi
    entries+=("$(jq -nc --arg id "$rel" --arg src "$src" --argjson exists "$exists" --argjson dirty "$dirty" '{id:$id,src:$src,exists:$exists,dirty:$dirty}')")
  done
  printf '%s\n' "${entries[@]}" | jq -s '.'
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
    local configs_json secrets_json settings_json
    configs_json=$(build_configs_json)
    secrets_json=$(build_secrets_json)
    settings_json=$(build_settings_json)
    local remote_name=""
    [[ -n "$remote" ]] && remote_name="${remote##*/}" && remote_name="${remote_name%.git}"
    jq -nc --arg branch "$branch" --arg remote "$remote" --arg remote_name "$remote_name" --arg repo_dir "$REPO_DIR" --argjson dirty "$dirty" --argjson untracked "$untracked" --argjson ahead "$ahead" --argjson behind "$behind" --arg pending "$pending_groups" --argjson configs "$configs_json" --argjson secrets "$secrets_json" --argjson settings "$settings_json" \
      '{initialized:true, branch:$branch, remote:$remote, remote_name:$remote_name, repo_dir:$repo_dir, dirty:$dirty, untracked:$untracked, ahead:$ahead, behind:$behind, pending:$pending, configs:$configs, secrets:$secrets, settings:$settings}'
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
  for entry in "${MANIFEST[@]}" "${SECRETS_MANIFEST[@]}"; do
    rel="${entry##*:}"
    [[ "$rel" == "$id" ]] && { printf '%s\n' "${entry%%:*}"; return 0; }
  done
  while IFS=$'\t' read -r psrc prel _pname; do
    [[ "$prel" == "$id" ]] && { printf '%s\n' "$psrc"; return 0; }
  done < <(discover_plugin_entries)
  return 1
}

# core_diff <id> [default|repo|auto] — plain unified diff on stdout, for the
# panel to render inline. The panel used to shell out to a floating terminal
# for this; a diff is something you read, not something you interact with, so
# it belongs in the panel next to the file it describes.
core_diff() {
  local id="$1" against="${2:-auto}" src repo_copy def
  src=$(resolve_manifest_src "$id") || { echo "unknown id: $id"; return 1; }
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
fi
