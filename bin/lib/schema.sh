# shellcheck shell=bash disable=SC2034
# schema.sh: the v3 data repository schema. Sourced by replicant-core.sh, which
# sets the paths it uses. It defines functions and data and runs nothing.
#
# Version 1 is the absence of .replicant/schema.json: the .replicant-track,
# .replicant-sync, .replicant-profiles and .replicant-version files beside
# config/, secrets/ and state/. Version 2 adds .replicant/schema.json,
# .replicant/entries.json and one machines/<id>.json per machine, with secret
# metadata in the version 1 vault index. Versions 1 and 2 stay readable for
# inspection and migration, but only version 3 accepts writes. Version 3 keeps
# the same layout, renames nothing on disk, and tightens the records: the
# schema marker carries dataVersion 3 with secretFormat age-pq-v2, non-secret
# mutable policy lives only in .replicant/entries.json, and secret metadata
# lives only inside the version 2 encrypted vault index.
#
# The one rule: a writer never mutates a repo whose format it cannot read.
# require_writable_schema is the first line of every core function that
# writes, and cmd_save checks the schema-gate command before it commits
# (a failed backup there does not stop the commit). Reads never block:
# status, diff, pull and dry runs keep answering on any schema. create, clone
# and init are not gated either: they make repos, they do not interpret them.
# reset and reset-all are not gated: they apply Omarchy defaults, never repo
# content. purge is the escape hatch and stays ungated on purpose.
#
# Legacy readers for versions 1 and 2 live in legacy.sh, the migration-only
# module. Nothing in the write path imports them.

# SCHEMA_VERSION is the highest dataVersion this client writes.
# SCHEMA_FORMAT is declared in schema.json alongside it.
SCHEMA_VERSION=3
SCHEMA_FORMAT="age-pq-v2"

# repo_data_version: prints 1, 2, 3, a newer number, or unknown. It always
# succeeds: the caller decides what each answer means. A missing schema.json
# is version 1, so every repo written before entries existed reads exactly as
# it always did. An unreadable, versionless, or non-numeric file is unknown,
# never a guess: a string "3" is malformed, not version 3.
repo_data_version() {
  local file="$REPO_DIR/.replicant/schema.json" v
  [[ -f "$file" ]] || { printf '1\n'; return 0; }
  v=$(jq -r '.dataVersion | if type == "number" then tostring else empty end' "$file" 2>/dev/null || true)
  [[ "$v" =~ ^[0-9]+$ ]] || { printf 'unknown\n'; return 0; }
  printf '%s\n' "$v"
}

# repo_state: prints missing when no git repo exists here, else the version
# as v1, v2, v3, unknown, or a newer number. A directory without .git is not
# version 1: version 1 is a git repo without a schema marker. Bootstrap
# (init, create, clone) uses this to tell "nothing here yet" from "a legacy
# repo that needs migration".
# -e, not -d: a linked worktree carries .git as a file.
repo_state() {
  local v
  [[ -e "$REPO_DIR/.git" ]] || { printf 'missing\n'; return 0; }
  v=$(repo_data_version)
  [[ "$v" =~ ^[0-9]+$ ]] && printf 'v%s\n' "$v" || printf '%s\n' "$v"
}

# repo_exists: 0 when a git repo exists at REPO_DIR, staged or not.
repo_exists() { [[ -e "$REPO_DIR/.git" ]]; }

# repo_is_v3: 0 when the active repo carries the version 3 schema marker.
# Writers use this to choose the canonical stores; readers use it to choose
# the canonical resolution paths. A repo without a marker is version 1.
repo_is_v3() { [[ "$(repo_data_version)" == 3 ]]; }

# repo_has_vault: 0 when secrets live encrypted in vault/blobs with an index,
# on version 2 and 3 alike. Version 1 keeps plaintext under secrets/.
repo_has_vault() { [[ "$(repo_data_version)" == 2 || "$(repo_data_version)" == 3 ]]; }

# V3_ENTRIES_OK caches one validation per process: every writer in one CLI
# invocation shares it, and a fresh process revalidates.
V3_ENTRIES_OK=0

# v3_require_valid_entries: 0 when the entries file is fit to mutate against.
# A missing file means the shipped defaults, which are valid by definition.
# Every version 3 writer calls this before mutation.
v3_require_valid_entries() {
  (( V3_ENTRIES_OK )) && return 0
  if [[ -f "$REPO_DIR/.replicant/entries.json" ]]; then
    validate_v3_entries || return 1
  fi
  V3_ENTRIES_OK=1
  return 0
}

# LEGACY_POLICY_FILES: the version 1 and 2 policy files that must not exist
# inside a version 3 repository. .replicant-version is not listed: it stays as
# the old-client prune guard.
LEGACY_POLICY_FILES=(.replicant-track .replicant-sync .replicant-profiles .replicant-exclude)

# v3_no_legacy_files: 0 when no legacy policy file contaminates the repo.
# A version 3 repository that still carries one was touched by an older
# client after migration, and every writer refuses it before mutation.
v3_no_legacy_files() {
  local name
  for name in "${LEGACY_POLICY_FILES[@]}"; do
    if [[ -e "$REPO_DIR/$name" ]]; then
      printf 'replicant: %s is a legacy policy file — a version 3 repository must not contain it\n' "$name" >&2
      return 1
    fi
  done
  return 0
}

# _schema_top_keys <file>: the top-level keys of a JSON object, one per line,
# in file order. jq cannot do this: it parses first, so duplicate keys
# collapse to last-wins before any filter sees them. This scans the raw text
# instead, tracking brace depth outside strings (braces inside strings do not
# count, and neither do nested keys). A non-object root lists nothing.
_schema_top_keys() {
  awk '
    BEGIN { depth = 0; in_str = 0; esc = 0; tok = ""; cand = ""; cand_depth = 0; have_cand = 0 }
    {
      line = $0; n = length(line)
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (in_str) {
          if (esc) { tok = tok c; esc = 0 }
          else if (c == "\\") { tok = tok c; esc = 1 }
          else if (c == "\"") { in_str = 0; cand = tok; cand_depth = depth; have_cand = 1; tok = "" }
          else { tok = tok c }
          continue
        }
        if (c == "\"") { in_str = 1; tok = ""; have_cand = 0; continue }
        if (c == "{" || c == "[") { depth++; have_cand = 0; continue }
        if (c == "}" || c == "]") { depth--; have_cand = 0; continue }
        if (c == " " || c == "\t") continue
        if (c == ":" && have_cand && cand_depth == 1) { print cand }
        have_cand = 0
      }
    }' "$1"
}

# _schema_marker_valid: 0 when the schema file is a well-formed version 3
# marker: numeric dataVersion 3 with secretFormat age-pq-v2. Every malformed
# field is named. Writers call this before mutation; readers stay lenient.
_schema_marker_valid() {
  local file="$REPO_DIR/.replicant/schema.json" v f
  v=$(jq -r '.dataVersion | if type == "number" then tostring else "non-numeric" end' "$file" 2>/dev/null || true)
  [[ "$v" == 3 ]] || { printf 'schema: dataVersion is %s, not 3\n' "$v" >&2; return 1; }
  f=$(jq -r '.secretFormat // empty' "$file" 2>/dev/null || true)
  [[ "$f" == "age-pq-v2" ]] || { printf 'schema: secretFormat is %s, not age-pq-v2\n' "${f:-missing}" >&2; return 1; }
  return 0
}

# _schema_duplicate_keys <file>: 0 when no top-level key repeats in the raw
# text. jq collapses duplicates silently, so this runs before any jq read.
_schema_duplicate_keys() {
  local dups
  dups=$(_schema_top_keys "$1" | sort | uniq -d)
  if [[ -n "$dups" ]]; then
    printf 'schema: duplicate key %s\n' "$dups" | head -n1 >&2
    return 1
  fi
  return 0
}

# require_writable_schema: 0 when this client may mutate a v3 repo. Versions 1
# and 2 remain readable, but every writer stops before touching their
# worktrees: migrate-v3 (phase G3) is the way forward.
require_writable_schema() {
  local v file="$REPO_DIR/.replicant/schema.json"
  # Duplicate keys collapse to last-wins under jq, so a duplicated file would
  # otherwise read as whatever value came last. Reject it before the version
  # decides anything.
  if [[ -f "$file" ]]; then
    _schema_duplicate_keys "$file" || return 1
  fi
  v=$(repo_data_version)
  case "$v" in
    1|2)
      # Parity suites exercise the legacy readers with this hatch. Normal CLI
      # callers never set it. The dedicated guard tests unset it.
      if [[ "${REPLICANT_TEST_ALLOW_LEGACY_WRITES:-}" == 1 ]]; then return 0; fi
      printf 'replicant: this repo uses the version %s layout, which is read-only here — migrate it to version 3, then retry\n' "$v" >&2
      return 1 ;;
    3)
      _schema_marker_valid || return 1
      v3_no_legacy_files || return 1
      return 0 ;;
    unknown)
      printf 'replicant: the repo schema at .replicant/schema.json is unreadable — restore it from git history, or start over with a fresh repo\n' >&2
      return 1 ;;
    *)
      printf 'replicant: this repo uses data format %s, this client writes up to %s — update the plugin, then retry\n' "$v" "$SCHEMA_VERSION" >&2
      return 1 ;;
  esac
}

# _v3_top_keys: kept as the alias the migration path uses while it still
# stages version 2 repositories. New code calls _schema_top_keys.
_v3_top_keys() { _schema_top_keys "$@"; }
_v2_top_keys() { _schema_top_keys "$@"; }

# _v3_struct_tsv: the structural half of entries validation. Prints one
# id<TAB>path<TAB>kind<TAB>scope<TAB>source line per entry, sorted by id, or
# fails naming the exact entry and field. jq error() carries the message, and
# the need() helper turns each rule into pass-through or failure.
_v3_struct_tsv() {
  jq -r '
    def need(c; msg): if c then . else error(msg) end;
    need(type == "object"; "entries: not a JSON object")
    | to_entries | sort_by(.key) | .[]
    | .key as $id | .value as $e
    | need($id | test("^[A-Za-z0-9._/\\-]+$"); "entries: bad id \($id)")
    | need(($e | type) == "object"; "entries \($id): not an object")
    | [$e.path, $e.kind, $e.scope, $e.source]
    | need(map(type) == ["string","string","string","string"]; "entries \($id): path, kind, scope and source must be strings")
    | .[0] as $p | .[1] as $k | .[2] as $s | .[3] as $o
    | need((($p | test("[\u0000-\u001f\u007f]")) | not); "entries \($id): path holds a control character")
    | need($p | startswith("/"); "entries \($id): path is not absolute")
    | need((($p | test("(^|/)\\.\\.(/|$)")) | not); "entries \($id): path climbs with ..")
    | need((($p | test("//")) | not); "entries \($id): path holds //")
    | need($k == "config" or $k == "dir"; "entries \($id): kind is not config or dir")
    | need(if $k == "dir" then ($p | endswith("/")) else (($p | endswith("/")) | not) end; "entries \($id): dir paths end with /, files do not")
    | need($s == "shared" or $s == "profile" or $s == "off"; "entries \($id): scope is not shared, profile or off")
    | need($o == "user" or $o == "override"; "entries \($id): source is not user or override")
    | [$id, $p, $k, $s, $o] | @tsv' "$1"
}
_v2_struct_tsv() { _v3_struct_tsv "$@"; }

# validate_v3_entries [file]: 0 when the entries file is sound. Default is the
# repo's own entries.json. A missing file is an error here: callers that
# accept its absence (a fresh v3 skeleton) check for the file themselves.
# Every failure names the entry and the rule on stderr and leaves the repo
# untouched: validation reads, never writes.
#
# Checks jq cannot do alone happen here on the parsed rows: two IDs sharing
# one live path, a directory entry swallowing another entry, a live path
# inside the data repo or the local state dir, and a live path that is a
# socket, device or fifo. A path that does not exist is fine: that is the
# missing state, not a broken record. The nesting loop is O(n*n); the section
# 4 registry reimplements it when entries become a hot path.
validate_v3_entries() {
  local file="${1:-$REPO_DIR/.replicant/entries.json}" key dups tsv
  [[ -f "$file" ]] || { printf 'entries: %s is missing\n' "$file" >&2; return 1; }
  dups=$(_schema_top_keys "$file" | sort | uniq -d)
  if [[ -n "$dups" ]]; then
    printf 'entries: duplicate id %s\n' "$dups" | head -n1 >&2
    return 1
  fi
  tsv=$(_v3_struct_tsv "$file" 2>&1) || { printf '%s\n' "$tsv" | sed -e 's/^jq: error ([^)]*): //' >&2; printf 'entries: %s is invalid\n' "$file" >&2; return 1; }
  local -a ids=() paths=()
  local id p k s o i j
  while IFS=$'\t' read -r id p k s o; do
    [[ -n "${id:-}" ]] || continue
    ids+=("$id"); paths+=("$p")
  done <<<"$tsv"
  local -A seen=()
  for i in "${!ids[@]}"; do
    id="${ids[$i]}"; p="${paths[$i]}"
    if [[ -n "${seen[$p]:-}" ]]; then
      printf 'entries %s and %s share the live path %s\n' "${seen[$p]}" "$id" "$p" >&2
      return 1
    fi
    seen[$p]="$id"
    if [[ "$p" == "$REPO_DIR" || "$p" == "$REPO_DIR/"* || "$p" == "$REPLICANT_HOME" || "$p" == "$REPLICANT_HOME/"* ]]; then
      printf 'entries %s: live path is inside the data repo\n' "$id" >&2
      return 1
    fi
    if [[ -e "$p" ]] && [[ ! -f "$p" && ! -d "$p" ]]; then
      printf 'entries %s: %s is a socket, device or fifo\n' "$id" "$p" >&2
      return 1
    fi
  done
  for i in "${!ids[@]}"; do
    [[ "${paths[$i]}" == */ ]] || continue
    for j in "${!ids[@]}"; do
      [[ "$i" != "$j" && "${paths[$j]}" == "${paths[$i]}"* ]] || continue
      printf 'entries %s swallows %s: nested tracked roots\n' "${ids[$i]}" "${ids[$j]}" >&2
      return 1
    done
  done
  return 0
}

# load_v3_entries [file]: the validated rows as id<TAB>path<TAB>kind<TAB>
# scope<TAB>source, sorted by id. An empty object loads as no rows: a missing
# v3 record means the shipped default policy (the registry reads it that way).
load_v3_entries() {
  local file="${1:-$REPO_DIR/.replicant/entries.json}"
  validate_v3_entries "$file" || return 1
  jq -r 'to_entries | sort_by(.key)[] | [.key, .value.path, .value.kind, .value.scope, .value.source] | @tsv' "$file"
}

# validate_v2_entries, load_v2_entries: the migration path still stages
# version 2 repositories until migrate-v3 replaces it. The record shape is
# the same, so these are aliases, not forks.
validate_v2_entries() { validate_v3_entries "$@"; }
load_v2_entries() { load_v3_entries "$@"; }

# v3_entries_upsert <id> <path> <kind> <scope> <source>: write one entries
# record, validating before and after. The file is written through a temporary
# file and one rename, so a failure never leaves a half-written policy.
v3_entries_upsert() {
  local id="$1" path="$2" kind="$3" scope="$4" source="$5"
  local file="$REPO_DIR/.replicant/entries.json" tmp
  v3_require_valid_entries || return 1
  [[ -f "$file" ]] || printf '{}\n' > "$file"
  tmp=$(mktemp) || return 1
  jq --arg id "$id" --arg path "$path" --arg kind "$kind" \
    --arg scope "$scope" --arg source "$source" \
    '.[$id] = {path: $path, kind: $kind, scope: $scope, source: $source}' \
    "$file" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  validate_v3_entries "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$file"
  V3_ENTRIES_OK=1
  invalidate_scopes_cache 2>/dev/null || true
  return 0
}

# v3_entries_remove <id>: drop one entries record, validating before and
# after. Removing the last record leaves an empty object, never a missing file.
v3_entries_remove() {
  local id="$1"
  local file="$REPO_DIR/.replicant/entries.json" tmp
  v3_require_valid_entries || return 1
  [[ -f "$file" ]] || return 0
  tmp=$(mktemp) || return 1
  jq --arg id "$id" 'del(.[$id])' "$file" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  validate_v3_entries "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$file"
  V3_ENTRIES_OK=1
  invalidate_scopes_cache 2>/dev/null || true
  return 0
}

# policy_store_state: a fingerprint of the mutable policy stores, for
# callers that must tell a no-op from a change. Legacy layouts hash the track
# file; version 3 hashes entries.json and the canonical secret id list (or
# the lock state when the vault does not open).
policy_store_state() {
  if repo_is_v3; then
    sha256sum "$REPO_DIR/.replicant/entries.json" 2>/dev/null || printf 'no-entries\n'
    vault_index_decrypt 2>/dev/null | jq -c '[.secrets[].id] | sort' 2>/dev/null || printf 'locked\n'
    return 0
  fi
  cat "$USER_TRACK_FILE" 2>/dev/null || true
}

# validate_machine_id [id]: 0 when the id is safe to build paths from. A
# machine id becomes a file name under .replicant/machines/ and a directory
# name under state/, so traversal and separators are refused before any path
# is constructed.
validate_machine_id() {
  [[ "${1:-}" =~ ^[A-Za-z0-9._-]+$ ]] || {
    printf 'machine id %s is not a safe file name\n' "${1:-<empty>}" >&2; return 1; }
  return 0
}

# machine_metadata_write [id]: records this machine beside the policy: its
# id, selected profile, client version and schema version. Four fields and
# nothing else: no secrets, no paths, nothing a scanner could trip on. The id
# is a file name, so it is checked before it touches the disk.
machine_metadata_write() {
  local id="${1:-$MACHINE}" dir="$REPO_DIR/.replicant/machines"
  validate_machine_id "$id" || return 1
  mkdir -p "$dir"
  jq -nc --arg id "$id" --arg profile "$(current_profile)" \
    --arg client "$(running_version)" --argjson schema "$SCHEMA_VERSION" \
    '{machineId: $id, profile: $profile, clientVersion: $client, schemaVersion: $schema}' > "$dir/$id.json"
}

# machine_profile [id]: the profile recorded for a machine, or nothing. The
# machine JSON record is the only store of the active profile on v3.
machine_profile() {
  local id="${1:-$MACHINE}"
  validate_machine_id "$id" || return 1
  jq -r '.profile // empty' "$REPO_DIR/.replicant/machines/$id.json" 2>/dev/null || true
}
