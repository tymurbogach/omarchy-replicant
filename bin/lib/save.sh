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
# stages. Best effort: a journal that cannot be written never fails the save.
tx_meta_write() {
  local txdir="$1" stage="$2" base="$3" scope="$4" msg="$5"
  shift 5
  local meta ids_json
  meta="$txdir/meta.json"
  ids_json=$(printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0))' 2>/dev/null || echo "[]")
  if [[ -f "$meta" ]]; then
    jq -c --arg stage "$stage" '.stage = $stage' -- "$meta" 2>/dev/null > "$meta.new" \
      && mv -f -- "$meta.new" "$meta" 2>/dev/null
  else
    jq -nc --arg stage "$stage" --arg base "$base" --arg scope "$scope" \
      --arg msg "$msg" --argjson ids "$ids_json" \
      '{version: 1, base: $base, scope: $scope, ids: $ids, msg: $msg,
        stage: $stage, candidate: null, push: null}' > "$meta" 2>/dev/null
  fi
  return 0
}

# tx_meta_field <txdir> <field> <value>: set one journal field (candidate, push).
tx_meta_field() {
  local txdir="$1" field="$2" value="$3" meta
  meta="$txdir/meta.json"
  [[ -f "$meta" ]] || return 0
  jq -c --arg field "$field" --arg value "$value" '.[$field] = $value' \
    -- "$meta" 2>/dev/null > "$meta.new" \
    && mv -f -- "$meta.new" "$meta" 2>/dev/null
  return 0
}

# tx_remove <txdir>: drop an uncommitted transaction worktree and its journal.
# Only for transactions that never committed: a committed one stays for
# recovery and is never removed here.
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

# tx_root: the directory that holds abandoned transaction worktrees. Always
# under REPLICANT_HOME, never redirected by REPLICANT_TX_REPO.
tx_root() {
  printf '%s/transactions\n' "$REPLICANT_HOME"
}

# core_tx_list: one tab-separated row per abandoned transaction for doctor and
# for the person: uuid, stage, base, scope, candidate, push, msg. Prints
# nothing when none are present. Read-only: it never touches the repo.
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

# core_tx_discard <uuid> [--force]: drop one abandoned transaction. A
# pre-commit journal (started, snapshotted) goes directly. A committed one
# holds a commit the active repo does not have, so it needs --force and says
# so, because discarding it drops that commit.
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

# core_tx_resume <uuid>: finish one abandoned committed transaction. Verifies
# the active HEAD is still the base, fast-forwards to the candidate, pushes,
# and removes the worktree on success. A pre-commit journal has no candidate,
# so there is nothing to resume: discard it and save again.
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
    tx_meta_write "$txdir" fast-forwarded "$base" "" "$msg"
    save_fix_modes
    briefcache_invalidate 2>/dev/null || true
  fi
  local PUSHED="" PUSH_ERR=""
  save_push 1
  tx_meta_field "$txdir" push "$PUSHED"
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

# core_save [--all|--inventory|--id <id>...] [-m <msg>|--auto] [--no-push]:
# one transaction, one commit. The active worktree must be clean: every copy
# in it is regenerable from live files, so there is nothing to carry over.
core_save() {
  local scope="" msg="" auto=0 push=1
  local -a ids=()
  while (( $# )); do
    case "$1" in
      --all) scope="all"; shift ;;
      --inventory) scope="inventory"; shift ;;
      --id) [[ -n "${2:-}" ]] || { echo "save: --id needs an entry id" >&2; return 2; }; scope="id"; ids+=("$2"); shift 2 ;;
      -m|--message) [[ -n "${2:-}" ]] || { echo "save: -m needs a message" >&2; return 2; }; msg="$2"; shift 2 ;;
      --auto|-a) auto=1; shift ;;
      --no-push) push=0; shift ;;
      -h|--help) echo "save [--all] [--id <id> ...] [--inventory] [-m \"why\" | --auto] [--no-push]" >&2; return 0 ;;
      *) echo "save: unknown option: $1" >&2; return 2 ;;
    esac
  done
  if [[ -z "$scope" ]]; then
    scope="all"
  fi
  if [[ "$scope" == "id" && ${#ids[@]} == 0 ]]; then
    echo "save: --id needs an entry id" >&2; return 2
  fi
  [[ -e "$REPO_DIR/.git" ]] || { echo "no repo — clone first" >&2; return 1; }
  require_writable_schema || return 1
  # With no commits yet there is no history to protect and no HEAD that could
  # move mid-save, so the snapshot goes straight into the active repo, the way
  # saves always did. Anything else goes through a transaction worktree.
  local base="" txmode=1 uuid="" txdir="" saverepo="$REPO_DIR"
  if ! base=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null); then
    txmode=0
  fi
  if (( txmode )); then
    local dirt
    dirt=$(git -C "$REPO_DIR" status --porcelain 2>/dev/null || true)
    if [[ -n "$dirt" ]]; then
      echo "save: the repo has uncommitted changes — a save needs a clean worktree:" >&2
      printf '%s\n' "$dirt" | head -n 20 | sed 's/^/    /' >&2
      echo "Review them with 'changes' or 'git -C $REPO_DIR diff'. Copies the backup" >&2
      echo "made are regenerable: 'save' writes them again from your live files." >&2
      return 1
    fi
    uuid=$(tx_uuid)
    txdir="$REPLICANT_HOME/transactions/$uuid"
    saverepo="$txdir/repo"
    mkdir -p -- "$txdir" || { echo "save: cannot create a transaction directory" >&2; return 1; }
    tx_meta_write "$txdir" started "$base" "$scope" "$msg" ${ids[@]+"${ids[@]}"}
    echo "stage: scanning" >&2
    echo "→ save: snapshotting into a transaction worktree" >&2
    git -C "$REPO_DIR" worktree add --detach -- "$saverepo" "$base" >/dev/null 2>&1 || {
      echo "save: cannot create the transaction worktree" >&2
      tx_remove "$txdir"
      return 1
    }
  else
    echo "stage: scanning" >&2
    echo "→ save: snapshotting into the repo (no commits yet)" >&2
  fi

  # The snapshot effect happens once. For a selective save the stdout paths
  # are also the commit's file list; stderr keeps talking to the person.
  # In legacy mode (no commits yet) the snapshot lands in the active repo.
  local -a add_paths=()
  local snap_rc=0
  if [[ "$scope" == "id" ]]; then
    local id snap_tmp
    snap_tmp=$(mktemp) || { (( txmode )) && tx_remove "$txdir"; return 1; }
    for id in "${ids[@]}"; do
      if (( txmode )); then
        REPLICANT_TX_REPO="$saverepo" bash "$REAL_CORE" snapshot-one "$id" >"$snap_tmp" || snap_rc=1
      else
        bash "$REAL_CORE" snapshot-one "$id" >"$snap_tmp" || snap_rc=1
      fi
      (( snap_rc )) && break
      local p
      while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        case "$p" in /*|*..*) continue ;; esac
        add_paths+=("$p")
      done < "$snap_tmp"
    done
    rm -f -- "$snap_tmp"
  else
    if (( txmode )); then
      REPLICANT_TX_REPO="$saverepo" bash "$REAL_CORE" backup --for-savegame 2>&1 || snap_rc=1
    else
      bash "$REAL_CORE" backup --for-savegame 2>&1 || snap_rc=1
    fi
  fi
  if (( snap_rc )); then
    (( txmode )) && tx_remove "$txdir"
    return 1
  fi
  (( txmode )) && tx_meta_write "$txdir" snapshotted "$base" "$scope" "$msg" ${ids[@]+"${ids[@]}"}
  echo "stage: encrypting" >&2

  # What the transaction holds determines the commit: everything, the
  # inventory, or exactly the named entries.
  local -a empty_check=()
  if [[ "$scope" == "id" ]]; then
    empty_check=(${add_paths[@]+"${add_paths[@]}"})
  elif [[ "$scope" == "inventory" ]]; then
    empty_check=(state/)
  else
    empty_check=()
  fi

  local pending
  if (( ${#empty_check[@]} )); then
    pending=$(git -C "$saverepo" status --porcelain -- "${empty_check[@]}" 2>/dev/null || true)
  else
    pending=$(git -C "$saverepo" status --porcelain -- . 2>/dev/null || true)
  fi

  local subject="$msg" did_commit=0 candidate="" machine=""
  machine=$(bash "$REAL_CORE" machine 2>/dev/null || echo unknown)
  if [[ -n "$pending" ]]; then
    if [[ -z "$subject" && "$auto" == 1 && "$scope" != "inventory" ]]; then
      subject=$(save_auto_subject "$saverepo")
    fi
    if [[ -z "$subject" ]]; then
      if [[ "$scope" == "id" ]]; then
        subject="config: update ${ids[0]}"
      elif [[ "$scope" == "inventory" ]]; then
        # An inventory save without a message always carries the standing
        # subject, even with --auto: the commit holds state/ only, so a
        # subject derived from config paths would lie about it.
        subject="state: $machine inventory (packages, plugins, themes)"
      else
        # Only the inventory moved: it carries its own standing subject, the
        # way bare savegame always committed it. Anything else without a
        # message is a review, not a commit.
        local nonstate
        nonstate=$(git -C "$saverepo" status --porcelain -- . ':(exclude)state/' 2>/dev/null || true)
        if [[ -z "$nonstate" ]]; then
          subject="state: $machine inventory (packages, plugins, themes)"
        else
          local state path
          echo "── Uncommitted changes ──" >&2
          echo "Write one commit per change, and say WHY in it." >&2; echo >&2
          while read -r state path; do printf '  %s  %s\n' "$state" "$path" >&2; done <<<"$pending"; echo >&2
          for path in $(git -C "$saverepo" diff --name-only -- . ':(exclude)state/' ':(exclude)secrets/' ':(exclude)vault/' 2>/dev/null); do
            echo "── $path ──" >&2; git -C "$saverepo" diff --unified=1 -- "$path" 2>/dev/null | sed -n '5,120p' | sed 's/^/    /' >&2; echo >&2
          done
          echo "Nothing was committed. To save it: 'save --all -m \"why\"', or" >&2
          echo "'save --id <id> -m \"why\"' for one entry." >&2
          (( txmode )) && tx_remove "$txdir"
          return 0
        fi
      fi
    fi
    echo "→ Validating the schema and scanning for secrets" >&2
    REPLICANT_TX_REPO="$saverepo" bash "$REAL_CORE" schema-gate >/dev/null 2>&1 || {
      (( txmode )) && tx_remove "$txdir"
      return 1
    }
    save_scan_tx "$saverepo" || {
      (( txmode )) && tx_remove "$txdir"
      return 1
    }
    if [[ "$scope" == "inventory" ]]; then
      git -C "$saverepo" add -A -- state/ >/dev/null 2>&1 || {
        (( txmode )) && tx_remove "$txdir"
        return 1
      }
    elif (( ${#add_paths[@]} )); then
      git -C "$saverepo" add -A -- "${add_paths[@]}" >/dev/null 2>&1 || {
        (( txmode )) && tx_remove "$txdir"
        return 1
      }
    else
      git -C "$saverepo" add -A >/dev/null 2>&1 || {
        (( txmode )) && tx_remove "$txdir"
        return 1
      }
    fi
    # The hook scans the staged content as well when it is installed; the
    # explicit scan above already passed, so a hook failure here is about the
    # hook setup, not the content, and it must still stop the save.
    echo "stage: committing" >&2
    git -C "$saverepo" commit -q -m "$subject" || {
      echo "save: the commit failed — nothing was committed" >&2
      (( txmode )) && tx_remove "$txdir"
      return 1
    }
    candidate=$(git -C "$saverepo" rev-parse HEAD 2>/dev/null) || {
      (( txmode )) && tx_remove "$txdir"
      return 1
    }
    did_commit=1
    tx_meta_field "$txdir" candidate "$candidate"
    (( txmode )) && tx_meta_write "$txdir" committed "$base" "$scope" "$subject" ${ids[@]+"${ids[@]}"}
    echo "→ Commit ($subject):" >&2
    git -C "$saverepo" show --stat --oneline HEAD 2>/dev/null | sed 's/^/    /' >&2; echo >&2
    if [[ "$scope" == "inventory" ]]; then
      echo "→ Inventory commit:" >&2
    fi
  fi

  # The commit point: from here the active repository moves. Anything that
  # fails below keeps the transaction directory for recovery instead of
  # removing it. Legacy mode (no commits yet) has nothing to fast-forward:
  # the commit already landed in the active repo.
  local now_head
  now_head=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)
  if (( txmode )) && (( did_commit )) && [[ "$now_head" != "$base" ]]; then
    echo "save: the active repo moved during the save (another save landed first)" >&2
    echo "The transaction is kept at $txdir — pull, then save again." >&2
    return 1
  fi
  if (( txmode )) && (( did_commit )); then
    git -C "$REPO_DIR" merge --ff-only -q "$candidate" 2>/dev/null || {
      echo "save: cannot fast-forward the active repo (it has changes the save did not make)" >&2
      echo "The transaction is kept at $txdir — resolve the worktree, then save again." >&2
      return 1
    }
    tx_meta_write "$txdir" fast-forwarded "$base" "$scope" "$subject" ${ids[@]+"${ids[@]}"}
    save_fix_modes
  fi
  if (( did_commit )); then
    briefcache_invalidate
  fi

  local PUSHED="" PUSH_ERR=""
  echo "stage: publishing" >&2
  save_push "$push"
  tx_meta_field "$txdir" push "$PUSHED"
  if [[ "$PUSHED" == "failed" ]]; then
    echo "Saved locally, but the push to GitHub failed:" >&2
    printf '%s\n' "$PUSH_ERR" | sed 's/^/    /' >&2
    echo "Another machine may have saved first. Run 'omarchy-replicant pull', then save again." >&2
    echo "The next save (or an explicit push) retries it." >&2
    return 1
  fi
  if (( ! did_commit )) && [[ "$PUSHED" != "ok" ]]; then
    echo "No changes. Nothing to save." >&2
    (( txmode )) && tx_remove "$txdir"
    return 0
  fi
  (( txmode )) && tx_remove "$txdir"
  case "$PUSHED" in
    no-remote) echo "Everything saved on this machine. There is no remote yet: run 'omarchy-replicant create --push'." >&2 ;;
    held)      echo "Everything saved on this machine, not pushed (--no-push)." >&2 ;;
    *)         echo "Everything saved and pushed." >&2 ;;
  esac
  return 0
}

# core_init: create the initial savegame commit. The CLI parses the deprecated
# flags and reports the command result; this function owns repository writes.
core_init() {
  require_writable_schema || return 1
  ensure_repo_layout
  core_backup
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
