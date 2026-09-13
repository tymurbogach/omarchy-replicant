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
SCOPE_FILE="$REPO_DIR/.replicant-sync"
PROFILE_FILE="$REPO_DIR/.replicant-profiles"
LEGACY_EXCLUDE_FILE="$REPO_DIR/.replicant-exclude"

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
ensure_profile_recorded() {
  [[ -d "$REPO_DIR/.git" ]] || return 0
  [[ -n "${REPLICANT_PROFILE:-}" ]] && return 0
  profile_for_machine "$MACHINE" >/dev/null 2>&1 && return 0
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

  (( taken )) && want="$MACHINE"
  core_profile_set "$want" >/dev/null 2>&1 || true
  return 0
}

read_profile_map() {
  [[ -f "$PROFILE_FILE" ]] || return 0
  sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$PROFILE_FILE" 2>/dev/null || true
}

profile_for_machine() {
  local want="$1" line k v
  while IFS= read -r line; do
    k="${line%%=*}"; v="${line#*=}"
    k="${k//[[:space:]]/}"; v="${v//[[:space:]]/}"
    [[ "$k" == "$want" ]] && { printf '%s\n' "$v"; return 0; }
  done < <(read_profile_map)
  return 1
}

# Resolved once per process: every scope lookup needs it.
current_profile() {
  if [[ -n "${REPLICANT_PROFILE:-}" ]]; then printf '%s\n' "$REPLICANT_PROFILE"; return; fi
  profile_for_machine "$MACHINE" && return
  guess_profile
}

# core_profile_set <name> — assign this machine to a profile, creating it.
core_profile_set() {
  local want="$1" line k v
  local -a keep=()
  [[ "$want" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || {
    echo "profile: use lowercase letters, digits, '-' or '_' (max 32)" >&2; return 1; }
  ensure_repo_layout
  while IFS= read -r line; do
    k="${line%%=*}"; k="${k//[[:space:]]/}"
    [[ "$k" == "$MACHINE" ]] || keep+=("$line")
  done < <(read_profile_map)
  keep+=("$MACHINE = $want")
  {
    echo "# Which profile each machine belongs to: <hostname> = <profile>."
    echo "# A machine that is not listed guesses from its own chassis."
    echo "# Files scoped to a profile live in profiles/<profile>/config/, so two"
    echo "# machines in different profiles never overwrite each other's copy."
    printf '%s\n' "${keep[@]}"
  } > "$PROFILE_FILE"
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
SCOPES_CACHE=""; SCOPES_CACHED=0
declare -gA SCOPE_OF=()
SCOPE_MAP_READY=0
invalidate_scopes_cache() { SCOPES_CACHED=0; SCOPES_CACHE=""; SCOPE_MAP_READY=0; SCOPE_OF=(); }

# load_scope_map: the scope list as an associative array, built in this shell.
# The first valid line for a path wins, as in scope_for, and the v0.5 off-list
# counts only while no .replicant-sync exists.
load_scope_map() {
  (( SCOPE_MAP_READY )) && return 0
  SCOPE_MAP_READY=1; SCOPE_OF=()
  local line k v
  read_scopes >/dev/null
  while IFS= read -r line; do
    k="${line%%=*}"; v="${line#*=}"
    k="${k//[[:space:]]/}"; v="${v//[[:space:]]/}"
    case "$v" in shared|profile|off) [[ -n "${SCOPE_OF[$k]:-}" ]] || SCOPE_OF[$k]="$v" ;; esac
  done < <(read_scopes)
  if [[ ! -f "$SCOPE_FILE" && -f "$LEGACY_EXCLUDE_FILE" ]]; then
    while IFS= read -r line; do
      line="${line//[[:space:]]/}"
      [[ -n "$line" && -z "${SCOPE_OF[$line]:-}" ]] && SCOPE_OF[$line]=off
    done < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$LEGACY_EXCLUDE_FILE" 2>/dev/null || true)
  fi
  return 0
}

# scope_into <var> <rel> and repo_path_into <var> <rel> <profile>: the answers
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
read_scopes() {
  if (( ! SCOPES_CACHED )); then
    SCOPES_CACHED=1
    [[ -f "$SCOPE_FILE" ]] && SCOPES_CACHE=$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$SCOPE_FILE" 2>/dev/null || true)
  fi
  [[ -n "$SCOPES_CACHE" ]] && printf '%s\n' "$SCOPES_CACHE"
  return 0
}

# scope_for <rel> → shared | profile | off   (unlisted files are shared)
scope_for() {
  local rel="$1" line k v
  while IFS= read -r line; do
    k="${line%%=*}"; v="${line#*=}"
    k="${k//[[:space:]]/}"; v="${v//[[:space:]]/}"
    if [[ "$k" == "$rel" ]]; then
      case "$v" in shared|profile|off) printf '%s\n' "$v"; return 0 ;; esac
    fi
  done < <(read_scopes)
  # A v0.5 repo that has not been through ensure_repo_layout yet still keeps its
  # off-list in the old flat file. Honour it until the migration runs, so a file
  # the user switched off never reads as shared for even one command.
  if [[ ! -f "$SCOPE_FILE" && -f "$LEGACY_EXCLUDE_FILE" ]]; then
    while IFS= read -r line; do
      [[ "${line//[[:space:]]/}" == "$rel" ]] && { printf 'off\n'; return 0; }
    done < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$LEGACY_EXCLUDE_FILE" 2>/dev/null || true)
  fi
  printf 'shared\n'
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

write_scope_file() {
  local -a keep=("$@")
  {
    echo "# What Replicant does with each tracked file, one per line:"
    echo "#   <path> = shared    one copy, every machine saves and restores it"
    echo "#   <path> = profile   a copy per profile, under profiles/<profile>/config/"
    echo "#   <path> = off       never saved from or restored onto any machine"
    echo "# A path that is not listed is shared. Written by the panel; safe to edit."
    print_lines "${keep[@]}"
  } > "$SCOPE_FILE"
  invalidate_scopes_cache
}

# Seed the scope list on a fresh repo, and migrate the v0.5 flat off-list.
# .replicant-exclude only had two states; every path in it meant "off", which is
# still exactly what it means here — so the migration is a straight translation
# and nothing a user chose is reinterpreted.
#
# EVERY writer must call this before rewriting the file. core_scope once did not,
# and because read_scopes() sees no .replicant-sync it rebuilt the list from
# nothing — silently discarding a v0.5 user's entire off-list the first time they
# touched any file's scope. Reading has a fallback; writing needs the real thing.
ensure_scope_file() {
  [[ -f "$SCOPE_FILE" ]] && return 0
  mkdir -p "$(dirname "$SCOPE_FILE")" 2>/dev/null || true
  local -a seed=()
  if [[ -f "$LEGACY_EXCLUDE_FILE" ]]; then
    local ln
    while IFS= read -r ln; do
      ln="${ln//[[:space:]]/}"
      [[ -n "$ln" ]] && seed+=("$ln = off")
    done < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$LEGACY_EXCLUDE_FILE" 2>/dev/null || true)
    write_scope_file "${seed[@]}"
    rm -f -- "$LEGACY_EXCLUDE_FILE"
    echo "  · migrated .replicant-exclude to .replicant-sync (${#seed[@]} entries kept off)" >&2
  else
    write_scope_file "${DEFAULT_SCOPES[@]/=/ = }"
  fi
}

# move_repo_copy <from> <to> — carry the copy the repo holds to its new path.
#
# The guard here used to be `-f`, so a tracked DIRECTORY was never moved: the
# tree stayed at the old path while repo_path_for pointed at the new one, and
# until the next save the panel called a saved tree unsaved and revert-to-repo
# could not find it. Both sides are inside the repo, which is the only reason
# clearing the destination first is safe — and it is checked, not assumed.
move_repo_copy() {
  local from="${1%/}" to="${2%/}"
  [[ -e "$from" ]] || return 0
  case "$to/" in "$REPO_DIR"/*) ;; *) echo "refusing to move outside the repo: $to" >&2; return 1 ;; esac
  mkdir -p "$(dirname "$to")"
  rm -rf -- "$to"
  mv -f -- "$from" "$to"
}

# core_scope <rel> <shared|profile|off> — the panel's per-file scope control.
core_scope() {
  local rel="$1" want="$2" line k old
  local -a keep=()
  case "$want" in shared|profile|off) ;; *)
    echo "scope: expected 'shared', 'profile' or 'off'" >&2; return 1 ;; esac
  resolve_manifest_src "$rel" >/dev/null 2>&1 || { echo "unknown id: $rel" >&2; return 1; }
  ensure_scope_file
  old=$(scope_for "$rel")
  [[ "$old" == "$want" ]] && { echo "$rel is already '$want'" >&2; return 0; }
  mkdir -p "$(dirname "$SCOPE_FILE")"
  while IFS= read -r line; do
    k="${line%%=*}"; k="${k//[[:space:]]/}"
    [[ "$k" == "$rel" ]] || keep+=("$line")
  done < <(read_scopes)
  [[ "$want" != "shared" ]] && keep+=("$rel = $want")
  write_scope_file "${keep[@]}"

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
}

# core_sync <rel> <on|off> — the older two-state switch, kept because it is in
# the shipped README and in scripts. "on" means shared.
core_sync() {
  local rel="$1" want="$2"
  case "$want" in
    on)  core_scope "$rel" shared ;;
    off) core_scope "$rel" off ;;
    *)   echo "sync: expected 'on' or 'off'" >&2; return 1 ;;
  esac
}

repo_copy_for_rel() {
  if is_secret_rel "$1"; then printf '%s\n' "$SECRETS_DIR/$1"; else repo_path_for "$1"; fi
}
