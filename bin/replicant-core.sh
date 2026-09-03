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

is_default_file() {
  # $1 = absolute source path (e.g. $HOME/.config/hypr/input.lua or /etc/...)
  # returns 0 if identical to Omarchy's default -> "default"
  local src="$1"
  local omarchy_path="${OMARCHY_PATH:-/usr/share/omarchy}"
  local rel=""
  # maps src -> relative path under /usr/share/omarchy/config or default
  if [[ "$src" == "$HOME/.config/"* ]]; then
    rel="${src#$HOME/.config/}"
    for base in "$omarchy_path/config" "/usr/share/omarchy/config" "$omarchy_path/default" "/usr/share/omarchy/default"; do
      if [[ -f "$base/$rel" ]]; then
        cmp -s "$src" "$base/$rel" 2>/dev/null && return 0
        return 1
      fi
    done
    # no known default -> not a default (it's your own)
    return 1
  elif [[ "$src" == "/etc/"* ]]; then
    # /etc has no Omarchy default -> always personal
    return 1
  elif [[ "$src" == "$HOME/.bashrc" ]]; then
    # compare against Omarchy's default bashrc if it exists
    for base in "$omarchy_path/default/bash" "$omarchy_path/config" "/usr/share/omarchy/default/bash"; do
      [[ -f "$base/bashrc" ]] && { cmp -s "$src" "$base/bashrc" 2>/dev/null && return 0; return 1; }
    done
    return 1
  else
    return 1
  fi
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
# single field inside an already-tracked file, safe to read/write mechanically.
#
# Format: "id|file|path|type|label|unit|min|max|options|hint"
#   type    number | bool | enum   (JSON, via jq)
#           toml-number                  (TOML "key = 123" inside a [section])
#   path    jq path (".idle.lock") for JSON; "section.key" for TOML
#   min/max only for numeric types, options only for enum (comma-separated)
#   hint    one short line shown under the control in the panel
#
# Adding a setting is ONE line here — Panel.qml renders the right control for
# the type generically, so no QML changes are needed.
SETTINGS=(
  "idle.screensaver|$HOME/.config/omarchy/shell.json|.idle.screensaver|number|Screensaver|s|10|3600||Idle time before the screensaver starts"
  "idle.lock|$HOME/.config/omarchy/shell.json|.idle.lock|number|Lock screen|s|10|7200||Idle time before the screen locks"
  "idle.lazyDpms|$HOME/.config/omarchy/shell.json|.idle.lazyDpms|number|Turn off display|s|10|7200||Idle time before the display powers down"
  "idle.lazySuspendAc|$HOME/.config/omarchy/shell.json|.idle.lazySuspendAc|number|Suspend on AC|s|0|14400||Idle time before suspending on AC power (0 = never)"
  "idle.lazySuspendBatt|$HOME/.config/omarchy/shell.json|.idle.lazySuspendBatt|number|Suspend on battery|s|0|14400||Idle time before suspending on battery (0 = never)"
  "bar.position|$HOME/.config/omarchy/shell.json|.bar.position|enum|Bar position||||top,bottom|Which screen edge the status bar sits on"
  "bar.transparent|$HOME/.config/omarchy/shell.json|.bar.transparent|bool|Transparent bar|||||Let the wallpaper show through the bar"
  "font.baseSize|$HOME/.config/omarchy/shell.toml|font.base-size|toml-number|Interface font size|pt|8|32||Base font size for the bar, menus and panels"
)

setting_field() { echo "$1" | cut -d'|' -f"$2"; }

find_setting() {
  local id="$1" entry
  for entry in "${SETTINGS[@]}"; do
    [[ "$(setting_field "$entry" 1)" == "$id" ]] && { echo "$entry"; return 0; }
  done
  return 1
}

# TOML helpers — deliberately minimal: these target flat "key = value" lines
# inside a "[section]" of a small, hand-written config (shell.toml). They are
# not a TOML parser and are not meant to grow into one; anything more complex
# stays a whole-file entry in MANIFEST and is edited in a real editor.
toml_get() {
  local file="$1" section="${2%%.*}" key="${2#*.}"
  awk -v sect="[$section]" -v key="$key" '
    $0 ~ /^[[:space:]]*\[/ { in_sect = ($0 ~ "^[[:space:]]*\\" sect) ; next }
    in_sect && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      sub(/^[^=]*=[[:space:]]*/, ""); gsub(/[[:space:]]*$/, ""); print; exit
    }
  ' "$file"
}

toml_set() {
  local file="$1" section="${2%%.*}" key="${2#*.}" value="$3" tmp
  tmp=$(mktemp)
  awk -v sect="[$section]" -v key="$key" -v val="$value" '
    $0 ~ /^[[:space:]]*\[/ { in_sect = ($0 ~ "^[[:space:]]*\\" sect) ; print; next }
    in_sect && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { sub(/=[[:space:]]*.*/, "= " val); done_it = 1 }
    { print }
    END { if (!done_it) exit 3 }
  ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  [[ -s "$tmp" ]] || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$file"
}

get_setting_value() {
  local entry; entry=$(find_setting "$1") || return 1
  local file path type
  file=$(setting_field "$entry" 2); path=$(setting_field "$entry" 3); type=$(setting_field "$entry" 4)
  [[ -f "$file" ]] || return 1
  case "$type" in
    toml-number) toml_get "$file" "$path" ;;
    *)
      # Not `// empty`: jq's alternative operator fires on `false` as well as
      # `null`, so a boolean setting that is genuinely off would read as missing.
      local raw; raw=$(jq -r "$path" "$file" 2>/dev/null) || return 1
      [[ "$raw" == "null" ]] && return 1
      printf '%s\n' "$raw"
      ;;
  esac
}

set_setting_value() {
  local entry; entry=$(find_setting "$1") || { echo "unknown setting: $1" >&2; return 1; }
  local file path type label unit min max options value="$2"
  file=$(setting_field "$entry" 2);   path=$(setting_field "$entry" 3)
  type=$(setting_field "$entry" 4);   label=$(setting_field "$entry" 5)
  unit=$(setting_field "$entry" 6);   min=$(setting_field "$entry" 7)
  max=$(setting_field "$entry" 8);    options=$(setting_field "$entry" 9)
  [[ -f "$file" ]] || { echo "file not found: $file" >&2; return 1; }

  case "$type" in
    number|toml-number)
      [[ "$value" =~ ^-?[0-9]+$ ]] || { echo "$1: '$value' is not a whole number" >&2; return 1; }
      if [[ -n "$min" ]] && (( value < min )); then echo "$1: $value$unit is below the minimum ($min$unit)" >&2; return 1; fi
      if [[ -n "$max" ]] && (( value > max )); then echo "$1: $value$unit is above the maximum ($max$unit)" >&2; return 1; fi
      ;;
    bool)
      [[ "$value" == "true" || "$value" == "false" ]] || { echo "$1: '$value' must be true or false" >&2; return 1; }
      ;;
    enum)
      [[ ",$options," == *",$value,"* ]] || { echo "$1: '$value' is not one of: ${options//,/, }" >&2; return 1; }
      ;;
  esac

  cp -a "$file" "$file.bak.$(date +%s)"
  case "$type" in
    toml-number)
      toml_set "$file" "$path" "$value" || { echo "$1: could not find '$path' in $file — left untouched" >&2; return 1; }
      ;;
    number|bool)
      local tmp; tmp=$(mktemp)
      jq --argjson v "$value" "$path = \$v" "$file" > "$tmp" 2>/dev/null
      [[ -s "$tmp" ]] || { echo "$1: write failed, left $file untouched" >&2; rm -f "$tmp"; return 1; }
      mv "$tmp" "$file"
      ;;
    *)
      local tmp; tmp=$(mktemp)
      jq --arg v "$value" "$path = \$v" "$file" > "$tmp" 2>/dev/null
      [[ -s "$tmp" ]] || { echo "$1: write failed, left $file untouched" >&2; rm -f "$tmp"; return 1; }
      mv "$tmp" "$file"
      ;;
  esac
  echo "$label -> $value$unit" >&2
}

build_settings_json() {
  local entries=()
  local entry id file path type label unit min max options hint value opts_json
  for entry in "${SETTINGS[@]}"; do
    id=$(setting_field "$entry" 1);     file=$(setting_field "$entry" 2)
    path=$(setting_field "$entry" 3);   type=$(setting_field "$entry" 4)
    label=$(setting_field "$entry" 5);  unit=$(setting_field "$entry" 6)
    min=$(setting_field "$entry" 7);    max=$(setting_field "$entry" 8)
    options=$(setting_field "$entry" 9); hint=$(setting_field "$entry" 10)
    value=$(get_setting_value "$id")
    if [[ -n "$options" ]]; then
      opts_json=$(printf '%s' "$options" | jq -Rc 'split(",")')
    else
      opts_json='[]'
    fi
    case "$type" in
      number|toml-number)
        entries+=("$(jq -nc --arg id "$id" --arg label "$label" --arg type "$type" --arg unit "$unit" \
          --argjson min "${min:-null}" --argjson max "${max:-null}" --argjson options "$opts_json" \
          --arg hint "$hint" --arg file "$file" --argjson value "${value:-null}" \
          '{id:$id,label:$label,type:$type,unit:$unit,min:$min,max:$max,options:$options,hint:$hint,file:$file,value:$value}')")
        ;;
      bool)
        [[ "$value" == "true" || "$value" == "false" ]] || value="false"
        entries+=("$(jq -nc --arg id "$id" --arg label "$label" --arg type "$type" --arg unit "$unit" \
          --argjson min null --argjson max null --argjson options "$opts_json" \
          --arg hint "$hint" --arg file "$file" --argjson value "$value" \
          '{id:$id,label:$label,type:$type,unit:$unit,min:$min,max:$max,options:$options,hint:$hint,file:$file,value:$value}')")
        ;;
      *)
        entries+=("$(jq -nc --arg id "$id" --arg label "$label" --arg type "$type" --arg unit "$unit" \
          --argjson min null --argjson max null --argjson options "$opts_json" \
          --arg hint "$hint" --arg file "$file" --arg value "${value:-}" \
          '{id:$id,label:$label,type:$type,unit:$unit,min:$min,max:$max,options:$options,hint:$hint,file:$file,value:$value}')")
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
      omarchy/*|omarchy-audit*|branding/*) group="omarchy" ;;
      alacritty*|foot*|kitty*|ghostty*) group="terminal" ;;
      opencode*|mise*|vscode*|dev/*) group="dev" ;;
      bin/*) group="scripts" ;;
      etc/*) group="system" ;;
      omarchy-plugin/*) group="replicant" ;;
      *) group="other" ;;
    esac
    if [[ -f "$src" ]]; then exists=true; else exists=false; fi
    if [[ -f "$src" ]] && is_default_file "$src"; then is_default=true; else is_default=false; fi
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
    entries+=("$(jq -nc --arg id "$rel" --arg label "$label" --arg src "$src" --arg group "$group" --argjson exists "$exists" --argjson is_default "$is_default" --argjson dirty "$dirty" --argjson unpushed "$unpushed" --arg sync_state "$sync_state" --arg source "manifest" '{id:$id,label:$label,src:$src,group:$group,exists:$exists,is_default:$is_default,dirty:$dirty,unpushed:$unpushed,sync_state:$sync_state,source:$source}')")
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
    entries+=("$(jq -nc --arg id "$prel" --arg label "$pname" --arg src "$psrc" --arg group "plugins" --argjson exists true --argjson is_default false --argjson dirty "$pdirty" --argjson unpushed "$punpushed" --arg sync_state "$psync" --arg source "auto" '{id:$id,label:$label,src:$src,group:$group,exists:$exists,is_default:$is_default,dirty:$dirty,unpushed:$unpushed,sync_state:$sync_state,source:$source}')")
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

core_status() {
  local json=0
  [[ "${1:-}" == "--json" ]] && json=1
  if [[ ! -d "$REPO_DIR/.git" ]]; then
    if (( json )); then echo '{"initialized":false}'; else echo "not initialized — run omarchy-replicant init --savegame"; fi
    return 0
  fi
  # best-effort refresh of origin/HEAD (so unpushed/ahead/behind are accurate);
  # never blocks if there's no network
  timeout 3 git -C "$REPO_DIR" fetch --quiet 2>/dev/null || true
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

# Used by the omarchy-replicant CLI wrapper
if [[ "${1:-}" == "backup" ]]; then core_backup
elif [[ "${1:-}" == "status" ]]; then core_status "${2:-}"
fi
