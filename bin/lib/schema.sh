# shellcheck shell=bash disable=SC2034
# schema.sh: the v2 data repository schema. Sourced by replicant-core.sh, which
# sets the paths it uses. It defines functions and data and runs nothing.
#
# Version 1 is the absence of .replicant/schema.json: the .replicant-track,
# .replicant-sync, .replicant-profiles and .replicant-version files beside
# config/, secrets/ and state/. Those repos keep working unchanged until the
# section 9 migration. Version 2 keeps the same content roots and moves the
# policy into .replicant/entries.json, with one machines/<id>.json per
# machine beside it.
#
# The one rule: a writer never mutates a repo whose format it cannot read.
# require_writable_schema is the first line of every core function that
# writes, and cmd_save checks the schema-gate command before it commits
# (a failed backup there does not stop the commit). Reads never block:
# status, diff, pull and dry runs keep answering on any schema. create, clone
# and init are not gated either: they make repos, they do not interpret them.
# reset and reset-all are not gated: they apply Omarchy defaults, never repo
# content. purge is the escape hatch and stays ungated on purpose.

# SCHEMA_VERSION is the highest dataVersion this client writes.
# SCHEMA_FORMAT is declared in schema.json for section 3; nothing reads a
# vault yet, so this is a promise of the format to come, not a reader.
SCHEMA_VERSION=2
SCHEMA_FORMAT="age-pq-v1"

# repo_data_version: prints 1, 2, a newer number, or unknown. It always
# succeeds: the caller decides what each answer means. A missing schema.json
# is version 1, so every repo written before section 2 reads exactly as it
# always did. An unreadable or versionless file is unknown, never a guess.
repo_data_version() {
  local file="$REPO_DIR/.replicant/schema.json" v
  [[ -f "$file" ]] || { printf '1\n'; return 0; }
  v=$(jq -r '.dataVersion // empty' "$file" 2>/dev/null || true)
  [[ "$v" =~ ^[0-9]+$ ]] || { printf 'unknown\n'; return 0; }
  printf '%s\n' "$v"
}

# require_writable_schema: 0 when this client may mutate a v2 repo. Version 1
# remains readable, but every writer stops before touching its worktree.
require_writable_schema() {
  local v
  v=$(repo_data_version)
  case "$v" in
    1)
      # Existing v1 parity suites use this only to exercise the legacy reader.
      # Normal CLI callers never set it. The dedicated v1 guard tests unset it.
      if [[ "${REPLICANT_TEST_ALLOW_LEGACY_WRITES:-}" == 1 ]]; then return 0; fi
      printf 'replicant: this repo uses the version 1 layout. Migrate it before saving, tracking, changing scope, or changing secrets\n' >&2
      return 1 ;;
    2) return 0 ;;
    unknown)
      printf 'replicant: the repo schema at .replicant/schema.json is unreadable — restore it from git history, or start over with a fresh repo\n' >&2
      return 1 ;;
    *)
      printf 'replicant: this repo uses data format %s, this client writes up to %s — update the plugin, then retry\n' "$v" "$SCHEMA_VERSION" >&2
      return 1 ;;
  esac
}

# _v2_top_keys: the top-level keys of a JSON object, one per line, in file
# order. jq cannot do this: it parses first, so duplicate keys collapse to
# last-wins before any filter sees them. This scans the raw text instead,
# tracking brace depth outside strings (braces inside strings do not count,
# and neither do nested keys). A non-object root lists nothing.
_v2_top_keys() {
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

# _v2_struct_tsv: the structural half of entries validation. Prints one
# id<TAB>path<TAB>kind<TAB>scope<TAB>source line per entry, sorted by id, or
# fails naming the exact entry and field. jq error() carries the message, and
# the need() helper turns each rule into pass-through or failure.
_v2_struct_tsv() {
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
    | need((($p | test("\n|\t|\r")) | not); "entries \($id): path holds a newline or tab")
    | need($p | startswith("/"); "entries \($id): path is not absolute")
    | need((($p | test("(^|/)\\.\\.(/|$)")) | not); "entries \($id): path climbs with ..")
    | need((($p | test("//")) | not); "entries \($id): path holds //")
    | need($k == "config" or $k == "dir"; "entries \($id): kind is not config or dir")
    | need(if $k == "dir" then ($p | endswith("/")) else (($p | endswith("/")) | not) end; "entries \($id): dir paths end with /, files do not")
    | need($s == "shared" or $s == "profile" or $s == "off"; "entries \($id): scope is not shared, profile or off")
    | need($o == "user" or $o == "override"; "entries \($id): source is not user or override")
    | [$id, $p, $k, $s, $o] | @tsv' "$1"
}

# validate_v2_entries [file]: 0 when the entries file is sound. Default is the
# repo's own entries.json. A missing file is an error here: callers that
# accept its absence (a v1 repo, a fresh v2 skeleton) check for the file
# themselves. Every failure names the entry and the rule on stderr and leaves
# the repo untouched: validation reads, never writes.
#
# Checks jq cannot do alone happen here on the parsed rows: two IDs sharing
# one live path, a directory entry swallowing another entry, a live path
# inside the data repo or the local state dir, and a live path that is a
# socket, device or fifo. A path that does not exist is fine: that is the
# missing state, not a broken record. The nesting loop is O(n*n); the section
# 4 registry reimplements it when entries become a hot path.
validate_v2_entries() {
  local file="${1:-$REPO_DIR/.replicant/entries.json}" key dups tsv
  [[ -f "$file" ]] || { printf 'entries: %s is missing\n' "$file" >&2; return 1; }
  dups=$(_v2_top_keys "$file" | sort | uniq -d)
  if [[ -n "$dups" ]]; then
    printf 'entries: duplicate id %s\n' "$dups" | head -n1 >&2
    return 1
  fi
  tsv=$(_v2_struct_tsv "$file" 2>&1) || { printf '%s\n' "$tsv" | sed -e 's/^jq: error ([^)]*): //' >&2; printf 'entries: %s is invalid\n' "$file" >&2; return 1; }
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

# load_v2_entries [file]: the validated rows as id<TAB>path<TAB>kind<TAB>
# scope<TAB>source, sorted by id. An empty object loads as no rows: a missing
# v2 record means the shipped default policy (section 4 reads it that way).
load_v2_entries() {
  local file="${1:-$REPO_DIR/.replicant/entries.json}"
  validate_v2_entries "$file" || return 1
  jq -r 'to_entries | sort_by(.key)[] | [.key, .value.path, .value.kind, .value.scope, .value.source] | @tsv' "$file"
}

# machine_metadata_write [id]: records this machine beside the policy: its
# id, selected profile, client version and schema version. Four fields and
# nothing else: no secrets, no paths, nothing a scanner could trip on. The id
# is a file name, so it is checked before it touches the disk.
machine_metadata_write() {
  local id="${1:-$MACHINE}" dir="$REPO_DIR/.replicant/machines"
  [[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] || { printf 'machine id %s is not a safe file name\n' "$id" >&2; return 1; }
  mkdir -p "$dir"
  jq -nc --arg id "$id" --arg profile "$(current_profile)" \
    --arg client "$(running_version)" --argjson schema "$SCHEMA_VERSION" \
    '{machineId: $id, profile: $profile, clientVersion: $client, schemaVersion: $schema}' > "$dir/$id.json"
}
