# shellcheck shell=bash disable=SC2034
# registry.sh: one normalized entry registry from every source that names one.
# Sourced by replicant-core.sh, which sets the paths it uses. It defines
# functions and data and runs nothing. Other modules read its data.
#
# Four sources name entries, and each used to be read where it was needed: the
# shipped lists (MANIFEST, SECRETS_MANIFEST), the v2 policy file
# (.replicant/entries.json), the discovered lists (user and auto), and the
# decrypted secret index (vault/index.age on v2). Four readers meant four
# answers to "what is tracked", so every loop that means "everything" joins
# them here instead.
#
# One row per entry, fields separated by tabs, sorted by id:
#
#   id, kind, source, category, scope, live path, repository path, blob, locked
#
# kind is config, dir or secret. source is manifest, user, auto or override.
# scope is shared, profile or off. A v2 secret carries its opaque blob id and
# locked tells whether this machine can read it; a v1 secret carries neither.
# The restore policy is not a field: a secret restores at mode 600 and every
# other entry restores as-is, then runs its category's apply step.

declare -g -a REGISTRY=()

# row_split <row> <n>: the first n tab fields, one per line. This is awk and
# not read on purpose: tab is IFS whitespace, so IFS=$'\t' read treats a run
# of tabs as one delimiter and an empty middle field shifts every field after
# it. A config row carries an empty blob, which is exactly that case.
row_split() {
  awk -F'\t' -v n="$2" '{for (i = 1; i <= n; i++) print $i}' <<<"$1"
}

# registry_build: fill REGISTRY from every source. Precedence when two sources
# name one id: a v2 override record wins over the shipped entry, and a user
# entry wins over an auto-discovered one (load_auto_manifest already refuses
# paths the user listed, and the guard here keeps that true if it ever slips).
registry_build() {
  local -A r_kind=() r_source=() r_live=() r_vscope=()
  local entry src rel
  for entry in "${MANIFEST[@]}"; do
    src="${entry%%:*}"; rel="${entry##*:}"
    r_live["$rel"]="$src"
    if is_dir_entry "$rel"; then r_kind["$rel"]="dir"; else r_kind["$rel"]="config"; fi
    r_source["$rel"]="manifest"
  done
  for entry in "${SECRETS_MANIFEST[@]}"; do
    src="${entry%%:*}"; rel="${entry##*:}"
    r_live["$rel"]="$src"
    r_kind["$rel"]="secret"
    r_source["$rel"]="manifest"
  done
  for entry in ${USER_MANIFEST[@]+"${USER_MANIFEST[@]}"}; do
    src="${entry%%:*}"; rel="${entry##*:}"
    r_live["$rel"]="$src"
    if is_dir_entry "$rel"; then r_kind["$rel"]="dir"; else r_kind["$rel"]="config"; fi
    r_source["$rel"]="user"
  done
  for entry in ${USER_SECRETS[@]+"${USER_SECRETS[@]}"}; do
    src="${entry%%:*}"; rel="${entry##*:}"
    r_live["$rel"]="$src"
    r_kind["$rel"]="secret"
    r_source["$rel"]="user"
  done
  for entry in ${AUTO_MANIFEST[@]+"${AUTO_MANIFEST[@]}"}; do
    src="${entry%%:*}"; rel="${entry##*:}"
    [[ -n "${r_live[$rel]:-}" ]] && continue
    r_live["$rel"]="$src"
    if is_dir_entry "$rel"; then r_kind["$rel"]="dir"; else r_kind["$rel"]="config"; fi
    r_source["$rel"]="auto"
  done
  # A v2 entry record overrides the shipped policy for its id, and adds ids
  # the shipped list never named. A missing record means the shipped default,
  # so an absent file here changes nothing. A present but invalid file fails
  # loudly: resolving its ids against the shipped default would point repo
  # paths at the wrong place.
  local v2=0
  [[ "$(repo_data_version 2>/dev/null)" == 2 ]] && v2=1
  if (( v2 )) && [[ -f "$REPO_DIR/.replicant/entries.json" ]]; then
    local rows id p k s o
    if ! rows=$(load_v2_entries 2>/dev/null); then
      printf 'registry: %s is invalid\n' "$REPO_DIR/.replicant/entries.json" >&2
      return 1
    fi
    while IFS=$'\t' read -r id p k s o; do
      [[ -n "${id:-}" ]] || continue
      r_live["$id"]="$p"
      r_kind["$id"]="$k"
      r_vscope["$id"]="$s"
      r_source["$id"]="$o"
    done <<<"$rows"
  fi
  # The vault decrypts once for the whole registry, not once per secret: an
  # empty vidx means the key is unusable here (locked), not an empty vault,
  # since a missing index.age decrypts to an empty registry instead.
  local vidx=""
  if (( v2 )); then
    vidx=$(vault_index_decrypt 2>/dev/null || true)
  fi
  SCOPE_MAP_READY=0; load_scope_map
  local prof
  prof=$(current_profile)
  local blobs
  blobs=$(vault_blobs_dir)
  REGISTRY=()
  local id category scope live repo blob locked
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    live="${r_live[$id]}"
    category=$(category_for_rel "$id")
    if [[ -n "${r_vscope[$id]:-}" ]]; then
      scope="${r_vscope[$id]}"
    else
      scope_into scope "$id"
    fi
    blob=""; locked="false"; repo=""
    if [[ "${r_kind[$id]}" == "secret" ]]; then
      if (( v2 )); then
        [[ -n "$vidx" ]] && blob=$(vault_index_blob "$vidx" "$id")
        [[ -n "$blob" ]] && repo="$blobs/$blob.age"
        [[ -z "$vidx" ]] && locked="true"
      else
        repo="$SECRETS_DIR/$id"
      fi
    else
      if [[ "$scope" == "profile" ]]; then
        repo="$REPO_DIR/profiles/$prof/config/$id"
      else
        repo="$CONFIG_DIR/$id"
      fi
    fi
    REGISTRY+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
      "$id" "${r_kind[$id]}" "${r_source[$id]}" "$category" "$scope" "$live" "$repo" "$blob" "$locked")")
  done < <(printf '%s\n' "${!r_live[@]}" | LC_ALL=C sort)
}

# registry_row_for <id>: the one registry row for an id, or nothing.
registry_row_for() {
  local id="$1" row
  for row in ${REGISTRY[@]+"${REGISTRY[@]}"}; do
    [[ "${row%%$'\t'*}" == "$id" ]] && { printf '%s\n' "$row"; return 0; }
  done
  return 1
}

# registry_field <row> <n>: the nth field of a registry row (1-based).
registry_field() {
  local row="$1" n="$2"
  awk -F'\t' -v n="$n" '{print $n}' <<<"$row"
}
