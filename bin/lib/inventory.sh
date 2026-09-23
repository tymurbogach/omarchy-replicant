# shellcheck shell=bash disable=SC2034
# inventory.sh: machine facts that can rebuild a setup.
# Sourced by replicant-core.sh. It defines functions and performs no work.

regenerate_inventory() {
  local known base_omarchy other_omarchy name pmf pid pver porigin pdir pmethod
  local tdir tname torigin retired u noise omarchy_path
  mkdir -p "$STATE_DIR"
  echo "→ Regenerating state/ inventory" >&2

  pacman -Qqen > "$STATE_DIR/pacman-official.txt" 2>/dev/null || true
  pacman -Qqem > "$STATE_DIR/pacman-aur.txt" 2>/dev/null || true
  omarchy_path=${OMARCHY_PATH:-/usr/share/omarchy}
  base_omarchy="$omarchy_path/install/omarchy-base.packages"
  other_omarchy="$omarchy_path/install/omarchy-other.packages"
  if [[ -r $base_omarchy ]]; then
    known=$(mktemp)
    cat "$base_omarchy" "$other_omarchy" 2>/dev/null |
      sed 's/#.*//' | tr -s ' \t' '\n' | sed '/^$/d' >> "$known"
    if [[ -r "$REPO_DIR/bin/pacman-delta-ignore" ]]; then
      sed 's/#.*//' "$REPO_DIR/bin/pacman-delta-ignore" | tr -d ' \t' | sed '/^$/d' >> "$known"
    elif [[ -r "$PLUGIN_DIR/bin/pacman-delta-ignore" ]]; then
      sed 's/#.*//' "$PLUGIN_DIR/bin/pacman-delta-ignore" | tr -d ' \t' | sed '/^$/d' >> "$known"
    fi
    sort -u "$known" -o "$known"
    comm -23 <(sort -u "$STATE_DIR/pacman-official.txt") "$known" > "$STATE_DIR/pacman-delta.txt"
    comm -23 <(sort -u "$STATE_DIR/pacman-aur.txt") "$known" > "$STATE_DIR/pacman-delta-aur.txt"
    rm -f "$known"
  else
    : > "$STATE_DIR/pacman-delta.txt"
    : > "$STATE_DIR/pacman-delta-aur.txt"
  fi

  {
    echo "# id<TAB>version<TAB>origin<TAB>method"
    echo "# A restore never fetches one. Install it yourself, one at a time:"
    echo "#   omarchy-replicant install-plugin <id>"
    echo "# method 'add'   -> omarchy plugin add <origin>"
    echo "# method 'clone' -> omarchy plugin clone <origin>"
    for pmf in "$HOME/.config/omarchy/plugins"/*/manifest.json; do
      [[ -f "$pmf" ]] || continue
      pdir=$(dirname "$pmf")
      pid=$(jq -r '.id // empty' "$pmf" 2>/dev/null) || continue
      [[ -n "$pid" ]] || continue
      pver=$(jq -r '.version // "?"' "$pmf" 2>/dev/null)
      IFS=$'\t' read -r porigin pmethod < <(resolve_plugin_origin "$pdir" "$pid" "$pmf")
      printf '%s\t%s\t%s\t%s\n' "$pid" "$pver" "$porigin" "$pmethod"
    done
  } > "$STATE_DIR/omarchy-plugins.txt"

  {
    echo "# name<TAB>origin — user-installed themes. A restore never fetches one."
    echo "#   omarchy-replicant install-theme <name>"
    for tdir in "$HOME/.config/omarchy/themes"/*/; do
      [[ -d "$tdir" ]] || continue
      tname=$(basename "${tdir%/}")
      torigin=$(git -C "${tdir%/}" remote get-url origin 2>/dev/null || true)
      [[ -n "$torigin" ]] || torigin="-"
      printf '%s\t%s\n' "$tname" "$torigin"
    done
  } > "$STATE_DIR/omarchy-themes.txt"

  for retired in system.txt mise.txt npm-global.txt containers.txt system-services.txt defined-secrets.txt; do
    rm -f "$STATE_DIR/$retired"
  done

  {
    systemctl --user list-unit-files --state=enabled --no-pager --no-legend 2>/dev/null |
      awk '{print $1}' |
      while read -r u; do
        [[ -f "$HOME/.config/systemd/user/$u" ]] && printf '%s\n' "$u"
      done
  } > "$STATE_DIR/user-services.txt" || true
  grep -E '[[:space:]]cifs[[:space:]]' /etc/fstab > "$STATE_DIR/cifs-mounts.txt" 2>/dev/null || true

  noise='^(chromium|fcitx5|systemd|omarchy|elephant|environment\.d|btop)$'
  {
    echo "# Files under ~/.config that differ from Omarchy's default."
    echo "# Content differences only."
    echo
    for d in "$HOME/.local/share/omarchy/config"/* "$omarchy_path/config"/*; do
      [[ -e "$d" ]] || continue
      name=$(basename "$d")
      [[ $name =~ $noise ]] && continue
      [[ -e "$HOME/.config/$name" ]] || continue
      diff -rq "$d" "$HOME/.config/$name" 2>/dev/null |
        grep ' differ$' | sed 's|.*/\.config/|~/.config/|' || true
    done
  } > "$STATE_DIR/drift-vs-omarchy.txt"
}
