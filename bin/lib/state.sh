# shellcheck shell=bash disable=SC2034
# state.sh: one evaluator for what every entry looks like right now.
# Sourced by replicant-core.sh, which sets the paths it uses. It defines
# functions and data and runs nothing. Other modules read its data.
#
# The badge used to be computed four times in four places: the config rows,
# the secret rows, the bar counts and the diff view each had their own copy
# of "compare, then order the states". Four copies meant four answers to the
# same file. Every consumer below asks one question instead: state_verdict.
#
# Facts come first and the verdict second. A fact is one observable thing
# (is the live file here, does the content match), and the verdict orders
# them: off, locked, missing, incoming, unsaved, default, unpushed, saved.
# Incoming outranks unsaved on purpose: both mean "differs", and they ask for
# opposite buttons. Unsaved outranks default: returning a file to the shipped
# default is itself a change that still needs saving.
#
# Nothing here is stored. Dirty is derived from a live comparison on every
# call, so editing a file and putting it back clears the badge by itself.

# entry_differs <src> <repo-copy> <is-dir> — 0 when what is on this machine is
# not what the repo holds. A file that is not on this machine does NOT differ:
# that is "missing", a different row and a different answer.
entry_differs() {
  local src="$1" repo_path="$2" is_dir="${3:-false}"
  if [[ "$is_dir" == true ]]; then
    [[ -d "${src%/}" ]] || return 1
    tree_same "$src" "$repo_path" && return 1
    return 0
  fi
  [[ -f "$src" ]] || return 1
  [[ -f "$repo_path" ]] || return 0
  cmp -s "$src" "$repo_path" 2>/dev/null && return 1
  return 0
}

# state_facts <registry-row> — the independent facts, one name=value per line.
# live: the file or tree is on this machine. repo: the repo holds a copy
# (for a locked secret the vault cannot be read, so this is false).
# same: the two match byte for byte. default: the live file matches what
# Omarchy ships (configs only). git_dirty, git_unpushed: the repo copy is
# uncommitted or unpushed. incoming: the last pull brought a newer copy of
# this entry; the verdict keeps it only while the copies still differ.
# locked: the secret cannot be evaluated here.
state_facts() {
  local row="$1"
  local -a f=()
  mapfile -t f < <(row_split "$row" 9)
  local id="${f[0]}" kind="${f[1]}" scope="${f[4]}" live="${f[5]}" repo="${f[6]}" blob="${f[7]}" locked="${f[8]}"
  local is_dir=false
  [[ "$kind" == "dir" ]] && is_dir=true
  local has_live=false has_repo=false same=false is_default=false
  if [[ "$is_dir" == true ]]; then
    [[ -d "${live%/}" ]] && has_live=true
    [[ -d "${repo%/}" ]] && has_repo=true
  else
    [[ -f "$live" ]] && has_live=true
    [[ -f "$repo" ]] && has_repo=true
  fi
  if [[ "$kind" == "secret" ]]; then
    if [[ "$locked" == "true" ]]; then
      has_repo=false
      same=false
    elif [[ -n "$blob" ]]; then
      vault_blob_same "$repo" "$live" 2>/dev/null && same=true
    else
      entry_differs "$live" "$repo" false || same=true
    fi
  else
    entry_differs "$live" "$repo" "$is_dir" || same=true
    if [[ "$is_dir" == false && "$has_live" == true ]]; then
      local def
      if def=$(default_for_src "$live" 2>/dev/null) && [[ -n "$def" ]]; then
        cmp -s "$live" "$def" 2>/dev/null && is_default=true
      fi
    fi
  fi
  local git_rel="${repo#"$REPO_DIR"/}"
  local git_dirty=false git_unpushed=false
  if [[ -n "$blob" ]]; then
    path_dirty "vault/blobs/$blob.age" && git_dirty=true
    path_unpushed "vault/blobs/$blob.age" && git_unpushed=true
  elif [[ -n "$repo" ]]; then
    path_dirty "$git_rel" && git_dirty=true
    path_unpushed "$git_rel" && git_unpushed=true
  fi
  local incoming=false
  is_incoming_rel "$id" && incoming=true
  # Locked needs something to hold: a secret with no live file is missing,
  # not locked, whether or not the key is here.
  if [[ "$has_live" == false ]]; then
    locked=false
  fi
  printf 'live=%s\nrepo=%s\nsame=%s\ndefault=%s\ngit_dirty=%s\ngit_unpushed=%s\nincoming=%s\nlocked=%s\n' \
    "$has_live" "$has_repo" "$same" "$is_default" "$git_dirty" "$git_unpushed" "$incoming" "$locked"
}

# state_verdict <registry-row> — the one answer every consumer shows:
# "<sync_state> <dirty> <unsaved> <unpushed> <incoming>", each flag true/false.
# dirty is the git half (copied in, not committed); unsaved is either half.
state_verdict() {
  state_eval "$1" | awk -F'\t' '{print $17, $13, $14, $15, $16}'
}

# state_eval <registry-row> — facts and verdict together in one pass, so a
# builder parses one line instead of comparing twice:
# id, kind, source, category, scope, live, repo, blob, locked,
# exists, saved, is_default, dirty, unsaved, unpushed, incoming, sync_state.
state_eval() {
  local row="$1"
  local -a f=()
  mapfile -t f < <(row_split "$row" 9)
  local id="${f[0]}" kind="${f[1]}" source="${f[2]}" category="${f[3]}" scope="${f[4]}"
  local live="${f[5]}" repo="${f[6]}" blob="${f[7]}" locked="${f[8]}"
  local live_v=no repo_v=no same_v=no default_v=no
  local git_dirty_v=no git_unpushed_v=no incoming_v=no locked_v="$locked"
  local line k v
  while IFS='=' read -r k v; do
    case "$k" in
      live) live_v="$v" ;; repo) repo_v="$v" ;; same) same_v="$v" ;;
      default) default_v="$v" ;; git_dirty) git_dirty_v="$v" ;;
      git_unpushed) git_unpushed_v="$v" ;; incoming) incoming_v="$v" ;;
      locked) locked_v="$v" ;;
    esac
  done < <(state_facts "$row")
  local dirty="$git_dirty_v" unsaved=false unpushed="$git_unpushed_v"
  if [[ "$live_v" == true && "$same_v" == false ]] || [[ "$git_dirty_v" == true ]]; then
    unsaved=true
  fi
  # Membership alone is not incoming: the copies must still differ, which is
  # what clears the mark after a restore or a deliberate save over it.
  if [[ "$unsaved" == false ]]; then
    incoming_v=false
  fi
  local sync_state="saved"
  if [[ "$scope" == "off" ]]; then sync_state="off"
  elif [[ "$locked_v" == "true" ]]; then sync_state="locked"
  elif [[ "$live_v" == false ]]; then sync_state="missing"
  elif [[ "$incoming_v" == true ]]; then sync_state="incoming"
  elif [[ "$unsaved" == true ]]; then sync_state="unsaved"
  elif [[ "$kind" != "secret" && "$default_v" == true ]]; then sync_state="default"
  elif [[ "$git_unpushed_v" == true ]]; then sync_state="unpushed"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "$kind" "$source" "$category" "$scope" "$live" "$repo" "$blob" "$locked_v" \
    "$live_v" "$repo_v" "$default_v" "$dirty" "$unsaved" "$unpushed" "$incoming_v" "$sync_state"
}
