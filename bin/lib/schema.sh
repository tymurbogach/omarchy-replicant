# shellcheck shell=bash disable=SC2034
# Validation for the one Replicant repository format.

SCHEMA_FORMAT="replicant"
ENTRIES_VALID=0

repo_state() {
  [[ -e "$REPO_DIR/.git" ]] || { printf 'missing\n'; return; }
  require_ready_schema >/dev/null 2>&1 && printf 'ready\n' || printf 'invalid\n'
}
repo_exists() { [[ -e "$REPO_DIR/.git" ]]; }
repo_has_vault() { require_ready_schema >/dev/null 2>&1; }
repo_is_ready() { require_ready_schema >/dev/null 2>&1; }

_schema_top_keys() { jq -r 'if type == "object" then keys[] else empty end' "$1" 2>/dev/null; }
_schema_no_duplicate_keys() { jq empty "$1" >/dev/null 2>&1 || { printf 'schema: invalid JSON in %s\n' "$1" >&2; return 1; }; }

_schema_marker_valid() {
  local file="$REPO_DIR/.replicant/schema.json"
  [[ -f "$file" ]] || { echo 'schema: .replicant/schema.json is missing' >&2; return 1; }
  _schema_no_duplicate_keys "$file" || return 1
  jq -e 'type == "object" and keys == ["format"] and .format == "replicant"' "$file" >/dev/null 2>&1 || {
    echo 'schema: expected {"format":"replicant"}' >&2; return 1; }
}

no_plaintext_secrets() {
  local plain
  [[ -d "$SECRETS_DIR" ]] || return 0
  plain=$(find "$SECRETS_DIR" -type f -print -quit 2>/dev/null || true)
  [[ -z "$plain" ]] || { printf 'schema: plaintext secret file found at %s; use vault/ only\n' "$plain" >&2; return 1; }
}

_entries_struct_tsv() {
  jq -r '
    def need(c; msg): if c then . else error(msg) end;
    need(type == "object"; "entries: not a JSON object")
    | to_entries | sort_by(.key) | .[]
    | .key as $id | .value as $e
    | need($id | test("^[A-Za-z0-9._/\\-]+$") and (test("(^|/)\\.\\.(/|$)") | not) and (test("//") | not); "entries: bad id \($id)")
    | need(($e | type) == "object"; "entries \($id): not an object")
    | [$e.path, $e.kind, $e.scope, $e.source]
    | need(map(type) == ["string","string","string","string"]; "entries \($id): path, kind, scope and source must be strings")
    | .[0] as $p | .[1] as $k | .[2] as $s | .[3] as $o
    | need(($p | startswith("/")) and (($p | test("(^|/)\\.\\.(/|$)") | not)) and (($p | test("//") | not)); "entries \($id): invalid path")
    | need($k == "config" or $k == "dir"; "entries \($id): invalid kind")
    | need(if $k == "dir" then ($p | endswith("/")) else (($p | endswith("/")) | not) end; "entries \($id): invalid directory path")
    | need($s == "shared" or $s == "profile" or $s == "off"; "entries \($id): invalid scope")
    | need($o == "user" or $o == "override"; "entries \($id): invalid source")
    | [$id, $p, $k, $s, $o] | @tsv' "$1"
}

validate_entries() {
  local file="${1:-$REPO_DIR/.replicant/entries.json}" rows id path kind scope source i j
  [[ -f "$file" ]] || { printf 'entries: %s is missing\n' "$file" >&2; return 1; }
  _schema_no_duplicate_keys "$file" || return 1
  rows=$(_entries_struct_tsv "$file" 2>&1) || { printf '%s\n' "$rows" >&2; return 1; }
  local -a ids=() paths=(); local -A seen=()
  while IFS=$'\t' read -r id path kind scope source; do
    [[ -n "${id:-}" ]] || continue
    [[ -z "${seen[$path]:-}" ]] || { printf 'entries %s and %s share %s\n' "${seen[$path]}" "$id" "$path" >&2; return 1; }
    seen[$path]="$id"; ids+=("$id"); paths+=("$path")
    [[ "$path" != "$REPO_DIR" && "$path" != "$REPO_DIR/"* && "$path" != "$REPLICANT_HOME" && "$path" != "$REPLICANT_HOME/"* ]] || { printf 'entries %s: path is inside Replicant data\n' "$id" >&2; return 1; }
    [[ ! -e "$path" || -f "$path" || -d "$path" ]] || { printf 'entries %s: path is not a file or directory\n' "$id" >&2; return 1; }
  done <<<"$rows"
  for i in "${!ids[@]}"; do for j in "${!ids[@]}"; do
    [[ "$i" == "$j" || "${paths[$i]}" != */ || "${paths[$j]}" != "${paths[$i]}"* ]] || { printf 'entries %s contains %s\n' "${ids[$i]}" "${ids[$j]}" >&2; return 1; }
  done; done
}

load_entries() { local file="${1:-$REPO_DIR/.replicant/entries.json}"; validate_entries "$file" && jq -r 'to_entries | sort_by(.key)[] | [.key, .value.path, .value.kind, .value.scope, .value.source] | @tsv' "$file"; }
require_valid_entries() { (( ENTRIES_VALID )) && return 0; validate_entries || return 1; ENTRIES_VALID=1; }

require_ready_schema() {
  _schema_marker_valid || return 1
  [[ -d "$REPO_DIR/vault/blobs" ]] || { echo 'schema: vault/blobs is missing' >&2; return 1; }
  [[ -d "$REPO_DIR/.replicant/machines" ]] || { echo 'schema: machine records are missing' >&2; return 1; }
  no_plaintext_secrets || return 1
  validate_entries || return 1
}

entries_upsert() {
  local id="$1" path="$2" kind="$3" scope="$4" source="$5" file="$REPO_DIR/.replicant/entries.json" tmp
  require_valid_entries || return 1; tmp=$(mktemp) || return 1
  jq --arg id "$id" --arg path "$path" --arg kind "$kind" --arg scope "$scope" --arg source "$source" '.[$id] = {path: $path, kind: $kind, scope: $scope, source: $source}' "$file" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  validate_entries "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$file"; ENTRIES_VALID=1; invalidate_scopes_cache 2>/dev/null || true
}
entries_remove() {
  local id="$1" file="$REPO_DIR/.replicant/entries.json" tmp
  require_valid_entries || return 1; tmp=$(mktemp) || return 1
  jq --arg id "$id" 'del(.[$id])' "$file" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  validate_entries "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$file"; ENTRIES_VALID=1; invalidate_scopes_cache 2>/dev/null || true
}
policy_store_state() { sha256sum "$REPO_DIR/.replicant/entries.json" 2>/dev/null || true; vault_index_decrypt 2>/dev/null | jq -c '[.secrets[].id] | sort' 2>/dev/null || printf 'locked\n'; }
validate_machine_id() { [[ "${1:-}" =~ ^[A-Za-z0-9._-]+$ ]] || { printf 'machine id %s is not safe\n' "${1:-<empty>}" >&2; return 1; }; }
machine_metadata_write() { local id="${1:-$MACHINE}" dir="$REPO_DIR/.replicant/machines"; validate_machine_id "$id" || return 1; mkdir -p "$dir"; jq -nc --arg id "$id" --arg profile "$(current_profile)" --arg client "$(running_version)" '{machineId: $id, profile: $profile, clientVersion: $client}' > "$dir/$id.json"; }
machine_profile() { local id="${1:-$MACHINE}"; validate_machine_id "$id" || return 1; jq -r '.profile // empty' "$REPO_DIR/.replicant/machines/$id.json" 2>/dev/null || true; }
