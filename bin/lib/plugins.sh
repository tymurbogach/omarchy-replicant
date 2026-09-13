# shellcheck shell=bash disable=SC2034
# plugins.sh: plugins and themes: origins, inventories, and installs on request.
# Sourced by replicant-core.sh, which sets the paths it uses. It defines
# functions and data and runs nothing. Other modules read its data.

# build_pending_reinstalls_json — third-party themes/plugins the inventory
# knows about but this machine does not have. `restore` never installs these
# on its own (restore_themes/restore_plugins in the CLI only report them) —
# this is the list the panel renders as its own row, one Install button per
# item, so fetching someone else's current code is always a decision made in
# the moment, not a side effect of "bring my stuff back".
build_pending_reinstalls_json() {
  # One TSV stream for both kinds, one jq — the same shape build_backups_json
  # below uses, instead of one jq process per pending item.
  {
    while IFS=$'\t' read -r tname torigin; do
      [[ -n "$tname" ]] || continue
      printf 'theme\t%s\t%s\t\n' "$tname" "$torigin"
    done < <(missing_themes)
    while IFS=$'\t' read -r pid porigin pmethod; do
      [[ -n "$pid" ]] || continue
      printf 'plugin\t%s\t%s\t%s\n' "$pid" "$porigin" "$pmethod"
    done < <(missing_plugins)
  } | jq -Rsc '
    split("\n") | map(select(length > 0) | split("\t") | {
      kind: .[0], id: .[1], origin: .[2], method: (.[3] // "")
    })'
}

# Where a plugin came from, when nothing records it directly.
#
# Omarchy does not store an origin: `omarchy plugin list --json` has no such
# field and `omarchy plugin update` simply skips anything without a .git, so a
# plugin copied into place has no trail of its own. It still usually HAS a
# home — you just have to work it out. In order:
#
#   1. a git remote on the installed copy                        -> add
#   2. a remote on the local checkout that remote points at       -> add
#   3. `clonedFrom` in the manifest, i.e. an edited copy of a
#      built-in Omarchy plugin                                    -> clone
#   4. a checkout on this machine whose manifest carries the same
#      id — how a plugin you wrote yourself gets installed         -> add
#
# (4) only resolves on the machine that holds the checkout, which is exactly
# the machine recording the inventory. The URL it finds travels in the repo, so
# the other machine reads a URL and never needs the checkout.
PLUGIN_SOURCE_ROOTS=("$HOME/Projects" "$HOME/src" "$HOME/code" "$HOME/projects" "$HOME/git" "$HOME/work")

resolve_plugin_origin() {
  local pdir="$1" pid="$2" pmf="$3" origin from m mid mroot
  origin=$(git -C "$pdir" remote get-url origin 2>/dev/null || true)

  # 1 & 2 — a remote, possibly via a local checkout it points at.
  if [[ -n "$origin" ]]; then
    if [[ "$origin" == /* && -d "$origin/.git" ]]; then
      # Resolve THROUGH the checkout: its own remote is where this really lives.
      # Accepted even when that is itself a path (a bare repo on a NAS, say) —
      # a path is at least a lead, and recording nothing makes the plugin
      # disappear silently. `doctor` is what says a path may not resolve
      # elsewhere; the inventory's job is to not lose the trail.
      from=$(git -C "$origin" remote get-url origin 2>/dev/null || true)
      [[ -n "$from" ]] && { printf '%s\tadd\n' "$from"; return 0; }
    elif [[ "$origin" != /* ]]; then
      printf '%s\tadd\n' "$origin"; return 0
    fi
  fi

  # 3 — a clone of a built-in. Restores the built-in, not the edits; the
  # inventory says so in its header rather than implying a full recovery.
  from=$(jq -r '.omarchy.clonedFrom // empty' "$pmf" 2>/dev/null || true)
  [[ -n "$from" ]] && { printf '%s\tclone\n' "$from"; return 0; }

  # 4 — a checkout of your own on this machine that builds this same plugin.
  for mroot in "${PLUGIN_SOURCE_ROOTS[@]}"; do
    [[ -d "$mroot" ]] || continue
    while IFS= read -r m; do
      [[ -n "$m" ]] || continue
      mid=$(jq -r '.id // empty' "$m" 2>/dev/null) || continue
      [[ "$mid" == "$pid" ]] || continue
      from=$(git -C "$(dirname "$m")" rev-parse --show-toplevel 2>/dev/null) || continue
      from=$(git -C "$from" remote get-url origin 2>/dev/null || true)
      [[ -n "$from" ]] && { printf '%s\tadd\n' "$from"; return 0; }
    done < <(find "$mroot" -maxdepth 4 -name manifest.json -not -path '*/node_modules/*' 2>/dev/null)
  done

  printf -- '-\t-\n'
}

# Plugins that exist ONLY on this machine: no git origin, so nothing can rebuild
# them anywhere. They are usually the user's own, written in place. Worth naming
# rather than skipping in silence, because shell.json lists them in the bar
# layout — restore it on a machine that lacks them and the bar comes back with
# holes in it.
local_only_plugins() {
  local pmf pid pdir porigin pmethod
  for pmf in "$HOME/.config/omarchy/plugins"/*/manifest.json; do
    [[ -f "$pmf" ]] || continue
    pdir="$(dirname "$pmf")"
    pid=$(jq -r '.id // empty' "$pmf" 2>/dev/null) || continue
    [[ -n "$pid" ]] || continue
    IFS=$'\t' read -r porigin pmethod < <(resolve_plugin_origin "$pdir" "$pid" "$pmf")
    [[ "$porigin" == "-" ]] && printf '%s\n' "$pid"
  done
}

# cloned_plugins — ids whose only origin is `omarchy plugin clone <built-in>`.
#
# These have a recorded origin, so local_only_plugins never names them and
# doctor reported "every installed plugin can be reinstalled from its origin" —
# which is true of the plugin and false of the work in it. `clone` reinstalls
# the BUILT-IN; a clone exists because somebody edited it, and the edits are the
# whole reason it is there. On the machine this was written on that was one
# hand-written indicator and a Matrix-rain lock screen, shader and all, existing
# nowhere else on earth.
#
# No diff against the built-in: `clone` means edited by construction, the built-in
# lives at a path this function would have to go hunting for, and a check that
# can be wrong about whether your work is backed up is worse than one that always
# tells you where it stands. Same answer as a hand-made theme — track the
# directory.
cloned_plugins() {
  local pmf pid pdir porigin pmethod
  for pmf in "$HOME/.config/omarchy/plugins"/*/manifest.json; do
    [[ -f "$pmf" ]] || continue
    pdir="$(dirname "$pmf")"
    pid=$(jq -r '.id // empty' "$pmf" 2>/dev/null) || continue
    [[ -n "$pid" ]] || continue
    IFS=$'\t' read -r porigin pmethod < <(resolve_plugin_origin "$pdir" "$pid" "$pmf")
    # A third column: the command that regenerates this clone, if it says so.
    # `omarchy plugin clone` produces a directory nobody owns, but a pack can
    # own one — omarchy-matrix derives its lock screen from Omarchy's current
    # source on every update precisely so a frozen copy cannot fall behind.
    # Backing that up is worse than not: you freeze the thing it exists to avoid.
    # The convention is `omarchy.derivedBy` in the clone's manifest, naming the
    # command; anything else is hand-made and on its own.
    local pderiv
    pderiv=$(jq -r '.omarchy.derivedBy // empty' "$pmf" 2>/dev/null || true)
    [[ "$pmethod" == "clone" ]] && printf '%s\t%s\t%s\n' "$pid" "$pdir" "$pderiv"
  done
  # The loop's last `&&` decides the exit status, so a run whose final plugin is
  # not a clone "failed" — and under the CLI's `set -e` that killed doctor in
  # the middle, silently, still exiting 0 through a pipe. Same shape as the
  # `grep -q` under pipefail trap: an incidental status read as an error.
  return 0
}

# edited_plugins — "id<TAB>dir<TAB>uncommitted<TAB>local-commits" for every
# installed plugin whose checkout holds work its origin does not have.
#
# The same hole as a clone, behind an origin that looks fine: install-plugin on
# the other machine fetches the ORIGIN's code, so an edit made in place, or a
# commit never pushed, does not come back. Omaplug sorts plugins the same way
# before it offers an update ("local changes").
#
# Offline on purpose: upstream is what the last fetch knew, the remote refs and
# FETCH_HEAD both. Doctor has no business touching the network for every plugin.
# `--no-optional-locks`: the shell watches every plugin directory for writes
# and reloads the plugin on one, and a plain `git status` can rewrite the index.
# A symlinked plugin is a development checkout, the project's business rather
# than the backup's, and Omaplug treats it the same way.
edited_plugins() {
  local pmf pdir pid dirty ahead
  local -a upstream
  for pmf in "$HOME/.config/omarchy/plugins"/*/manifest.json; do
    [[ -f "$pmf" ]] || continue
    pdir="${pmf%/manifest.json}"
    [[ -L "$pdir" || ! -d "$pdir/.git" ]] && continue
    git -C "$pdir" remote get-url origin >/dev/null 2>&1 || continue
    pid=$(jq -r '.id // empty' "$pmf" 2>/dev/null)
    [[ -n "$pid" ]] || continue
    dirty=$(git --no-optional-locks -C "$pdir" status --porcelain --untracked-files=normal 2>/dev/null | grep -c . || true)
    # FETCH_HEAD counts as upstream. `omarchy plugin update` fetches `origin
    # HEAD` into FETCH_HEAD and fast-forwards to it, and never moves
    # refs/remotes: a plugin updated that way looked 36 commits ahead.
    upstream=(--remotes)
    git -C "$pdir" rev-parse -q --verify FETCH_HEAD >/dev/null 2>&1 && upstream+=(FETCH_HEAD)
    ahead=$(git -C "$pdir" rev-list --count HEAD --not "${upstream[@]}" 2>/dev/null || echo 0)
    (( dirty > 0 || ahead > 0 )) || continue
    # HEAD can be behind while the files already match a commit upstream.
    # Porcelain then counts every difference to HEAD as an edit, and doctor
    # called such a plugin "14 uncommitted changes". Files that match an
    # upstream commit hold no work of their own.
    upstream_tree_matches "$pdir" && continue
    printf '%s\t%s\t%s\t%s\n' "$pid" "$pdir" "$dirty" "$ahead"
  done
  return 0
}

# tree_matches_commit <dir> <commit>: are the files of the checkout exactly
# the files of that commit, untracked files included? A temporary index is
# built from the commit, so the checkout's own index is never written. The
# shell reloads a plugin on any write under its directory.
tree_matches_commit() {
  local dir="$1" commit="$2" idx rc=1
  idx=$(mktemp) || return 1
  if GIT_INDEX_FILE="$idx" git -C "$dir" read-tree "$commit" 2>/dev/null \
     && GIT_INDEX_FILE="$idx" git --no-optional-locks -C "$dir" diff --quiet 2>/dev/null \
     && [[ -z "$(GIT_INDEX_FILE="$idx" git --no-optional-locks -C "$dir" ls-files --others --exclude-standard 2>/dev/null)" ]]; then
    rc=0
  fi
  rm -f "$idx"
  return "$rc"
}

# upstream_tree_matches <dir>: do the files match FETCH_HEAD or the tip of any
# remote branch? Offline, like edited_plugins: it asks only what the last
# fetch knew.
upstream_tree_matches() {
  local dir="$1" tip
  local -a tips=()
  mapfile -t tips < <({ git -C "$dir" rev-parse -q --verify FETCH_HEAD 2>/dev/null
                       git -C "$dir" for-each-ref --format='%(objectname)' refs/remotes 2>/dev/null; } | sort -u)
  for tip in ${tips[@]+"${tips[@]}"}; do
    tree_matches_commit "$dir" "$tip" && return 0
  done
  return 1
}

# Plugins are not files to copy back — they are repos to reinstall. The saved
# inventory records each one's id and git origin so a second machine can be
# rebuilt with the command Omarchy itself provides.
missing_plugins() {
  local inv="$STATE_DIR/omarchy-plugins.txt" pid pver porigin pmethod
  [[ -f "$inv" ]] || { for inv in "$STATE_ROOT"/*/omarchy-plugins.txt; do [[ -f "$inv" ]] && break; done; }
  [[ -f "$inv" ]] || return 0
  while IFS=$'\t' read -r pid pver porigin pmethod; do
    [[ -n "$pid" && "$pid" != \#* ]] || continue
    [[ -d "$HOME/.config/omarchy/plugins/$pid" ]] && continue
    [[ "$porigin" == "-" || -z "$porigin" ]] && continue
    # An inventory written before the method column existed only ever meant add.
    [[ -z "$pmethod" || "$pmethod" == "-" ]] && pmethod=add
    printf '%s\t%s\t%s\n' "$pid" "$porigin" "$pmethod"
  done < "$inv"
}

# The same question about themes: which of the ones recorded in the repo is not
# on this machine, and where does it come from. Any machine's inventory will
# do — unlike a package list, a theme is not machine-specific, and the whole
# point is that the laptop can install what the desktop had.
missing_themes() {
  local inv tname torigin
  for inv in "$STATE_DIR/omarchy-themes.txt" "$STATE_ROOT"/*/omarchy-themes.txt; do
    [[ -f "$inv" ]] || continue
    while IFS=$'\t' read -r tname torigin; do
      [[ -n "$tname" && "$tname" != \#* ]] || continue
      [[ -d "$HOME/.config/omarchy/themes/$tname" ]] && continue
      [[ "$torigin" == "-" || -z "$torigin" ]] && continue
      printf '%s\t%s\n' "$tname" "$torigin"
    done < "$inv"
  done | sort -u
}

# core_install_theme <name> — install ONE third-party theme from its recorded
# origin, on demand. Never called automatically: `restore` only ever reports
# a theme as pending (see restore_themes in the CLI) and this is the explicit
# action that actually fetches whatever is at that origin right now.
#
# Two machines can record the same theme name with two different origins. A
# name alone then does not say which address the user agreed to, so this
# refuses and prints both rather than install the first match it finds.
core_install_theme() {
  local want="${1:-}" tname torigin
  local -a origins=()
  [[ -n "$want" ]] || { echo "usage: install-theme <name>" >&2; return 1; }
  while IFS=$'\t' read -r tname torigin; do
    [[ "$tname" == "$want" ]] || continue
    origins+=("$torigin")
  done < <(missing_themes)
  local -a unique_origins=()
  if (( ${#origins[@]} > 0 )); then
    mapfile -t unique_origins < <(printf '%s\n' "${origins[@]}" | sort -u)
  fi
  if (( ${#unique_origins[@]} == 0 )); then
    echo "$want is not a pending third-party theme (already installed, or not in the inventory)" >&2
    return 1
  fi
  if (( ${#unique_origins[@]} > 1 )); then
    echo "$want is recorded with more than one origin — refusing to guess which one to install:" >&2
    printf '  %s\n' "${unique_origins[@]}" >&2
    return 1
  fi
  command -v omarchy >/dev/null 2>&1 || { echo "omarchy not found on PATH" >&2; return 1; }
  omarchy theme install "${unique_origins[0]}" || { echo "$want — omarchy theme install failed (${unique_origins[0]})" >&2; return 1; }
  echo "$want installed from ${unique_origins[0]} — this also makes it the active theme" >&2
}

# ─── What the marketplace checked, asked only when a person installs ───────
# Omaplug reads the same catalog fields. The catalog is 7.6 MB, so it is
# fetched at most once an hour, and never by the status poll: only when a
# person asks to install a plugin. It informs and never refuses, because
# `omarchy plugin add` takes no commit to pin to.
MARKETPLACE_CATALOG_URL="${REPLICANT_CATALOG_URL:-https://plugins.omarchy.org/catalog.json}"
CATALOG_CACHE="$REPLICANT_HOME/catalog.json"
CATALOG_MAX_AGE=3600

# marketplace_catalog: print the path of a catalog no older than an hour.
marketplace_catalog() {
  local tmp age
  if [[ -f "$CATALOG_CACHE" ]]; then
    age=$(( $(date +%s) - $(stat -c %Y "$CATALOG_CACHE" 2>/dev/null || echo 0) ))
    if (( age < CATALOG_MAX_AGE )); then printf '%s\n' "$CATALOG_CACHE"; return 0; fi
  fi
  mkdir -p "$REPLICANT_HOME" 2>/dev/null || return 1
  tmp=$(mktemp "$REPLICANT_HOME/catalog.XXXXXX") || return 1
  if curl -fsSL --max-time 20 -o "$tmp" "$MARKETPLACE_CATALOG_URL" 2>/dev/null \
     && jq -e '.plugins | type == "array"' "$tmp" >/dev/null 2>&1; then
    mv -f "$tmp" "$CATALOG_CACHE"
  else
    rm -f "$tmp"
  fi
  [[ -f "$CATALOG_CACHE" ]] || return 1
  printf '%s\n' "$CATALOG_CACHE"
}

normalize_repo_url() { printf '%s\n' "$1" | sed -E 's#\.git$##; s#/$##' | tr '[:upper:]' '[:lower:]'; }

# core_plugin_verification <id> [origin]: the marketplace status of a plugin,
# and where its origin is now, as plain facts on stdout. The origin is asked
# only when the catalog names a commit to compare it with.
core_plugin_verification() {
  local id="$1" origin="${2:-}" catalog entry vstatus vcommit now
  [[ -n "$origin" ]] || origin=$(missing_plugins | awk -F'\t' -v i="$id" '$1 == i { print $2; exit }')
  if ! catalog=$(marketplace_catalog); then
    echo "Marketplace: the catalog could not be read (offline?)."
    return 0
  fi
  entry=$(jq -c --arg id "$id" --arg repo "$(normalize_repo_url "${origin:-none}")" '
    [.plugins[] | select(.id == $id or ((.repo // "") | ascii_downcase
      | sub("\\.git$"; "") | sub("/$"; "")) == $repo)][0] // empty' "$catalog" 2>/dev/null)
  if [[ -z "$entry" ]]; then
    echo "Marketplace: $id is not listed."
    return 0
  fi
  vstatus=$(jq -r '.verificationStatus // "unknown"' <<<"$entry")
  vcommit=$(jq -r '.verificationCommit // .listingValidatedCommit // ""' <<<"$entry")
  echo "Marketplace: $id is listed as $vstatus${vcommit:+, checked at ${vcommit:0:12}}."
  [[ -n "$vcommit" && -n "$origin" && "$origin" != "-" ]] || return 0
  now=$(timeout 15 git ls-remote "$origin" HEAD 2>/dev/null | awk 'NR == 1 { print $1 }')
  if [[ -z "$now" ]]; then
    echo "Origin: $origin could not be reached."
  elif [[ "$now" == "$vcommit" ]]; then
    echo "Origin: $origin is still at the commit that the marketplace checked."
  else
    echo "Origin: $origin is at ${now:0:12} now. It has moved since the marketplace checked it."
  fi
}

# core_install_plugin <id> — the same action for a plugin. `missing_plugins`
# already carries the method column that tells clone (an edited built-in)
# from add (a real third-party plugin) — same two commands restore_plugins
# already knew how to call, just no longer called without being asked.
# Ambiguity is refused here too, on the origin and the method together.
core_install_plugin() {
  local want="${1:-}" pid porigin pmethod
  local -a pairs=()
  [[ -n "$want" ]] || { echo "usage: install-plugin <id>" >&2; return 1; }
  while IFS=$'\t' read -r pid porigin pmethod; do
    [[ "$pid" == "$want" ]] || continue
    pairs+=("$porigin"$'\t'"$pmethod")
  done < <(missing_plugins)
  local -a unique_pairs=()
  if (( ${#pairs[@]} > 0 )); then
    mapfile -t unique_pairs < <(printf '%s\n' "${pairs[@]}" | sort -u)
  fi
  if (( ${#unique_pairs[@]} == 0 )); then
    echo "$want is not a pending third-party plugin (already installed, or not in the inventory)" >&2
    return 1
  fi
  if (( ${#unique_pairs[@]} > 1 )); then
    echo "$want is recorded with more than one origin — refusing to guess which one to install:" >&2
    printf '  %s\n' "${unique_pairs[@]}" | sed 's/\t/ (method: /; s/$/)/' >&2
    return 1
  fi
  local origin="${unique_pairs[0]%%$'\t'*}" method="${unique_pairs[0]#*$'\t'}"
  command -v omarchy >/dev/null 2>&1 || { echo "omarchy not found on PATH" >&2; return 1; }
  # A clone copies Omarchy's own built-in, which has no marketplace entry.
  [[ "$method" == "clone" ]] || core_plugin_verification "$want" "$origin" >&2
  if [[ "$method" == "clone" ]]; then
    omarchy plugin clone "$origin" || { echo "$want — omarchy plugin clone failed" >&2; return 1; }
    echo "$want re-cloned from $origin (any edits you made are not in this)" >&2
  else
    omarchy plugin add "$origin" --enable --yes || { echo "$want — omarchy plugin add failed" >&2; return 1; }
    echo "$want installed from $origin" >&2
  fi
}

# A theme installed here that no origin can be worked out for — a hand-made one
# in ~/.config/omarchy/themes. Nothing reinstalls it, so `doctor` says so and
# the answer is to track that directory in .replicant-track.
local_only_themes() {
  local tdir tname
  for tdir in "$HOME/.config/omarchy/themes"/*/; do
    [[ -d "$tdir" ]] || continue
    tname=$(basename "${tdir%/}")
    git -C "${tdir%/}" remote get-url origin >/dev/null 2>&1 && continue
    is_tracked_path "${tdir%/}/" && continue
    printf '%s\n' "$tname"
  done
}
