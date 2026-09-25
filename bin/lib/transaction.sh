# shellcheck shell=bash disable=SC2034
# transaction.sh: one transaction engine for every repository mutation.
# Sourced by replicant-core.sh, which sets the paths it uses. It defines
# functions and data and runs nothing.
#
# Save and bulk snapshot live state into a detached worktree under
# $REPLICANT_HOME/transactions/<uuid>/repo, commit there, verify that the
# active HEAD has not moved since, fast-forward to the candidate, push, and
# remove the worktree. Any failure before the fast-forward leaves the active
# repository exactly as it was; a transaction that already committed is never
# discarded automatically, so doctor can offer to resume or drop it.
#
# Shape writes (sync, scope, policy, track, untrack, forget, recover, profile,
# key recipient) commit only their own paths directly in the active worktree.
# They never require a clean tree: a scope change must not swallow an unrelated
# pending edit into its commit, and it must succeed while one is pending. What
# they share with save and bulk is the journal discipline: the journal is
# created before the candidate commit, every journal write is atomic
# (temporary file plus rename), a journal that cannot be written fails the
# mutation before anything is committed, and a failed push keeps the local
# commit with its journal and names the retry.
#
# Journal writes after the commit point (candidate, push marks) warn instead of
# failing: the repository already moved, so a journal error there must not
# report the mutation as failed. The candidate stays derivable from HEAD, and
# the next command retries the push.

# tx_uuid: a random transaction directory name.
tx_uuid() {
  local u
  if u=$(tr -dc 'a-f0-9' </dev/urandom 2>/dev/null | head -c 16); then
    [[ -n "$u" ]] && { printf '%s\n' "$u"; return 0; }
  fi
  printf '%s-%s\n' "$(date +%s)" "$$"
  return 0
}

# tx_meta_write <txdir> <stage> <base> <scope> <msg> [ids...]: record the
# transaction stage in meta.json, keeping the fields written at earlier
# stages. Fatal: a journal that cannot be written fails the mutation, so call
# this before the candidate commit exists. Always through a temporary file
# plus rename, for both creation and update.
tx_meta_write() {
  local txdir="$1" stage="$2" base="$3" scope="$4" msg="$5"
  shift 5
  local meta tmp ids_json
  meta="$txdir/meta.json"
  tmp="$txdir/.meta.json.tmp.$$"
  mkdir -p -- "$txdir" || {
    echo "transaction: cannot create the journal directory $txdir" >&2
    return 1
  }
  ids_json=$(printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0))' 2>/dev/null) || {
    echo "transaction: cannot record the journal ids for $txdir" >&2
    rm -f -- "$tmp"
    return 1
  }
  if [[ -f "$meta" ]]; then
    jq -c --arg stage "$stage" '.stage = $stage' -- "$meta" 2>/dev/null > "$tmp" || {
      echo "transaction: cannot update the journal stage for $txdir" >&2
      rm -f -- "$tmp"
      return 1
    }
  else
    jq -nc --arg stage "$stage" --arg base "$base" --arg scope "$scope" \
      --arg msg "$msg" --argjson ids "$ids_json" \
      '{version: 1, base: $base, scope: $scope, ids: $ids, msg: $msg,
        stage: $stage, candidate: null, push: null}' > "$tmp" 2>/dev/null || {
      echo "transaction: cannot create the journal for $txdir" >&2
      rm -f -- "$tmp"
      return 1
    }
  fi
  mv -f -- "$tmp" "$meta" || {
    echo "transaction: cannot publish the journal for $txdir" >&2
    rm -f -- "$tmp"
    return 1
  }
  return 0
}

# tx_meta_field <txdir> <field> <value>: set one journal field (candidate,
# push). Fatal like tx_meta_write: the caller decides whether a post-commit
# mark failure aborts (before the commit point) or warns (after it moved).
tx_meta_field() {
  local txdir="$1" field="$2" value="$3" meta tmp
  meta="$txdir/meta.json"
  tmp="$txdir/.meta.json.tmp.$$"
  [[ -f "$meta" ]] || {
    echo "transaction: no journal at $txdir" >&2
    return 1
  }
  jq -c --arg field "$field" --arg value "$value" '.[$field] = $value' \
    -- "$meta" 2>/dev/null > "$tmp" || {
    echo "transaction: cannot update the journal field $field for $txdir" >&2
    rm -f -- "$tmp"
    return 1
  }
  mv -f -- "$tmp" "$meta" || {
    echo "transaction: cannot publish the journal for $txdir" >&2
    rm -f -- "$tmp"
    return 1
  }
  return 0
}

# tx_remove <txdir>: drop a transaction worktree and its journal. Only for
# transactions that never committed, or for ones whose push succeeded: a
# committed transaction with a failed push stays for recovery and is never
# removed here.
tx_remove() {
  local txdir="$1" txrepo
  txrepo="$txdir/repo"
  if [[ -d "$txrepo" || -f "$txrepo" ]]; then
    git -C "$REPO_DIR" worktree remove --force -- "$txrepo" 2>/dev/null || rm -rf -- "$txrepo" 2>/dev/null || true
    git -C "$REPO_DIR" worktree prune 2>/dev/null || true
  fi
  rm -rf -- "$txdir" 2>/dev/null || true
  return 0
}

# tx_root: the directory that holds transaction journals and worktrees. Always
# under REPLICANT_HOME, never redirected by REPLICANT_TX_REPO.
tx_root() {
  printf '%s/transactions\n' "$REPLICANT_HOME"
}

# core_tx_list: one tab-separated row per transaction for doctor and for the
# person: uuid, stage, base, scope, candidate, push, msg. Prints nothing when
# none are present. Read-only: it never touches the repo.
core_tx_list() {
  local root txdir meta uuid stage base scope candidate push msg
  root=$(tx_root)
  [[ -d "$root" ]] || return 0
  for txdir in "$root"/*/; do
    [[ -d "$txdir" ]] || continue
    meta="${txdir}meta.json"
    [[ -f "$meta" ]] || continue
    uuid=$(basename "$txdir")
    stage=$(jq -r '.stage // "unknown"' -- "$meta" 2>/dev/null || echo unknown)
    base=$(jq -r '.base // ""' -- "$meta" 2>/dev/null || echo "")
    scope=$(jq -r '.scope // ""' -- "$meta" 2>/dev/null || echo "")
    candidate=$(jq -r '.candidate // ""' -- "$meta" 2>/dev/null || echo "")
    [[ "$candidate" == "null" ]] && candidate=""
    push=$(jq -r '.push // ""' -- "$meta" 2>/dev/null || echo "")
    [[ "$push" == "null" ]] && push=""
    msg=$(jq -r '.msg // ""' -- "$meta" 2>/dev/null || echo "")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$uuid" "$stage" "$base" "$scope" "$candidate" "$push" "$msg"
  done
  return 0
}

# core_tx_discard <uuid> [--force]: drop one transaction. A pre-commit journal
# (started, snapshotted) goes directly. A committed one holds a commit the
# active repo may not have, so it needs --force and says so, because discarding
# it drops that commit.
core_tx_discard() {
  local uuid="${1:-}" force=0 a
  for a in "$@"; do [[ "$a" == "--force" ]] && force=1; done
  [[ -n "$uuid" ]] || { echo "tx-discard: usage: tx-discard <uuid> [--force]" >&2; return 2; }
  case "$uuid" in *..*|*/*) echo "tx-discard: invalid id: $uuid" >&2; return 2 ;; esac
  local txdir meta stage
  txdir="$(tx_root)/$uuid"
  meta="$txdir/meta.json"
  [[ -f "$meta" ]] || { echo "tx-discard: no transaction $uuid" >&2; return 1; }
  stage=$(jq -r '.stage // "unknown"' -- "$meta" 2>/dev/null || echo unknown)
  if [[ "$stage" == "committed" || "$stage" == "fast-forwarded" ]]; then
    if (( ! force )); then
      echo "tx-discard: $uuid already committed ($stage) — resume it with 'tx resume $uuid'," >&2
      echo "or discard the commit with 'tx discard $uuid --force'" >&2
      return 1
    fi
  fi
  tx_remove "$txdir"
  briefcache_invalidate 2>/dev/null || true
  echo "discarded transaction $uuid ($stage)" >&2
  return 0
}

# core_tx_resume <uuid>: finish one committed transaction. Inspects the actual
# repository, not only the journal: the candidate commit must still exist as an
# object (a pruned or hand-removed worktree leaves a journal that points at
# nothing), and the active HEAD decides the path. A pre-commit journal has no
# candidate, so there is nothing to resume: discard it and save again.
core_tx_resume() {
  local uuid="${1:-}"
  [[ -n "$uuid" ]] || { echo "tx-resume: usage: tx-resume <uuid>" >&2; return 2; }
  case "$uuid" in *..*|*/*) echo "tx-resume: invalid id: $uuid" >&2; return 2 ;; esac
  local txdir meta stage base candidate push_state msg
  txdir="$(tx_root)/$uuid"
  meta="$txdir/meta.json"
  [[ -f "$meta" ]] || { echo "tx-resume: no transaction $uuid" >&2; return 1; }
  stage=$(jq -r '.stage // "unknown"' -- "$meta" 2>/dev/null || echo unknown)
  base=$(jq -r '.base // ""' -- "$meta" 2>/dev/null || echo "")
  candidate=$(jq -r '.candidate // ""' -- "$meta" 2>/dev/null || echo "")
  [[ "$candidate" == "null" ]] && candidate=""
  msg=$(jq -r '.msg // ""' -- "$meta" 2>/dev/null || echo "")
  if [[ -z "$candidate" ]]; then
    echo "tx-resume: $uuid never committed (stage $stage) — nothing to resume." >&2
    echo "Discard it with 'tx discard $uuid', then save again." >&2
    return 1
  fi
  [[ -e "$REPO_DIR/.git" ]] || { echo "no repo — clone first" >&2; return 1; }
  if ! git -C "$REPO_DIR" cat-file -e "$candidate" 2>/dev/null; then
    echo "tx-resume: $uuid names commit $candidate, which is not in the repository." >&2
    echo "Its worktree is gone or the commit was pruned — the journal is kept at $txdir," >&2
    echo "and only 'tx discard $uuid --force' removes it." >&2
    return 1
  fi
  if [[ ! -d "$txdir/repo" && "$stage" != "fast-forwarded" ]]; then
    echo "tx-resume: $uuid lost its worktree — resuming from the stored commit instead." >&2
  fi
  local now_head
  now_head=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo "")
  if [[ "$now_head" == "$candidate" ]]; then
    echo "tx-resume: $uuid is already in the active repo — pushing it again." >&2
  else
    if [[ "$now_head" != "$base" ]]; then
      echo "tx-resume: the active repo moved since the transaction started." >&2
      echo "The transaction is kept at $txdir — pull, then save again." >&2
      return 1
    fi
    git -C "$REPO_DIR" merge --ff-only -q "$candidate" 2>/dev/null || {
      echo "tx-resume: cannot fast-forward the active repo (it has changes the save did not make)" >&2
      echo "The transaction is kept at $txdir — resolve the worktree, then resume again." >&2
      return 1
    }
    tx_meta_write "$txdir" fast-forwarded "$base" "" "$msg" \
      || echo "tx-resume: warning: the fast-forward landed but the journal did not update" >&2
    save_fix_modes
    briefcache_invalidate 2>/dev/null || true
  fi
  local PUSHED="" PUSH_ERR=""
  save_push 1
  tx_meta_field "$txdir" push "$PUSHED" \
    || echo "tx-resume: warning: the push state did not reach the journal" >&2
  if [[ "$PUSHED" == "failed" ]]; then
    echo "Saved locally, but the push to GitHub failed:" >&2
    printf '%s\n' "$PUSH_ERR" | sed 's/^/    /' >&2
    echo "Another machine may have saved first. Run 'omarchy-replicant pull', then push again." >&2
    echo "The transaction is kept at $txdir — push again to retry." >&2
    return 1
  fi
  tx_remove "$txdir"
  case "$PUSHED" in
    no-remote) echo "Resumed and saved on this machine. There is no remote yet: run 'omarchy-replicant create --push'." >&2 ;;
    *) echo "Resumed transaction $uuid and pushed." >&2 ;;
  esac
  return 0
}

# tx_require_clean <context>: refuse when the active worktree holds uncommitted
# changes. Worktree transactions snapshot from HEAD, so every copy in a dirty
# tree is either regenerable (save writes it again) or a review in progress.
tx_require_clean() {
  local context="$1" dirt
  dirt=$(git -C "$REPO_DIR" status --porcelain 2>/dev/null || true)
  if [[ -n "$dirt" ]]; then
    echo "$context: the repo has uncommitted changes — it needs a clean worktree:" >&2
    printf '%s\n' "$dirt" | head -n 20 | sed 's/^/    /' >&2
    echo "Review them with 'changes' or 'git -C $REPO_DIR diff'. Copies the backup" >&2
    echo "made are regenerable: a worktree transaction writes them again from your live files." >&2
    return 1
  fi
  return 0
}

# tx_begin <scope> <msg> [ids...]: start a worktree transaction. Requires a
# repo with one commit and a clean worktree, creates the journal first (fatal),
# then the detached worktree. Sets TX_UUID, TX_DIR, TX_BASE and TX_REPO for the
# caller. A repo with no commits yet has no history to protect: the caller
# saves inline instead of calling this.
tx_begin() {
  local scope="$1" msg="$2"
  shift 2
  TX_UUID=""; TX_DIR=""; TX_BASE=""; TX_REPO=""
  [[ -e "$REPO_DIR/.git" ]] || { echo "no repo — clone first" >&2; return 1; }
  TX_BASE=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)
  [[ -n "$TX_BASE" ]] || { echo "a transaction needs a repository with one commit" >&2; return 1; }
  tx_require_clean "transaction" || return 1
  TX_UUID=$(tx_uuid)
  TX_DIR="$(tx_root)/$TX_UUID"
  TX_REPO="$TX_DIR/repo"
  mkdir -p -- "$TX_DIR" || { echo "transaction: cannot create the transaction directory" >&2; return 1; }
  tx_meta_write "$TX_DIR" started "$TX_BASE" "$scope" "$msg" "$@" || {
    tx_remove "$TX_DIR"
    return 1
  }
  git -C "$REPO_DIR" worktree add --detach -- "$TX_REPO" "$TX_BASE" >/dev/null 2>&1 || {
    echo "transaction: cannot create the transaction worktree" >&2
    tx_remove "$TX_DIR"
    return 1
  }
  return 0
}

# tx_mark_committed <txdir> <candidate> <base> <scope> <subject> [ids...]:
# record a candidate commit in the journal. Warn-only: past this point the
# commit exists, so a journal error must not report the mutation as failed.
tx_mark_committed() {
  local txdir="$1" candidate="$2" base="$3" scope="$4" subject="$5"
  shift 5
  tx_meta_field "$txdir" candidate "$candidate" \
    || echo "transaction: warning: the candidate did not reach the journal" >&2
  tx_meta_write "$txdir" committed "$base" "$scope" "$subject" "$@" \
    || echo "transaction: warning: the commit landed but the journal did not update" >&2
  return 0
}

# tx_activate <txdir> <candidate> <base>: the commit point. Verifies the active
# HEAD is still the base, fast-forwards to the candidate, and records it.
# Anything that fails here keeps the transaction for recovery.
tx_activate() {
  local txdir="$1" candidate="$2" base="$3" now_head
  now_head=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)
  if [[ "$now_head" != "$base" ]]; then
    echo "transaction: the active repo moved during the transaction (another save landed first)" >&2
    echo "The transaction is kept at $txdir — pull, then save again." >&2
    return 1
  fi
  git -C "$REPO_DIR" merge --ff-only -q "$candidate" 2>/dev/null || {
    echo "transaction: cannot fast-forward the active repo (it has changes the transaction did not make)" >&2
    echo "The transaction is kept at $txdir — resolve the worktree, then save again." >&2
    return 1
  }
  tx_meta_write "$txdir" fast-forwarded "$base" "" "" \
    || echo "transaction: warning: the fast-forward landed but the journal did not update" >&2
  save_fix_modes
  return 0
}

# tx_abort <txdir>: drop a transaction that never committed (a relay or a
# validation failed before the candidate commit). Committed work is never
# aborted: use tx discard --force for that, by hand.
tx_abort() {
  tx_remove "$1"
  return 0
}

# tx_atomic_install <src> <dest> <mode>: copy one file atomically with an exact
# mode. Writes a temporary file in the destination directory and renames it
# over, so a reader never sees a half-written key. Fails loudly.
tx_atomic_install() {
  local src="$1" dest="$2" mode="$3" dir tmp
  [[ -n "$src" && -n "$dest" && -n "$mode" ]] || {
    echo "transaction: atomic install needs a source, a destination and a mode" >&2
    return 1
  }
  [[ -f "$src" ]] || { echo "transaction: no source file at $src" >&2; return 1; }
  dir="$(dirname -- "$dest")"
  mkdir -p -- "$dir" || { echo "transaction: cannot create $dir" >&2; return 1; }
  tmp="$dir/.install.tmp.$$"
  rm -f -- "$tmp"
  cp -f -- "$src" "$tmp" || { echo "transaction: cannot stage $dest" >&2; rm -f -- "$tmp"; return 1; }
  chmod "$mode" -- "$tmp" || { echo "transaction: cannot set mode $mode on $dest" >&2; rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$dest" || { echo "transaction: cannot publish $dest" >&2; rm -f -- "$tmp"; return 1; }
  return 0
}

# tx_shape_begin <scope> <msg> [ids...]: open the journal for a shape write
# (a direct commit of selected paths in the active worktree). The journal comes
# before any commit: when it cannot be written the mutation never runs. Sets
# TX_DIR and TX_BASE for tx_shape_commit and tx_shape_finish.
tx_shape_begin() {
  local scope="$1" msg="$2"
  shift 2
  TX_UUID=""; TX_DIR=""; TX_BASE=""
  [[ -e "$REPO_DIR/.git" ]] || { echo "no repo — clone first" >&2; return 1; }
  TX_BASE=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)
  TX_UUID=$(tx_uuid)
  TX_DIR="$(tx_root)/$TX_UUID"
  tx_meta_write "$TX_DIR" started "$TX_BASE" "$scope" "$msg" "$@" || {
    tx_remove "$TX_DIR" 2>/dev/null || true
    return 1
  }
  return 0
}

# tx_shape_commit <msg> <txdir> -- <paths...>: stage exactly the given paths
# and commit them as one commit. Stages nothing else, so an unrelated pending
# edit stays pending. A git add or commit failure aborts loudly: ignored
# failures once committed an untrack nowhere while reporting success. Commits
# only the staged subset (never a bare pathspec): a path that stages nothing
# makes git commit fail with "pathspec did not match", which is how the silent
# failure happened. Prints the candidate commit on success, and nothing when
# the relay changed none of the paths (the journal is dropped then).
tx_shape_commit() {
  local msg="$1" txdir="$2"
  shift 2
  [[ "${1:-}" == "--" ]] && shift
  (( $# )) || { echo "transaction: a shape commit needs paths" >&2; tx_abort "$txdir"; return 2; }
  local -a paths=("$@") existing=() staged=()
  local p line
  # Stage only what exists on disk or in the index. A pathspec that matches
  # nothing makes git add fail, and the legacy stores (.replicant-sync,
  # .replicant-track) are absent from v3 repositories by design.
  for p in "${paths[@]}"; do
    if [[ -e "$REPO_DIR/${p%/}" ]] || [[ -n "$(git -C "$REPO_DIR" ls-files -- "$p" 2>/dev/null)" ]]; then
      existing+=("$p")
    fi
  done
  (( ${#existing[@]} )) || { tx_abort "$txdir"; return 0; }
  git -C "$REPO_DIR" add -A -- "${existing[@]}" >/dev/null 2>&1 || {
    echo "transaction: could not stage the change — nothing was committed" >&2
    tx_abort "$txdir"
    return 1
  }
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    staged+=("$line")
  done < <(git -C "$REPO_DIR" diff --cached --name-only --no-renames -z -- "${existing[@]}" 2>/dev/null | tr '\0' '\n')
  # --no-renames matters: with rename detection a moved copy lists only its
  # destination, and the source deletion would stay staged but uncommitted.
  if (( ${#staged[@]} == 0 )); then
    tx_abort "$txdir"
    return 0
  fi
  local candidate
  progress_stage commit false "Committing"
  git -C "$REPO_DIR" commit -q -m "$msg" -- "${staged[@]}" >/dev/null 2>&1 || {
    echo "transaction: the commit failed — nothing was committed" >&2
    tx_abort "$txdir"
    return 1
  }
  candidate=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null) || {
    echo "transaction: the commit landed but its id is unreadable" >&2
    tx_abort "$txdir"
    return 1
  }
  tx_meta_field "$txdir" candidate "$candidate" \
    || echo "transaction: warning: the candidate did not reach the journal" >&2
  printf '%s\n' "$candidate"
  return 0
}

# tx_shape_finish <txdir>: push a shape commit. With no remote there is
# nowhere to push, which is not a failure: the journal goes and the commit
# stays, the way save reports its no-remote outcome. A failed push keeps the
# local commit with its journal and names the retry; anything else removes the
# journal and reports the outcome, the way save reports its push.
tx_shape_finish() {
  local txdir="$1" push_err
  if ! git -C "$REPO_DIR" remote get-url origin >/dev/null 2>&1; then
    tx_meta_field "$txdir" push "no-remote" \
      || echo "transaction: warning: the push state did not reach the journal" >&2
    tx_remove "$txdir"
    briefcache_invalidate 2>/dev/null || true
    progress_result local-only "Saved on this machine, no remote yet" "omarchy-replicant create --push"
    return 0
  fi
  progress_stage publish false "Publishing"
  if ! push_err=$(git -C "$REPO_DIR" push -q 2>&1); then
    tx_meta_field "$txdir" push "failed" \
      || echo "transaction: warning: the push state did not reach the journal" >&2
    echo "Saved locally, but the push to GitHub failed:" >&2
    printf '%s\n' "$push_err" | sed 's/^/    /' >&2
    echo "Another machine may have saved first. Run 'omarchy-replicant pull', then push again." >&2
    echo "The next save (or an explicit push) retries it." >&2
    briefcache_invalidate 2>/dev/null || true
    progress_result local-only "Saved locally, but the push failed" "omarchy-replicant push"
    return 1
  fi
  tx_meta_field "$txdir" push "ok" \
    || echo "transaction: warning: the push state did not reach the journal" >&2
  tx_remove "$txdir"
  briefcache_invalidate 2>/dev/null || true
  progress_result success "Saved" ""
  return 0
}

# tx_shape_policy_paths: the policy stores every shape commit stages beside
# its entry paths: the legacy track, sync and profile files (absent from v3
# repositories by design, so tx_shape_commit skips them there) plus the v3
# entries record and the vault index. One list so the shape transactions in
# scopes, track and history cannot drift apart.
tx_shape_policy_paths() {
  printf '%s\n' .replicant-track .replicant-sync .replicant-profiles \
    .replicant/entries.json vault/index.age
}

# core_shape_transact <msg> <scope> <relay> [relay-args...] -- <paths...>:
# run one shape mutation as a transaction: the journal first, then the relay
# (a core mutator that writes the active worktree), then one commit of exactly
# the given paths, then the push. A relay failure removes the pre-commit
# journal and reports the relay error; the relay itself changed only
# uncommitted files, which the person reviews with changes. Shape writes never
# take a worktree: they must succeed beside unrelated pending edits.
core_shape_transact() {
  local msg="$1" scope="$2" relay="$3"
  shift 3
  local -a relay_args=() paths=()
  local seen_sep=0 a
  for a in "$@"; do
    if [[ "$a" == "--" ]]; then seen_sep=1; continue; fi
    if (( seen_sep )); then paths+=("$a"); else relay_args+=("$a"); fi
  done
  (( ${#paths[@]} )) || { echo "transaction: a shape transaction needs commit paths" >&2; return 2; }
  tx_shape_begin "$scope" "$msg" || return 1
  local txdir="$TX_DIR" candidate
  "$relay" ${relay_args[@]+"${relay_args[@]}"} || {
    tx_abort "$txdir"
    return 1
  }
  candidate=$(tx_shape_commit "$msg" "$txdir" -- "${paths[@]}") || return 1
  if [[ -z "$candidate" ]]; then
    progress_result noop "No changes" ""
    return 0
  fi
  tx_shape_finish "$txdir" || return 1
  return 0
}
