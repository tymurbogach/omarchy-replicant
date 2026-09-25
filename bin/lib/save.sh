# shellcheck shell=bash disable=SC2034
# save.sh: saves as transactions, never in the active worktree.
# Sourced by replicant-core.sh, which sets the paths it uses. It defines
# functions and data and runs nothing. Other modules read its data.
#
# A save snapshots live entries into a detached temporary worktree under
# $REPLICANT_HOME/transactions/<uuid>/repo, commits there, verifies that the
# active repository HEAD has not moved since, fast-forwards the active
# repository to the candidate commit, pushes, and removes the worktree. Any
# failure before the fast-forward leaves the active repository exactly as it
# was; a transaction that already committed is never discarded automatically,
# so doctor (section 5B) can offer to resume or drop it.
#
# The snapshot reuses the existing copy passes with the repo paths redirected:
# the global snapshot re-runs `backup` with REPLICANT_TX_REPO set, and a
# selective snapshot runs `snapshot-one` the same way. No copy logic is
# duplicated here, so v1 and v2 repos save through the same code the backup
# already exercises.

# The transaction journal, worktree lifecycle, resume and discard live in
# bin/lib/transaction.sh: every mutator shares that one engine. This module
# keeps the save-specific passes (subject, scanner, push, modes, snapshot) and
# the save phase functions that core_save orchestrates.

# save_auto_subject <txrepo>: the commit subject from what the transaction
# changed, the way the CLI derived it from the active repo before
# transactions. Paths only, never contents: a name is not a secret.
save_auto_subject() {
  local txrepo="$1"
  local -a raw=() rels=()
  local line p kind=config
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    p=${line:3}
    p=${p##* -> }
    p=${p#\"}; p=${p%\"}
    raw+=("$p")
  done < <(git -C "$txrepo" status --porcelain -uall -- . ':(exclude)state/' 2>/dev/null)
  (( ${#raw[@]} )) || { printf 'config: save\n'; return 0; }
  local all_secret=1
  for p in "${raw[@]}"; do
    [[ "$p" == secrets/* || "$p" == vault/* ]] || all_secret=0
    p=${p#config/}; p=${p#secrets/}; p=${p#vault/blobs/}; p=${p#profiles/*/config/}
    rels+=("$p")
  done
  (( all_secret )) && kind=secrets
  local n=${#rels[@]} joined
  joined=$(printf '%s, ' "${rels[@]}"); joined=${joined%, }
  if (( ${#joined} <= 60 )); then
    printf '%s: %s\n' "$kind" "$joined"
  else
    printf '%s: %d files — %s, +%d more\n' "$kind" "$n" "${rels[0]}" "$(( n - 1 ))"
  fi
  return 0
}

# save_scan_tx <txrepo>: the secret scanner over what the transaction would
# commit. Mirrors the backup's scan directories. Fails closed like the hook.
save_scan_tx() {
  local txrepo="$1"
  local scan prof
  scan="$txrepo/bin/scan-secrets.sh"
  [[ -x "$scan" ]] || scan="$PLUGIN_DIR/bin/scan-secrets.sh"
  if [[ ! -x "$scan" ]]; then
    echo "  ✗ secret scanner not found, blocking the save" >&2
    return 1
  fi
  local -a scan_dirs=("$txrepo/config" "$txrepo/state")
  if prof=$(REPLICANT_TX_REPO="$txrepo" bash "$REAL_CORE" profile-get 2>/dev/null) && [[ -n "$prof" ]]; then
    [[ -d "$txrepo/profiles/$prof/config" ]] && scan_dirs+=("$txrepo/profiles/$prof/config")
  fi
  if ! "$scan" "${scan_dirs[@]}" 2>&1; then
    echo "  ✗ POSSIBLE SECRET — DO NOT commit" >&2
    return 1
  fi
  echo "  ✓ clean" >&2
  return 0
}

# save_push: send the active repo's pending commits, mirroring the CLI's push
# outcome words so every command reports the same states. Sets PUSHED to one
# of ok, no-remote, held, nothing, failed; PUSH_ERR carries git's complaint.
save_push() {
  local want_push="$1"
  PUSHED=""; PUSH_ERR=""
  if (( ! want_push )); then PUSHED="held"; return 0; fi
  if ! git -C "$REPO_DIR" remote get-url origin >/dev/null 2>&1; then PUSHED="no-remote"; return 0; fi
  git -C "$REPO_DIR" rev-parse -q --verify HEAD >/dev/null 2>&1 || { PUSHED="nothing"; return 0; }
  local -a push_args=(origin HEAD)
  local branch
  if git -C "$REPO_DIR" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
    [[ "$(git -C "$REPO_DIR" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)" != 0 ]] || { PUSHED="nothing"; return 0; }
  else
    branch=$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)
    push_args=(-u origin "$branch")
  fi
  echo "→ Push to $(git -C "$REPO_DIR" config --get remote.origin.url 2>/dev/null)" >&2
  if PUSH_ERR=$(git -C "$REPO_DIR" push -q "${push_args[@]}" 2>&1); then
    PUSHED="ok"
    echo "    done" >&2
  else
    PUSHED="failed"
  fi
  return 0
}

# save_fix_modes: git tracks only the exec bit, so a fast-forward checkout
# rebuilds every other mode from the umask. The copy passes establish v1
# secret copies at 600 under a 700 secrets dir, so re-apply both after the
# fast-forward. Vault blobs keep checkout modes: they were never mode-managed.
save_fix_modes() {
  repo_has_vault 2>/dev/null && return 0
  local entry rel dst
  [[ -d "$SECRETS_DIR" ]] && chmod 700 -- "$SECRETS_DIR" 2>/dev/null || true
  for entry in ${TRACKED_SECRETS[@]+"${TRACKED_SECRETS[@]}"}; do
    rel="${entry##*:}"
    dst="$SECRETS_DIR/$rel"
    [[ -f "$dst" ]] && chmod 600 -- "$dst" 2>/dev/null || true
  done
  return 0
}

# snapshot_one <rel>: copy one tracked entry into the repo (which the save
# transaction redirects into its worktree through REPLICANT_TX_REPO). The
# selective counterpart of the backup's copy pass: it always copies, even
# when another machine holds a newer copy, because naming the file is how a
# person overrules the hold-back. Prints the repo-relative paths it wrote, so
# the save commits exactly those and nothing else.
snapshot_one() {
  local rel="$1"
  local src regrow kind scope live repo blob
  local -a rf=()
  [[ -n "$rel" ]] || { echo "snapshot: usage: snapshot-one <id>" >&2; return 2; }
  require_writable_schema || return 1
  src=$(resolve_manifest_src "$rel") || { echo "unknown id: $rel" >&2; return 1; }
  registry_build || return 1
  regrow=$(registry_row_for "$rel") || { echo "unknown id: $rel" >&2; return 1; }
  mapfile -t rf < <(row_split "$regrow" 9)
  kind="${rf[1]}"; scope="${rf[4]}"; live="${rf[5]}"; repo="${rf[6]}"; blob="${rf[7]}"
  if [[ "$scope" == "off" ]]; then
    echo "snapshot: $rel is switched off — scope it back on before saving it" >&2
    return 1
  fi
  if [[ "$kind" == "secret" ]] && repo_has_vault; then
    [[ -f "$live" ]] || { echo "$live does not exist on this machine" >&2; return 1; }
    if [[ -f "$live" && ! -r "$live" ]]; then
      echo "  · ${live/#$HOME/\~} is readable by root only. To save it: sudo install -D -m600 -o $(id -un) -g $(id -gn) $live $repo" >&2
      return 1
    fi
    local idx
    idx=$(vault_index_decrypt) || return 1
    idx=$(vault_save_entry "$live" "$rel" "$idx") || return 1
    vault_index_write "$idx" || return 1
    blob=$(vault_index_blob "$idx" "$rel")
    printf 'vault/blobs/%s.age\n' "$blob"
    printf 'vault/index.age\n'
    return 0
  fi
  if [[ "$kind" == "dir" ]]; then
    [[ -d "${live%/}" ]] || { echo "${live%/} does not exist on this machine" >&2; return 1; }
    copy_tree_into_repo "$live" "$repo" || return 1
  else
    if is_secret_rel "$rel"; then
      [[ -f "$live" ]] || { echo "$live does not exist on this machine" >&2; return 1; }
      mkdir -p "$(dirname "$repo")"
      install -m 600 "$live" "$repo" || return 1
    else
      [[ -f "$live" ]] || { echo "$live does not exist on this machine" >&2; return 1; }
      mkdir -p "$(dirname "$repo")"
      cp -f "$live" "$repo" || return 1
    fi
  fi
  local stripped="${repo%/}"
  stripped="${stripped#"$REPO_DIR"/}"
  printf '%s\n' "$stripped"
  return 0
}

# save_plan: parse save options into the SAVE_* plan for the staging,
# validation and activation phases below. Sets SAVE_SCOPE, SAVE_MSG,
# SAVE_AUTO, SAVE_PUSH and SAVE_IDS. Prints the help and leaves SAVE_SCOPE
# empty for -h, so core_save stops after planning.
save_plan() {
  SAVE_SCOPE=""; SAVE_MSG=""; SAVE_AUTO=0; SAVE_PUSH=1
  SAVE_IDS=()
  while (( $# )); do
    case "$1" in
      --all) SAVE_SCOPE="all"; shift ;;
      --inventory) SAVE_SCOPE="inventory"; shift ;;
      --id) [[ -n "${2:-}" ]] || { echo "save: --id needs an entry id" >&2; return 2; }; SAVE_SCOPE="id"; SAVE_IDS+=("$2"); shift 2 ;;
      -m|--message) [[ -n "${2:-}" ]] || { echo "save: -m needs a message" >&2; return 2; }; SAVE_MSG="$2"; shift 2 ;;
      --auto|-a) SAVE_AUTO=1; shift ;;
      --no-push) SAVE_PUSH=0; shift ;;
      -h|--help) echo "save [--all] [--id <id> ...] [--inventory] [-m \"why\" | --auto] [--no-push]" >&2; return 0 ;;
      *) echo "save: unknown option: $1" >&2; return 2 ;;
    esac
  done
  if [[ -z "$SAVE_SCOPE" ]]; then
    SAVE_SCOPE="all"
  fi
  if [[ "$SAVE_SCOPE" == "id" && ${#SAVE_IDS[@]} == 0 ]]; then
    echo "save: --id needs an entry id" >&2; return 2
  fi
  return 0
}

# core_save [--all|--inventory|--id <id>...] [-m <msg>|--auto] [--no-push]:
# one transaction, one commit. The active worktree must be clean: every copy
# in it is regenerable from live files, so there is nothing to carry over.
# Planning, staging, validation and activation are separate phases below; this
# orchestrates them and nothing else.
core_save() {
  # A cancelled save must say so on the progress stream and must not commit:
  # every phase below fails before the fast-forward, so exiting here leaves
  # the active repository exactly as it was.
  trap '[[ "${REPLICANT_PROCESS_GROUP:-0}" == 1 ]] || progress_result cancelled "Cancelled" ""; exit 130' INT TERM
  local _save_rc=0
  save_plan "$@" || _save_rc=$?
  if (( _save_rc )); then
    progress_result failed "Save failed before it started" ""
    trap - INT TERM
    return "$_save_rc"
  fi
  [[ -n "$SAVE_SCOPE" ]] || { trap - INT TERM; return 0; }
  save_stage || _save_rc=$?
  if (( _save_rc )); then
    progress_result failed "Save failed while scanning" ""
    trap - INT TERM
    return "$_save_rc"
  fi
  save_validate_commit || _save_rc=$?
  if (( _save_rc )); then
    progress_result failed "Save failed before the commit" ""
    trap - INT TERM
    return "$_save_rc"
  fi
  save_activate || _save_rc=$?
  trap - INT TERM
  return "$_save_rc"
}
# save_stage: run the save plan against a snapshot (staging). With commits in
# the repo this opens a transaction worktree through the shared journal: the
# journal comes first, so an unwritable journal fails before the snapshot.
# Sets SAVE_TXMODE, SAVE_BASE, SAVE_UUID, SAVE_TXDIR, SAVE_REPO and
# SAVE_ADD_PATHS for validation and activation.
save_stage() {
  [[ -e "$REPO_DIR/.git" ]] || { echo "no repo — clone first" >&2; return 1; }
  require_writable_schema || return 1
  # With no commits yet there is no history to protect and no HEAD that could
  # move mid-save, so the snapshot goes straight into the active repo, the way
  # saves always did. Anything else goes through a transaction worktree.
  SAVE_BASE=""; SAVE_TXMODE=1; SAVE_UUID=""; SAVE_TXDIR=""; SAVE_REPO="$REPO_DIR"
  if ! SAVE_BASE=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null); then
    SAVE_TXMODE=0
  fi
  if (( SAVE_TXMODE )); then
    local dirt
    dirt=$(git -C "$REPO_DIR" status --porcelain 2>/dev/null || true)
    if [[ -n "$dirt" ]]; then
      echo "save: the repo has uncommitted changes — a save needs a clean worktree:" >&2
      printf '%s\n' "$dirt" | head -n 20 | sed 's/^/    /' >&2
      echo "Review them with 'changes' or 'git -C $REPO_DIR diff'. Copies the backup" >&2
      echo "made are regenerable: 'save' writes them again from your live files." >&2
      return 1
    fi
    SAVE_UUID=$(tx_uuid)
    SAVE_TXDIR="$REPLICANT_HOME/transactions/$SAVE_UUID"
    SAVE_REPO="$SAVE_TXDIR/repo"
    mkdir -p -- "$SAVE_TXDIR" || { echo "save: cannot create a transaction directory" >&2; return 1; }
    tx_meta_write "$SAVE_TXDIR" started "$SAVE_BASE" "$SAVE_SCOPE" "$SAVE_MSG" ${SAVE_IDS[@]+"${SAVE_IDS[@]}"} || {
      tx_remove "$SAVE_TXDIR"
      return 1
    }
    echo "stage: scanning" >&2
    progress_stage scan true "Scanning"
    echo "→ save: snapshotting into a transaction worktree" >&2
    git -C "$REPO_DIR" worktree add --detach -- "$SAVE_REPO" "$SAVE_BASE" >/dev/null 2>&1 || {
      echo "save: cannot create the transaction worktree" >&2
      tx_remove "$SAVE_TXDIR"
      return 1
    }
  else
    echo "stage: scanning" >&2
    progress_stage scan true "Scanning"
    echo "→ save: snapshotting into the repo (no commits yet)" >&2
  fi

  # The snapshot effect happens once. For a selective save the stdout paths
  # are also the commit's file list; stderr keeps talking to the person.
  # In legacy mode (no commits yet) the snapshot lands in the active repo.
  SAVE_ADD_PATHS=()
  local snap_rc=0
  if [[ "$SAVE_SCOPE" == "id" ]]; then
    local id snap_tmp
    snap_tmp=$(mktemp) || { (( SAVE_TXMODE )) && tx_remove "$SAVE_TXDIR"; return 1; }
    for id in ${SAVE_IDS[@]+"${SAVE_IDS[@]}"}; do
      if (( SAVE_TXMODE )); then
        REPLICANT_TX_REPO="$SAVE_REPO" bash "$REAL_CORE" snapshot-one "$id" >"$snap_tmp" || snap_rc=1
      else
        bash "$REAL_CORE" snapshot-one "$id" >"$snap_tmp" || snap_rc=1
      fi
      (( snap_rc )) && break
      local p
      while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        case "$p" in /*|*..*) continue ;; esac
        SAVE_ADD_PATHS+=("$p")
      done < "$snap_tmp"
    done
    rm -f -- "$snap_tmp"
  else
    if (( SAVE_TXMODE )); then
      REPLICANT_TX_REPO="$SAVE_REPO" bash "$REAL_CORE" backup --for-savegame 2>&1 || snap_rc=1
    else
      bash "$REAL_CORE" backup --for-savegame 2>&1 || snap_rc=1
    fi
  fi
  if (( snap_rc )); then
    (( SAVE_TXMODE )) && tx_remove "$SAVE_TXDIR"
    return 1
  fi
  if (( SAVE_TXMODE )); then
    tx_meta_write "$SAVE_TXDIR" snapshotted "$SAVE_BASE" "$SAVE_SCOPE" "$SAVE_MSG" ${SAVE_IDS[@]+"${SAVE_IDS[@]}"} || {
      tx_remove "$SAVE_TXDIR"
      return 1
    }
  fi
  echo "stage: encrypting" >&2
  progress_stage encrypt true "Encrypting"
  return 0
}

# save_validate_commit: decide the subject, validate the snapshot and commit
# it (validation). Sets SAVE_SUBJECT, SAVE_DID_COMMIT and SAVE_CANDIDATE for
# activation. A snapshot with nothing to say is a review, not a commit: it
# removes the pre-commit journal and reports success without committing.
save_validate_commit() {
  # What the transaction holds determines the commit: everything, the
  # inventory, or exactly the named entries.
  local -a empty_check=()
  if [[ "$SAVE_SCOPE" == "id" ]]; then
    empty_check=(${SAVE_ADD_PATHS[@]+"${SAVE_ADD_PATHS[@]}"})
  elif [[ "$SAVE_SCOPE" == "inventory" ]]; then
    empty_check=(state/)
  else
    empty_check=()
  fi

  local pending
  if (( ${#empty_check[@]} )); then
    pending=$(git -C "$SAVE_REPO" status --porcelain -- "${empty_check[@]}" 2>/dev/null || true)
  else
    pending=$(git -C "$SAVE_REPO" status --porcelain -- . 2>/dev/null || true)
  fi

  SAVE_SUBJECT="$SAVE_MSG"; SAVE_DID_COMMIT=0; SAVE_CANDIDATE=""
  local machine=""
  machine=$(bash "$REAL_CORE" machine 2>/dev/null || echo unknown)
  if [[ -n "$pending" ]]; then
    if [[ -z "$SAVE_SUBJECT" && "$SAVE_AUTO" == 1 && "$SAVE_SCOPE" != "inventory" ]]; then
      SAVE_SUBJECT=$(save_auto_subject "$SAVE_REPO")
    fi
    if [[ -z "$SAVE_SUBJECT" ]]; then
      if [[ "$SAVE_SCOPE" == "id" ]]; then
        SAVE_SUBJECT="config: update ${SAVE_IDS[0]}"
      elif [[ "$SAVE_SCOPE" == "inventory" ]]; then
        # An inventory save without a message always carries the standing
        # subject, even with --auto: the commit holds state/ only, so a
        # subject derived from config paths would lie about it.
        SAVE_SUBJECT="state: $machine inventory (packages, plugins, themes)"
      else
        # Only the inventory moved: it carries its own standing subject, the
        # way bare savegame always committed it. Anything else without a
        # message is a review, not a commit.
        local nonstate
        nonstate=$(git -C "$SAVE_REPO" status --porcelain -- . ':(exclude)state/' 2>/dev/null || true)
        if [[ -z "$nonstate" ]]; then
          SAVE_SUBJECT="state: $machine inventory (packages, plugins, themes)"
        else
          local state path
          echo "── Uncommitted changes ──" >&2
          echo "Write one commit per change, and say WHY in it." >&2; echo >&2
          while read -r state path; do printf '  %s  %s\n' "$state" "$path" >&2; done <<<"$pending"; echo >&2
          for path in $(git -C "$SAVE_REPO" diff --name-only -- . ':(exclude)state/' ':(exclude)secrets/' ':(exclude)vault/' 2>/dev/null); do
            echo "── $path ──" >&2; git -C "$SAVE_REPO" diff --unified=1 -- "$path" 2>/dev/null | sed -n '5,120p' | sed 's/^/    /' >&2; echo >&2
          done
          echo "Nothing was committed. To save it: 'save --all -m \"why\"', or" >&2
          echo "'save --id <id> -m \"why\"' for one entry." >&2
          (( SAVE_TXMODE )) && tx_remove "$SAVE_TXDIR"
          return 0
        fi
      fi
    fi
    echo "→ Validating the schema and scanning for secrets" >&2
    REPLICANT_TX_REPO="$SAVE_REPO" bash "$REAL_CORE" schema-gate >/dev/null 2>&1 || {
      (( SAVE_TXMODE )) && tx_remove "$SAVE_TXDIR"
      return 1
    }
    save_scan_tx "$SAVE_REPO" || {
      (( SAVE_TXMODE )) && tx_remove "$SAVE_TXDIR"
      return 1
    }
    if [[ "$SAVE_SCOPE" == "inventory" ]]; then
      git -C "$SAVE_REPO" add -A -- state/ >/dev/null 2>&1 || {
        (( SAVE_TXMODE )) && tx_remove "$SAVE_TXDIR"
        return 1
      }
    elif (( ${#SAVE_ADD_PATHS[@]} )); then
      git -C "$SAVE_REPO" add -A -- "${SAVE_ADD_PATHS[@]}" >/dev/null 2>&1 || {
        (( SAVE_TXMODE )) && tx_remove "$SAVE_TXDIR"
        return 1
      }
    else
      git -C "$SAVE_REPO" add -A >/dev/null 2>&1 || {
        (( SAVE_TXMODE )) && tx_remove "$SAVE_TXDIR"
        return 1
      }
    fi
    # The hook scans the staged content as well when it is installed; the
    # explicit scan above already passed, so a hook failure here is about the
    # hook setup, not the content, and it must still stop the save.
    echo "stage: committing" >&2
    progress_stage commit false "Committing"
    git -C "$SAVE_REPO" commit -q -m "$SAVE_SUBJECT" || {
      echo "save: the commit failed — nothing was committed" >&2
      (( SAVE_TXMODE )) && tx_remove "$SAVE_TXDIR"
      return 1
    }
    SAVE_CANDIDATE=$(git -C "$SAVE_REPO" rev-parse HEAD 2>/dev/null) || {
      (( SAVE_TXMODE )) && tx_remove "$SAVE_TXDIR"
      return 1
    }
    SAVE_DID_COMMIT=1
    if (( SAVE_TXMODE )); then
      tx_mark_committed "$SAVE_TXDIR" "$SAVE_CANDIDATE" "$SAVE_BASE" "$SAVE_SCOPE" "$SAVE_SUBJECT" ${SAVE_IDS[@]+"${SAVE_IDS[@]}"}
    fi
    echo "→ Commit ($SAVE_SUBJECT):" >&2
    git -C "$SAVE_REPO" show --stat --oneline HEAD 2>/dev/null | sed 's/^/    /' >&2; echo >&2
    if [[ "$SAVE_SCOPE" == "inventory" ]]; then
      echo "→ Inventory commit:" >&2
    fi
  fi
  return 0
}

# save_activate: move the active repository to the candidate and publish it
# (activation). The commit point: from here the active repository moves.
# Anything that fails below keeps the transaction directory for recovery
# instead of removing it. Legacy mode (no commits yet) has nothing to
# fast-forward: the commit already landed in the active repo. A failed push
# keeps the local commit with its journal and names the retry.
save_activate() {
  local now_head
  now_head=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)
  if (( SAVE_TXMODE )) && (( SAVE_DID_COMMIT )) && [[ "$now_head" != "$SAVE_BASE" ]]; then
    echo "save: the active repo moved during the save (another save landed first)" >&2
    echo "The transaction is kept at $SAVE_TXDIR — pull, then save again." >&2
    progress_result failed "The active repo moved during the save" "omarchy-replicant pull"
    return 1
  fi
  if (( SAVE_TXMODE )) && (( SAVE_DID_COMMIT )); then
    git -C "$REPO_DIR" merge --ff-only -q "$SAVE_CANDIDATE" 2>/dev/null || {
      echo "save: cannot fast-forward the active repo (it has changes the save did not make)" >&2
      echo "The transaction is kept at $SAVE_TXDIR — resolve the worktree, then save again." >&2
      progress_result failed "Cannot fast-forward the active repo" "omarchy-replicant changes"
      return 1
    }
    tx_meta_write "$SAVE_TXDIR" fast-forwarded "$SAVE_BASE" "$SAVE_SCOPE" "$SAVE_SUBJECT" ${SAVE_IDS[@]+"${SAVE_IDS[@]}"} \
      || echo "save: warning: the fast-forward landed but the journal did not update" >&2
    save_fix_modes
  fi
  if (( SAVE_DID_COMMIT )); then
    briefcache_invalidate
  fi

  local PUSHED="" PUSH_ERR=""
  echo "stage: publishing" >&2
  progress_stage publish false "Publishing"
  save_push "$SAVE_PUSH"
  if (( SAVE_TXMODE )); then
    tx_meta_field "$SAVE_TXDIR" push "$PUSHED" \
      || echo "save: warning: the push state did not reach the journal" >&2
  fi
  if [[ "$PUSHED" == "failed" ]]; then
    echo "Saved locally, but the push to GitHub failed:" >&2
    printf '%s\n' "$PUSH_ERR" | sed 's/^/    /' >&2
    echo "Another machine may have saved first. Run 'omarchy-replicant pull', then save again." >&2
    echo "The next save (or an explicit push) retries it." >&2
    progress_result local-only "Saved locally, but the push failed" "omarchy-replicant push"
    return 1
  fi
  if (( ! SAVE_DID_COMMIT )) && [[ "$PUSHED" != "ok" ]]; then
    echo "No changes. Nothing to save." >&2
    (( SAVE_TXMODE )) && tx_remove "$SAVE_TXDIR"
    progress_result noop "No changes. Nothing to save." ""
    return 0
  fi
  (( SAVE_TXMODE )) && tx_remove "$SAVE_TXDIR"
  case "$PUSHED" in
    no-remote)
      echo "Everything saved on this machine. There is no remote yet: run 'omarchy-replicant create --push'." >&2
      progress_result local-only "Saved on this machine, no remote yet" "omarchy-replicant create --push"
      ;;
    held)
      echo "Everything saved on this machine, not pushed (--no-push)." >&2
      progress_result local-only "Saved on this machine, not pushed" "omarchy-replicant push"
      ;;
    *)
      echo "Everything saved and pushed." >&2
      progress_result success "Saved" ""
      ;;
  esac
  return 0
}

# core_init: create the initial savegame commit. The CLI parses the deprecated
# flags and reports the command result; this function owns repository writes.
# A missing repo is staged as v3 in a temp dir first: the write gate runs
# against the staged repo, never before the schema marker exists.
core_init() {
  if [[ "$(repo_state)" == missing ]]; then
    core_init_staged || return 1
  else
    require_writable_schema || return 1
  fi
  ensure_repo_layout
  core_backup || return 1
  git -C "$REPO_DIR" add -A
  if git -C "$REPO_DIR" diff --cached --quiet; then
    echo "init: nothing new" >&2
  else
    git -C "$REPO_DIR" commit -q -m "replicant: init $(date +%F) $(hostname)" || return 1
    echo "init commit" >&2
  fi
  git -C "$REPO_DIR" config core.hooksPath .githooks 2>/dev/null || true
  echo "init done at $REPO_DIR (savegame layout: config/secrets/state)" >&2
}

# core_init_staged: build a fresh v3 repo in a temp dir beside the final path
# (same parent, so the rename is atomic), validate it, and move it into place.
# Every failure removes the staging dir: a failed init leaves no repo behind.
core_init_staged() {
  local parent stage
  parent="$(dirname -- "$REPO_DIR")"
  mkdir -p -- "$parent" || return 1
  if [[ -e "$REPO_DIR" ]] && ! repo_exists; then
    if [[ -d "$REPO_DIR" ]] && [[ -z "$(ls -A -- "$REPO_DIR" 2>/dev/null)" ]]; then
      rmdir -- "$REPO_DIR" || return 1
    else
      printf 'init: %s exists but is not a git repo — move it aside, then retry\n' "$REPO_DIR" >&2
      return 1
    fi
  fi
  stage="$(mktemp -d "$parent/.replicant-init-XXXXXX")" || return 1
  if ! _core_init_build "$stage"; then
    rm -rf -- "$stage"
    return 1
  fi
  if ! bootstrap_fail_at activate; then
    rm -rf -- "$stage"
    return 1
  fi
  if ! mv -- "$stage" "$REPO_DIR"; then
    rm -rf -- "$stage"
    printf 'init: could not activate the staged repo at %s — nothing was changed\n' "$REPO_DIR" >&2
    return 1
  fi
  return 0
}

# _core_init_build <stage>: run the full layout inside the staging dir with
# the repo paths redirected, then validate the staged repo. Writes nothing
# outside the stage: the path globals set at source time are redirected too.
_core_init_build() {
  local stage="$1" rc=0
  local saved_repo="$REPO_DIR" saved_config="$CONFIG_DIR"
  local saved_state_root="$STATE_ROOT" saved_state="$STATE_DIR"
  local saved_templates="$TEMPLATES_DIR" saved_secrets="$SECRETS_DIR"
  local saved_hooks="$GITHOOKS_DIR" saved_track="$USER_TRACK_FILE"
  local saved_version="$REPO_VERSION_FILE" saved_scope="$SCOPE_FILE"
  if ! bootstrap_fail_at validate; then
    return 1
  fi
  REPO_DIR="$stage" CONFIG_DIR="$stage/config"
  STATE_ROOT="$stage/state" STATE_DIR="$stage/state/$MACHINE"
  TEMPLATES_DIR="$stage/templates" SECRETS_DIR="$stage/secrets"
  GITHOOKS_DIR="$stage/.githooks"
  USER_TRACK_FILE="$stage/.replicant-track"
  REPO_VERSION_FILE="$stage/.replicant-version"
  SCOPE_FILE="$stage/.replicant-sync"
  if ! ensure_repo_layout; then
    rc=1
  elif ! _schema_marker_valid; then
    rc=1
  elif ! v3_no_legacy_files; then
    rc=1
  elif ! validate_v3_entries "$stage/.replicant/entries.json"; then
    rc=1
  fi
  REPO_DIR="$saved_repo" CONFIG_DIR="$saved_config"
  STATE_ROOT="$saved_state_root" STATE_DIR="$saved_state"
  TEMPLATES_DIR="$saved_templates" SECRETS_DIR="$saved_secrets"
  GITHOOKS_DIR="$saved_hooks" USER_TRACK_FILE="$saved_track"
  REPO_VERSION_FILE="$saved_version" SCOPE_FILE="$saved_scope"
  return "$rc"
}
