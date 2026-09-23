# shellcheck shell=bash disable=SC2034
# backup.sh: copy live configuration into the repository before a save.
# Sourced by replicant-core.sh. It owns the backup workflow and uses layout
# primitives for directory and hook management.

core_backup() {
  require_writable_schema || return 1
  briefcache_invalidate
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
  # The loop order is the tracked order, so the messages below read the way
  # they always did. What changed is where each answer comes from: the scope,
  # the live and repo paths resolve in the registry, and the hold decision is
  # the evaluator's membership-plus-difference.
  registry_build
  local regrow rscope rlive rrepo isdir
  local -a rf=()
  for entry in "${TRACKED[@]}"; do
    rel="${entry##*:}"
    regrow=$(registry_row_for "$rel") || continue
    mapfile -t rf < <(row_split "$regrow" 9)
    rscope="${rf[4]}"; rlive="${rf[5]}"; rrepo="${rf[6]}"
    src="$rlive"
    dst="$rrepo"
    # Switched off in .replicant-sync: not copied from here, and (see the
    # prune pass below) whatever the repo already holds is left alone.
    if [[ "$rscope" == "off" ]]; then
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
    isdir=false; is_dir_entry "$rel" && isdir=true
    if is_incoming_rel "$rel" && entry_differs "$rlive" "$rrepo" "$isdir"; then
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
  local _e _row
  local -a _rf=()
  for entry in "${TRACKED[@]}"; do
    _e="${entry##*:}"
    _row=$(registry_row_for "$_e" 2>/dev/null) || continue
    mapfile -t _rf < <(row_split "$_row" 9)
    [[ "${_rf[4]}" == "off" ]] && continue
    expected+=("${_rf[6]}")
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
  if [[ "$(repo_data_version)" == 2 ]]; then
    # Encrypted per secret into vault/, never as plaintext. The key check
    # inside fails the backup before anything mutates when this machine has
    # no usable key: a save that silently skipped secrets would lose backups.
    vault_save_all || return 1
  else
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
  fi

  regenerate_inventory
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
