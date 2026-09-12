# shellcheck shell=bash disable=SC2034
# layout.sh: the repo layout, the pre-commit hook, and the backup itself.
# Sourced by replicant-core.sh, which sets the paths it uses. It defines
# functions and data and runs nothing. Other modules read its data.

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
