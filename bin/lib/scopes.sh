# shellcheck shell=bash disable=SC2034
# scopes.sh: profiles, and whether each file is shared, kept per profile, or off.
# Sourced by replicant-core.sh, which sets the paths it uses. It defines
# functions and data and runs nothing. Other modules read its data.

# ─── Profiles and what each machine syncs ───────────────────────────────────
# One repo, more than one machine, and they are not the same machine. A desktop
# and a laptop want the same shell, the same keybindings and the same git
# identity — and emphatically NOT the same monitor layout, touchpad settings or
# lid behaviour. So every tracked file carries a scope:
#
#   shared   (default) one copy in config/, every machine saves and restores it
#   profile  a copy per profile in profiles/<profile>/config/, so the desktop
#            and the laptop each keep their own and neither overwrites the other
#   off      not saved from here, not restored onto here, and whatever copy the
#            repo already holds is left exactly as it is
#
# "profile" is the one that makes two machines practical. Switching monitors.lua
# off means nobody gets a backup of it; scoping it to a profile means both
# machines get one, they just don't get each OTHER's.
#
# Both lists live in the repo rather than ~/.local/share, because "monitors are
# machine-specific" is a fact about the setup, not about one machine: decide it
# once, and every machine sharing the repo honours it.

# Seeded on a fresh repo. Not hardcoded rules: they are written into a file the
# user can see, edit, and change from the panel. These are the files that are
# *about the hardware*, which is exactly what a profile is for.
# Only files that describe the hardware itself. hypr/input.lua deliberately is
# NOT here: it carries the keyboard layout and repeat rate, which you do want on
# both machines, alongside a few touchpad keys a desktop simply ignores.
# Splitting it per profile would cost more than it saves.
DEFAULT_SCOPES=(
  "hypr/monitors.lua=profile"
  "etc/99-lid.conf=profile"
  "etc/99-hibernate-delay.conf=profile"
)

# A machine with no explicit assignment guesses from its own chassis. Guessing
# is safe here: the guess only picks WHICH profile directory this machine reads
# and writes, and `profile set` overrides it permanently.
guess_profile() {
  if command -v omarchy-hw-laptop >/dev/null 2>&1; then
    omarchy-hw-laptop >/dev/null 2>&1 && { echo laptop; return; }
    echo desktop; return
  fi
  # No Omarchy helper (a test fixture, or a non-Omarchy box): fall back to the
  # kernel's own answer — a lid is the thing that makes a laptop a laptop.
  if [[ -d /proc/acpi/button/lid ]]; then echo laptop; else echo desktop; fi
}

# ensure_profile_recorded — write down which profile THIS machine is in, once,
# if nobody has said.
#
# guess_profile asks the chassis, so every laptop guesses `laptop`. Two laptops
# on one repo therefore both wrote profiles/laptop/config/hypr/monitors.lua and
# the second save silently overwrote the first machine's only backup of its
# screen layout — reproduced, and it eats the one file that is profile-scoped
# out of the box. This is the bug state/<hostname>/ was introduced to fix, one
# level up: profiles are named by ROLE, and roles collide.
#
# Recording the guess makes the collision visible to the next machine, which
# then falls back to its hostname — unique by construction. It only ever ASSIGNS
# and never reassigns, so an existing machine keeps the profile it already has
# and nothing moves in a repo that is already working.
# normalize_profile_name <raw> — a hostname (or any string) mapped into the
# profile alphabet: lowercase letters, digits, '-' and '_', max 32, starting
# with a letter or digit. The hostname fallback in ensure_profile_recorded used
# to be assigned raw, so a machine called "My.Host" failed core_profile_set
# validation and stayed unrecorded, silently sharing the guessed profile.
normalize_profile_name() {
  local n="$1"
  n=$(tr '[:upper:]' '[:lower:]' <<<"$n")
  n=$(LC_ALL=C tr -c 'a-z0-9_-' '-' <<<"$n")
  n=$(tr -s '-' <<<"$n")
  n="${n#-}"
  n="${n%-}"
  n="${n:0:32}"
  n="${n%-}"
  while [[ -n "$n" && "$n" =~ ^[^a-z0-9] ]]; do n="${n:1}"; done
  [[ -z "$n" ]] && n="machine"
  printf '%s\n' "$n"
}

ensure_profile_recorded() {
  [[ -e "$REPO_DIR/.git" ]] || return 0
  # A forced profile still gets recorded: worktrees and clones validate the
  # machines dir, which only exists with files in it, so an unrecorded
  # machine would leave every save transaction failing its schema gate.
  if [[ -n "${REPLICANT_PROFILE:-}" ]]; then
    if [[ -z "$(profile_for_machine "$MACHINE" 2>/dev/null)" ]]; then
      core_profile_set "${REPLICANT_PROFILE}" >/dev/null 2>&1 || true
    fi
    return 0
  fi
  # Non-empty, not merely exit-zero: machine_profile reads a file that may
  # not exist, and swallows the miss, so the exit code alone claims every
  # new machine is already recorded and the fallback below never runs.
  [[ -n "$(profile_for_machine "$MACHINE" 2>/dev/null)" ]] && return 0
  local want taken=0 line k v d
  want=$(guess_profile)

  # Claimed by name: another machine is recorded under this role.
  while IFS= read -r line; do
    k="${line%%=*}"; v="${line#*=}"
    k="${k//[[:space:]]/}"; v="${v//[[:space:]]/}"
    [[ -z "$k" ]] && continue
    [[ "$v" == "$want" && "$k" != "$MACHINE" ]] && { taken=1; break; }
  done < <(read_profile_map)

  # Claimed by occupancy: the tree exists but nobody is recorded under it —
  # which is every repo written before this check existed. The tree is only
  # SOMEBODY ELSE'S if somebody else has actually saved here; on a repo with one
  # machine it is that machine's own, and taking a different name would orphan
  # its backup instead of protecting it.
  if (( ! taken )) && [[ -d "$REPO_DIR/profiles/$want" ]]; then
    for d in "$STATE_ROOT"/*/; do
      [[ -d "$d" ]] || continue
      [[ "$(basename "$d")" == "$MACHINE" ]] && continue
      taken=1; break
    done
  fi

  # The fallback is the hostname, unique by construction — normalized into
  # the profile alphabet, and suffixed while another machine holds the name
  # (two hostnames can normalize to one profile: "Host-A" and "host.a").
  if (( taken )); then
    want=$(normalize_profile_name "$MACHINE")
    local base="${want:0:29}" used i=2
    used=$(read_profile_map | sed -e 's/.*=//' -e 's/[[:space:]]//g')
    while grep -qxF "$want" <<<"$used"; do
      want="${base}-${i}"
      (( i++ )) || true
    done
  fi
  core_profile_set "$want" >/dev/null 2>&1 || true
  return 0
}

# Machine assignments live in .replicant/machines/*.json, one file per
# machine with a profile field. This prints "<machine> = <profile>" per line.
read_profile_map() {
  local f id prof
  [[ -d "$REPO_DIR/.replicant/machines" ]] || return 0
  for f in "$REPO_DIR/.replicant/machines"/*.json; do
    [[ -f "$f" ]] || continue
    id=$(basename "$f" .json)
    prof=$(jq -r '.profile // empty' "$f" 2>/dev/null || true)
    [[ -n "$prof" ]] || continue
    printf '%s = %s\n' "$id" "$prof"
  done
  return 0
}

profile_for_machine() {
  machine_profile "$1"
}

# Resolved once per process: every scope lookup needs it. The machine JSON
# record is the only store: the test override wins for suites, then the
# recorded profile, then the chassis guess.
current_profile() {
  if [[ -n "${REPLICANT_PROFILE:-}" ]]; then printf '%s\n' "$REPLICANT_PROFILE"; return; fi
  local recorded
  recorded=$(machine_profile "$MACHINE" 2>/dev/null || true)
  [[ -n "$recorded" ]] || recorded=$(guess_profile)
  printf '%s\n' "$recorded"
  return
}

# profile_report prints the profile view. The CLI delegates this read-only
# presentation to the scopes module and keeps only command parsing outside it.
profile_report() {
  local want="${1:-}" cur pr n
  if [[ -z "$want" || "$want" == list ]]; then
    cur=$(current_profile)
    printf 'This machine (%s) is in the "%s" profile.\n\n' "$MACHINE" "$cur"
    printf 'Profiles in this repo:\n'
    while IFS= read -r pr; do
      [[ -n "$pr" ]] || continue
      n=$(find "$REPO_DIR/profiles/$pr/config" -type f 2>/dev/null | wc -l || true)
      if [[ "$pr" == "$cur" ]]; then
        printf '  * %-14s %-12s <- this machine\n' "$pr" "$(plural "$n" file)"
      else
        printf '    %-14s %s\n' "$pr" "$(plural "$n" file)"
      fi
    done < <(list_profiles)
    printf '\nMachines:\n'
    read_profile_map | sed 's/^/    /'
    return 0
  fi
  core_profile_set "$want"
}

# core_profile_set <name> — assign this machine to a profile, creating it.
# The machine JSON record is the only store.
core_profile_set() {
  require_ready_schema || return 1
  local want="$1"
  [[ "$want" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || {
    echo "profile: use lowercase letters, digits, '-' or '_' (max 32)" >&2; return 1; }
  ensure_repo_layout
  require_valid_entries || return 1
  local dir="$REPO_DIR/.replicant/machines"
  mkdir -p "$dir"
  if [[ -f "$dir/$MACHINE.json" ]]; then
    jq --arg profile "$want" --arg client "$(running_version)" \
      '.profile = $profile | .clientVersion = $client' \
      "$dir/$MACHINE.json" > "$dir/$MACHINE.json.new" || return 1
    mv -f -- "$dir/$MACHINE.json.new" "$dir/$MACHINE.json"
  else
    REPLICANT_PROFILE="$want" machine_metadata_write "$MACHINE" || return 1
  fi
  briefcache_invalidate
  echo "$MACHINE is now in the '$want' profile" >&2
}

# Every profile the repo knows about: the assignments, the directories that
# already exist, and this machine's own — so the panel can list them.
list_profiles() {
  {
    read_profile_map | sed -e 's/.*=//' -e 's/[[:space:]]//g'
    [[ -d "$REPO_DIR/profiles" ]] && find "$REPO_DIR/profiles" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null
    current_profile
  } | sed '/^$/d' | sort -u
}

# The scope list is read at least three times per row — once directly and twice
# more through repo_path_for — and it used to spawn a sed for every one of them.
# On fifty rows that is a hundred and fifty processes to answer a question about
# a file of a dozen lines. It is read once per process instead.
declare -gA SCOPE_OF=()
SCOPE_MAP_READY=0
invalidate_scopes_cache() { SCOPE_MAP_READY=0; SCOPE_OF=(); }

# load_scope_map: the scope list as an associative array, built in this shell.
# The entries records fill the map, with the shipped defaults behind them, so
# the fork-free scope_into answers from one snapshot per process.
load_scope_map() {
  (( SCOPE_MAP_READY )) && return 0
  SCOPE_MAP_READY=1; SCOPE_OF=()
  local k v vid vsc
  if [[ -f "$REPO_DIR/.replicant/entries.json" ]]; then
    while IFS=$'\t' read -r vid vsc; do
      [[ -n "${vid:-}" ]] || continue
      case "$vsc" in shared|profile|off) [[ -n "${SCOPE_OF[$vid]:-}" ]] || SCOPE_OF[$vid]="$vsc" ;; esac
    done < <(jq -r 'to_entries | sort_by(.key)[] | [.key, (.value.scope // "")] | @tsv' \
      "$REPO_DIR/.replicant/entries.json" 2>/dev/null || true)
  fi
  local entry
  for entry in "${DEFAULT_SCOPES[@]}"; do
    k="${entry%%=*}"; v="${entry##*=}"
    [[ -n "${SCOPE_OF[$k]:-}" ]] || SCOPE_OF[$k]="$v"
  done
  return 0
}

# entries_scope_for <rel>: the scope recorded in .replicant/entries.json, or
# nothing. The single scope source. Best effort: registry_build validates the
# file first and fails loudly, so resolution never has to.
entries_scope_for() {
  [[ -f "$REPO_DIR/.replicant/entries.json" ]] || return 0
  jq -r --arg id "$1" '.[$id].scope // empty' "$REPO_DIR/.replicant/entries.json" 2>/dev/null || true
}
# of scope_for and repo_path_for, written into <var> without a fork. The loops
# over every row call these. `$(scope_for ...)` is one fork for each call, and
# the bar runs count_changes once a minute.
scope_into() {
  load_scope_map
  printf -v "$1" '%s' "${SCOPE_OF[$2]:-shared}"
}
repo_path_into() {
  local scope_into_result
  scope_into scope_into_result "$2"
  if [[ "$scope_into_result" == "profile" ]]; then
    printf -v "$1" '%s' "$REPO_DIR/profiles/$3/config/$2"
  else
    printf -v "$1" '%s' "$CONFIG_DIR/$2"
  fi
}
# scope_for <rel> → shared | profile | off   (unlisted files are shared)
# The answer comes from the shared scope cache that scope_into reads too: the
# entries record first, the shipped defaults behind it, shared when neither
# names the id. One resolution path, never two.
scope_for() {
  local rel="$1"
  load_scope_map
  printf '%s\n' "${SCOPE_OF[$rel]:-shared}"
}

# Kept so the eight call sites that only care about "is this switched off"
# read the way they always did.
is_excluded() { [[ "$(scope_for "$1")" == "off" ]]; }

# repo_path_for <rel> [profile] — where this file's copy lives in the repo.
# The one place that knows shared files sit in config/ and profile-scoped ones
# sit under profiles/<profile>/. Every reader and writer goes through it, so a
# file cannot be saved to one path and restored from another.
repo_path_for() {
  local rel="$1" prof="${2:-}"
  if [[ "$(scope_for "$rel")" == "profile" ]]; then
    [[ -n "$prof" ]] || prof=$(current_profile)
    printf '%s\n' "$REPO_DIR/profiles/$prof/config/$rel"
  else
    printf '%s\n' "$CONFIG_DIR/$rel"
  fi
}

# print_lines <line>... — one line each, and nothing at all for no lines. The
# writers ended in `(( n )) && printf`, so with nothing to keep a writer returned
# 1, and set -e ended the first layout on a new machine with no message.
print_lines() { (( $# )) || return 0; printf '%s\n' "$@"; }

# move_repo_copy <from> <to> — carry the copy the repo holds to its new path.
#
# The guard here used to be `-f`, so a tracked DIRECTORY was never moved: the
# tree stayed at the old path while repo_path_for pointed at the new one, and
# until the next save the panel called a saved tree unsaved and revert-to-repo
# could not find it. Both sides are inside the repo, which is the only reason
# moving is safe at all — and the destination is checked, not assumed.
#
# The destination is never cleared first. Clearing it and then moving loses
# both copies when the move fails. Instead the destination (when present)
# moves aside, the source moves over, and only then is the aside copy dropped;
# a failed move restores it, so one failed scope change cannot eat a backup.
move_repo_copy() {
  local from="${1%/}" to="${2%/}" aside=""
  [[ -e "$from" ]] || return 0
  case "$to/" in "$REPO_DIR"/*) ;; *) echo "refusing to move outside the repo: $to" >&2; return 1 ;; esac
  mkdir -p "$(dirname "$to")"
  if [[ -e "$to" ]]; then
    aside="$to.__prev.$$"
    rm -rf -- "$aside"
    mv -- "$to" "$aside" || { echo "could not stage the destination aside: $to" >&2; return 1; }
  fi
  if mv -- "$from" "$to"; then
    [[ -n "$aside" ]] && rm -rf -- "$aside"
    return 0
  fi
  echo "could not move $from to $to — nothing was lost" >&2
  if [[ -n "$aside" ]]; then
    mv -- "$aside" "$to" 2>/dev/null || echo "restore $aside to $to by hand" >&2
  fi
  return 1
}

# core_scope <rel> <shared|profile|off> — the panel's per-file scope control.
core_scope() {
  require_ready_schema || return 1
  local rel="$1" want="$2" old
  case "$want" in shared|profile|off) ;; *)
    echo "scope: expected 'shared', 'profile' or 'off'" >&2; return 1 ;; esac
  resolve_manifest_src "$rel" >/dev/null 2>&1 || { echo "unknown id: $rel" >&2; return 1; }
  old=$(scope_for "$rel")
  [[ "$old" == "$want" ]] && { echo "$rel is already '$want'" >&2; return 0; }
  scope_store "$rel" "$want" || return 1

  # Moving between scopes moves the copy the repo already holds, so changing
  # your mind does not silently strand a backup at the old path.
  local from to
  case "$old:$want" in
    shared:profile)
      from="$CONFIG_DIR/$rel"; to="$REPO_DIR/profiles/$(current_profile)/config/$rel"
      move_repo_copy "$from" "$to" ;;
    profile:shared)
      from="$REPO_DIR/profiles/$(current_profile)/config/$rel"; to="$CONFIG_DIR/$rel"
      move_repo_copy "$from" "$to" ;;
  esac

  case "$want" in
    shared)  echo "$rel is shared by every machine" >&2 ;;
    profile) echo "$rel is kept per profile — this machine reads and writes the '$(current_profile)' copy" >&2 ;;
    off)     echo "$rel will no longer sync" >&2 ;;
  esac
  briefcache_invalidate
}

# scope_store <rel> <scope>: record one scope decision in the canonical
# .replicant/entries.json, creating an override record for shipped entries
# that carry non-default policy. Fails before mutation when validation fails.
# Secrets cannot use the profile scope from any path: vault blobs are global,
# so a per-profile secret would record a scope its storage cannot honour.
# bulk.sh refused it while this function accepted it; the single rule lives
# here, where every scope write (single, bulk, policy) arrives.
scope_store() {
  local rel="$1" want="$2" src kind scope source
  if [[ "$want" == profile ]] && is_secret_rel "$rel"; then
    echo "scope: secret entries cannot use the profile scope: $rel" >&2
    return 1
  fi
  if is_secret_rel "$rel"; then
    vault_identity_ok || return 1
    local idx blob
    idx=$(vault_index_decrypt) || return 1
    blob=$(vault_index_blob "$idx" "$rel")
    [[ -n "$blob" ]] || { echo "scope: $rel is not saved in your repo yet — save it first" >&2; return 1; }
    idx=$(jq -c --arg id "$rel" --arg scope "$want" \
      '.secrets |= map(if .id == $id then .scope = $scope else . end)' <<<"$idx") || return 1
    vault_index_write "$idx" || return 1
    return 0
  fi
  require_valid_entries || return 1
  src=$(resolve_manifest_src "$rel") || { echo "unknown id: $rel" >&2; return 1; }
  kind=config; is_dir_entry "$rel" && kind=dir
  scope=$(entries_scope_for "$rel")
  if [[ -n "$scope" ]]; then
    source=$(jq -r --arg id "$rel" '.[$id].source // "override"' \
      "$REPO_DIR/.replicant/entries.json" 2>/dev/null)
    [[ "$source" == user || "$source" == override ]] || source=override
  else
    source=override
  fi
  entries_upsert "$rel" "$src" "$kind" "$want" "$source" || return 1
  return 0
}

# core_scope_bulk <scope> <id...> — apply one scope decision to every id.
# Validate the complete selection before changing the entries record or moving
# a repository copy. The CLI commits the resulting shape as one decision.
core_scope_bulk() {
  require_ready_schema || return 1
  local want="$1" id src old from to
  shift || true
  [[ "$want" == shared || "$want" == profile || "$want" == off ]] || {
    echo "policy: expected scope 'shared', 'profile' or 'off'" >&2
    return 1
  }
  (( $# > 0 )) || { echo "policy: no entries selected" >&2; return 1; }

  local -A seen=()
  local -a ids=() olds=() froms=() tos=()
  for id in "$@"; do
    [[ -n "$id" && -z "${seen[$id]:-}" ]] || {
      echo "policy: duplicate or empty entry id: $id" >&2; return 1; }
    seen["$id"]=1
    resolve_manifest_src "$id" >/dev/null 2>&1 || {
      echo "policy: unknown id: $id" >&2; return 1; }
    old=$(scope_for "$id")
    ids+=("$id"); olds+=("$old")
    [[ "$old" == "$want" ]] && { froms+=(""); tos+=(""); continue; }
    if [[ "$old" == shared && "$want" == profile ]]; then
      from="$CONFIG_DIR/$id"; to="$REPO_DIR/profiles/$(current_profile)/config/$id"
    elif [[ "$old" == profile && "$want" == shared ]]; then
      from="$REPO_DIR/profiles/$(current_profile)/config/$id"; to="$CONFIG_DIR/$id"
    else
      froms+=(""); tos+=(""); continue
    fi
    if [[ -e "$from" && ! -e "$to" ]]; then
      [[ -d "$(dirname "$to")" || -w "$(dirname "$to")" || ! -e "$(dirname "$to")" ]] || {
        echo "policy: destination is not writable: $to" >&2; return 1; }
    fi
    froms+=("$from"); tos+=("$to")
  done

  for id in "${ids[@]}"; do
    scope_store "$id" "$want" || return 1
  done

  local i
  for i in "${!ids[@]}"; do
    [[ -n "${froms[$i]}" ]] || continue
    move_repo_copy "${froms[$i]}" "${tos[$i]}" || return 1
  done
  briefcache_invalidate
  echo "$(plural "${#ids[@]}" entry entries) now use the '$want' scope" >&2
}

# scope_shape_paths <rel>: the repository paths one scope decision can touch.
# A file lives at exactly one of the two copy paths; the shared policy stores
# and the vault index cover the metadata. Prints one path per line.
scope_shape_paths() {
  local rel="$1"
  tx_shape_policy_paths
  printf '%s\n' "config/$rel" "profiles/$(current_profile)/config/$rel"
}

# core_scope_transact <rel> <shared|profile|off>: one scope change, one commit.
core_scope_transact() {
  local rel="${1:-}" want="${2:-}"
  [[ -n "$rel" && -n "$want" ]] || { echo "usage: scope <id> shared|profile|off" >&2; return 2; }
  local -a paths=()
  while IFS= read -r p; do [[ -n "$p" ]] && paths+=("$p"); done < <(scope_shape_paths "$rel")
  core_shape_transact "scope: $rel is now $want" "scope" core_scope "$rel" "$want" -- "${paths[@]}"
}

# core_policy_transact <scope> <id...>: one validated bulk policy change, one
# commit. Validates the complete selection before changing anything, through
# core_scope_bulk.
core_policy_transact() {
  local scope="${1:-}"
  shift || true
  [[ -n "$scope" && $# -gt 0 ]] || { echo "usage: policy set --scope <scope> -- <id...>" >&2; return 2; }
  local -a ids=("$@") paths=()
  local id p
  while IFS= read -r p; do [[ -n "$p" ]] && paths+=("$p"); done < <(tx_shape_policy_paths)
  for id in "${ids[@]}"; do
    paths+=("config/$id" "profiles/$(current_profile)/config/$id")
  done
  core_shape_transact "policy: set $scope for $(plural "${#ids[@]}" entry entries)" \
    "policy" core_scope_bulk "$scope" "${ids[@]}" -- "${paths[@]}"
}

# core_profile_transact <name>: move this machine to a profile, one commit.
# It runs through the shared shape transaction like every other policy write,
# so the journal, the commit and the push behave the same everywhere.
core_profile_transact() {
  local want="${1:-}"
  [[ -n "$want" ]] || { echo "usage: profile <name>" >&2; return 2; }
  local msg="profile: $MACHINE is now '$want'"
  core_shape_transact "$msg" "profile" profile_report "$want" -- .replicant/machines || return 1
  echo "Files scoped to a profile will now be saved and restored from profiles/$want/." >&2
  return 0
}

repo_copy_for_rel() {
  if is_secret_rel "$1"; then printf '%s\n' "$SECRETS_DIR/$1"; else repo_path_for "$1"; fi
}
