#!/bin/bash
# replicant-core.sh — port literal de omarchy_thinkpad savegame para el plugin
# Ubicado en: ~/.config/omarchy/plugins/io.github.tymurbogach.omarchy-replicant/bin/
# No reinventa: copia MANIFEST/SECRETS_MANIFEST + lib.sh + scan-secrets + backup/savegame/restore
set -euo pipefail

REAL_CORE="$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
PLUGIN_DIR="$(cd -- "$(dirname -- "$REAL_CORE")/.." && pwd)"
# Repo destino del usuario (separate from dotfiles generic): private, layout savegame
REPLICANT_HOME="${OMARCHY_REPLICANT_HOME:-$HOME/.local/share/omarchy-replicant}"
REPO_DIR="$REPLICANT_HOME/repo"
# Compat: old simple repo used flat files; core uses savegame layout config/secrets/state
CONFIG_DIR="$REPO_DIR/config"
SECRETS_DIR="$REPO_DIR/secrets"
STATE_DIR="$REPO_DIR/state"
TEMPLATES_DIR="$REPO_DIR/templates"
GITHOOKS_DIR="$REPO_DIR/.githooks"

# ─── MANIFEST — copia literal de ~/omarchy_thinkpad/bin/backup.sh ────────────
# Dirección única: sistema -> repo. Solo lo tuyo o lo que difiere del default.
# Lo idéntico al default no se trackea: se recupera con omarchy-refresh-config.
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
  # Extra v2: replicant plugin itself (so plugin survives reinstall)
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

# lib.sh — poner con .bak.<epoch>
DRY=${DRY:-0}
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1" >&2; }
skip() { printf '  \033[33m·\033[0m %s\n' "$1" >&2; }
run()  { if (( DRY )); then printf '  \033[36m»\033[0m %s\n' "$*" >&2; else "$@"; fi; }
poner() {
  local src=$1 dst=$2 modo=$3
  local corto=${dst/#$HOME/\~}
  if [[ ! -f $src ]]; then
    skip "$corto — origen ausente en el repo ($src)"
    return
  fi
  if [[ -f $dst ]] && cmp -s "$src" "$dst"; then
    run chmod "$modo" "$dst"
    ok "$corto (ya igual, modo $modo)"
    return
  fi
  if [[ -e $dst ]]; then
    run cp -a "$dst" "$dst.bak.$(date +%s)"
    skip "$corto — el anterior guardado como .bak.<epoch>"
  fi
  run install -D -m "$modo" "$src" "$dst"
  ok "$corto ($modo)"
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
COMMIT BLOQUEADO: posible credencial en config/state/templates.
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
  # .gitignore — savegame style (state/ generated, .bak.* ignored, secrets/ tracked)
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
  echo "→ Copiando configuración (MANIFEST fijo, savegame)" >&2
  copied=0; missing=0
  for entry in "${MANIFEST[@]}"; do
    src=${entry%%:*}
    dst="$CONFIG_DIR/${entry##*:}"
    if [[ -f $src ]]; then
      mkdir -p "$(dirname "$dst")"
      cp -f "$src" "$dst"
      ((copied++)) || true
    else
      echo "  · ausente: ${src/#$HOME/\~}" >&2
      ((missing++)) || true
    fi
  done
  echo "  $copied copiados, $missing ausentes" >&2

  echo "→ Copiando secretos (repo privado, 600)" >&2
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
      echo "  · ausente: ${src/#$HOME/\~}" >&2
    fi
  done
  # CIFS credentials (root:600, best-effort)
  install -d -m 700 "$SECRETS_DIR/samba" 2>/dev/null || true
  for src in /etc/samba/credentials-pi /etc/samba/credentials-nas; do
    dst="$SECRETS_DIR/samba/$(basename "$src")"
    if [[ -r $src ]]; then install -m 600 "$src" "$dst" 2>/dev/null || true
    elif [[ -e $src && ! -f $dst ]]; then
      echo "  · $src requiere sudo: sudo install -m600 -o $USER -g $USER $src $dst" >&2
    fi
  done
  echo "  $scopied secretos copiados" >&2

  echo "→ Regenerando inventario state/" >&2
  mkdir -p "$STATE_DIR"
  {
    echo "# Generado por replicant-core.sh — no editar a mano"
    echo "fecha:        $(date -Is)"
    echo "hostname:     $(hostnamectl --static 2>/dev/null || hostname)"
    echo "kernel:       $(uname -r)"
    echo "omarchy:      $(cat /usr/share/omarchy/version 2>/dev/null || cat "$HOME/.local/share/omarchy/version" 2>/dev/null || echo '?')"
    echo "claude-code:  $(claude --version 2>/dev/null || echo 'no instalado')"
  } > "$STATE_DIR/sistema.txt"
  pacman -Qqen > "$STATE_DIR/pacman-oficial.txt" 2>/dev/null || true
  pacman -Qqem > "$STATE_DIR/pacman-aur.txt" 2>/dev/null || true
  OMARCHY_PATH=${OMARCHY_PATH:-/usr/share/omarchy}
  base_omarchy="$OMARCHY_PATH/install/omarchy-base.packages"
  otros_omarchy="$OMARCHY_PATH/install/omarchy-other.packages"
  if [[ -r $base_omarchy ]]; then
    conocidos=$(mktemp)
    cat "$base_omarchy" "$otros_omarchy" 2>/dev/null | sed 's/#.*//' | tr -s ' \t' '\n' | sed '/^$/d' >> "$conocidos"
    if [[ -r "$REPO_DIR/bin/pacman-delta-ignore" ]]; then
      sed 's/#.*//' "$REPO_DIR/bin/pacman-delta-ignore" | tr -d ' \t' | sed '/^$/d' >> "$conocidos"
    elif [[ -r "$PLUGIN_DIR/bin/pacman-delta-ignore" ]]; then
      sed 's/#.*//' "$PLUGIN_DIR/bin/pacman-delta-ignore" | tr -d ' \t' | sed '/^$/d' >> "$conocidos"
    fi
    sort -u "$conocidos" -o "$conocidos"
    comm -23 <(sort -u "$STATE_DIR/pacman-oficial.txt") "$conocidos" > "$STATE_DIR/pacman-delta.txt"
    comm -23 <(sort -u "$STATE_DIR/pacman-aur.txt")     "$conocidos" > "$STATE_DIR/pacman-delta-aur.txt"
    rm -f "$conocidos"
  else
    : > "$STATE_DIR/pacman-delta.txt"
    : > "$STATE_DIR/pacman-delta-aur.txt"
  fi
  mise ls 2>/dev/null > "$STATE_DIR/mise.txt" || true
  npm ls -g --depth=0 2>/dev/null > "$STATE_DIR/npm-global.txt" || true
  systemctl list-unit-files --state=enabled --no-pager --no-legend 2>/dev/null | awk '{print $1}' > "$STATE_DIR/servicios-sistema.txt" || true
  systemctl --user list-unit-files --state=enabled --no-pager --no-legend 2>/dev/null | awk '{print $1}' > "$STATE_DIR/servicios-usuario.txt" || true
  docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Ports}}' 2>/dev/null > "$STATE_DIR/contenedores.txt" || true
  grep -E '[[:space:]]cifs[[:space:]]' /etc/fstab > "$STATE_DIR/montajes-cifs.txt" 2>/dev/null || true
  if [[ -r $HOME/.config/environment.d/60-secrets.conf ]]; then
    { echo "# Nombres de las variables definidas. Los VALORES no se trackean."; grep -oE '^[A-Z_]+' "$HOME/.config/environment.d/60-secrets.conf" | sort; } > "$STATE_DIR/secretos-definidos.txt"
  fi
  RUIDO='^(chromium|fcitx5|systemd|omarchy|elephant|environment\.d|btop)$'
  {
    echo "# Ficheros de ~/.config que difieren del default de Omarchy."
    echo "# Solo diferencias de contenido: los 'Only in' son casi siempre datos de runtime."
    echo "# Excluidos por ruido: chromium, fcitx5, systemd, omarchy, elephant, environment.d, btop"
    echo
    for d in "$HOME/.local/share/omarchy/config"/* "$OMARCHY_PATH/config"/*; do
      [[ -e "$d" ]] || continue
      name=$(basename "$d")
      [[ $name =~ $RUIDO ]] && continue
      [[ -e "$HOME/.config/$name" ]] || continue
      diff -rq "$d" "$HOME/.config/$name" 2>/dev/null | grep ' differ$' | sed 's|.*/\.config/|~/.config/|' || true
    done
  } > "$STATE_DIR/deriva-vs-omarchy.txt"

  echo "→ Escaneando lo copiado (excluye secrets/)" >&2
  SCAN="$REPO_DIR/bin/scan-secrets.sh"
  [[ -x "$SCAN" ]] || SCAN="$PLUGIN_DIR/bin/scan-secrets.sh"
  if [[ -x "$SCAN" ]]; then
    if ! "$SCAN" "$CONFIG_DIR" "$STATE_DIR" 2>&1; then
      echo "  ✗ POSIBLE SECRETO — NO hagas commit" >&2
      return 1
    fi
    echo "  ✓ limpio" >&2
  else
    echo "  · scan-secrets.sh no encontrado, omitiendo" >&2
  fi
  echo "Listo. Revisa con 'git -C $REPO_DIR diff' y commitea con porqué." >&2
}

is_default_file() {
  # $1 = absolute source path (e.g. $HOME/.config/hypr/input.lua or /etc/...)
  # returns 0 if idéntico al default de Omarchy → "por defecto"
  local src="$1"
  local omarchy_path="${OMARCHY_PATH:-/usr/share/omarchy}"
  local rel=""
  # mapea src → ruta relativa bajo /usr/share/omarchy/config o default
  if [[ "$src" == "$HOME/.config/"* ]]; then
    rel="${src#$HOME/.config/}"
    for base in "$omarchy_path/config" "/usr/share/omarchy/config" "$omarchy_path/default" "/usr/share/omarchy/default"; do
      if [[ -f "$base/$rel" ]]; then
        cmp -s "$src" "$base/$rel" 2>/dev/null && return 0
        return 1
      fi
      # para carpetas con fichero dentro, ej hypr/input.lua → hypr/input.lua existe, ya probado
    done
    # sin default conocido → no es por defecto (es personal tuyo)
    return 1
  elif [[ "$src" == "/etc/"* ]]; then
    # /etc no tiene default en omarchy → siempre personalizado
    return 1
  elif [[ "$src" == "$HOME/.bashrc" ]]; then
    # compara contra omarchy default bashrc si existe
    for base in "$omarchy_path/default/bash" "$omarchy_path/config" "/usr/share/omarchy/default/bash"; do
      [[ -f "$base/bashrc" ]] && { cmp -s "$src" "$base/bashrc" 2>/dev/null && return 0; return 1; }
    done
    return 1
  else
    return 1
  fi
}

build_configs_json() {
  local entries=()
  local entry src dst rel label group exists is_default
  for entry in "${MANIFEST[@]}"; do
    src="${entry%%:*}"
    rel="${entry##*:}"
    label="$rel"
    # grupo por prefijo
    case "$rel" in
      home/*) group="shell" ;;
      ssh/*|git/*) group="git/ssh" ;;
      claude/*) group="claude" ;;
      hypr/*) group="hypr" ;;
      uwsm/*|xdg-terminals*) group="sesión" ;;
      omarchy/*|omarchy-audit*|branding/*) group="omarchy" ;;
      alacritty*|foot*|kitty*|ghostty*) group="terminal" ;;
      opencode*|mise*|vscode*|dev/*) group="dev" ;;
      bin/*) group="scripts" ;;
      etc/*) group="sistema" ;;
      omarchy-plugin/*) group="replicant" ;;
      *) group="otros" ;;
    esac
    if [[ -f "$src" ]]; then exists=true; else exists=false; fi
    if [[ -f "$src" ]] && is_default_file "$src"; then is_default=true; else is_default=false; fi
    # detecta si el repo tiene cambios sin commitear para ese rel
    local dirty=false
    if git -C "$REPO_DIR" status --porcelain -- "config/$rel" 2>/dev/null | grep -q .; then dirty=true; fi
    entries+=("$(jq -nc --arg id "$rel" --arg label "$label" --arg src "$src" --arg group "$group" --argjson exists "$exists" --argjson is_default "$is_default" --argjson dirty "$dirty" '{id:$id,label:$label,src:$src,group:$group,exists:$exists,is_default:$is_default,dirty:$dirty}')")
  done
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
    if (( json )); then echo '{"initialized":false}'; else echo "no inicializado — ejecuta omarchy-replicant init --savegame"; fi
    return 0
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
    local configs_json secrets_json
    configs_json=$(build_configs_json)
    secrets_json=$(build_secrets_json)
    jq -nc --arg branch "$branch" --arg remote "$remote" --argjson dirty "$dirty" --argjson untracked "$untracked" --argjson ahead "$ahead" --argjson behind "$behind" --arg pending "$pending_groups" --argjson configs "$configs_json" --argjson secrets "$secrets_json" \
      '{initialized:true, branch:$branch, remote:$remote, dirty:$dirty, untracked:$untracked, ahead:$ahead, behind:$behind, pending:$pending, configs:$configs, secrets:$secrets}'
  else
    echo "branch: $branch"
    echo "remote: ${remote:-<none>}"
    echo "dirty: $dirty pending:$pending_groups ahead/behind: $ahead/$behind"
    if (( dirty > 0 )); then git -C "$REPO_DIR" status --short 2>/dev/null | head -n 30; fi
  fi
}

# Used by omarchy-replicant Savegame wrapper
if [[ "${1:-}" == "backup" ]]; then core_backup
elif [[ "${1:-}" == "status" ]]; then core_status "${2:-}"
fi
