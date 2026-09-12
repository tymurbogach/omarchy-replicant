# shellcheck shell=bash disable=SC2034
# tree.sh: writing files and directory trees, with a backup of what they replace.
# Sourced by replicant-core.sh, which sets the paths it uses. It defines
# functions and data and runs nothing. Other modules read its data.

# install helpers — install_file() writes with a .bak.<epoch> of whatever it overwrites
DRY=${DRY:-0}
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1" >&2; }
skip() { printf '  \033[33m·\033[0m %s\n' "$1" >&2; }
run()  { if (( DRY )); then printf '  \033[36m»\033[0m %s\n' "$*" >&2; else "$@"; fi; }
install_file() {
  local src=$1 dst=$2 mode=$3
  local short_path=${dst/#$HOME/\~}
  if [[ ! -f $src ]]; then
    skip "$short_path — source missing in the repo ($src)"
    return
  fi
  # A config symlinked into a dotfiles repo is still that config, so the write
  # goes through the link. `install` onto the name itself replaces the link with
  # a plain file, and the dotfiles repo silently stops seeing the change. The
  # backup is a copy of what the link points at, kept next to the tracked name,
  # where list_backups and undo look.
  local target=$dst
  if [[ -L $dst ]]; then
    target=$(readlink -f -- "$dst" 2>/dev/null) && [[ -f $target ]] || target=$dst
  fi
  if [[ -f $target ]] && cmp -s "$src" "$target"; then
    run chmod "$mode" "$target"
    ok "$short_path (already matches, mode $mode)"
    return
  fi
  if [[ -e $dst ]]; then
    run cp -a -- "$target" "$dst.bak.$(date +%s)"
    skip "$short_path — previous version saved as .bak.<epoch>"
  fi
  run install -D -m "$mode" "$src" "$target"
  ok "$short_path ($mode)"
}

# ─── Directory entries ──────────────────────────────────────────────────────
# A handful of things people configure are a small tree rather than one file —
# ~/.config/nvim is the obvious one. What is deliberately NOT here is anything
# that is really a git clone: the eight custom themes on the machine this was
# written on come to 556 MB, 400 of it inside their own .git directories, and
# copying that into a git repo would be both enormous and worse than the thing
# it replaced. Those get an inventory and `omarchy theme install` instead.
#
# .git is skipped inside a tracked tree for the same reason, one size down: a
# repo nested in a repo is not backed up by copying its objects around.
#
# Other tools' safety copies are skipped too. OmaSettings leaves
# `<file>.omasettings.bak` beside a file it edits for the first time (Neovim's
# options.lua, inside the tracked nvim/ tree), and `omarchy refresh config`
# leaves `<file>.bak.<epoch>`. Neither is configuration.
TREE_EXCLUDES=(".git" "node_modules" "__pycache__" ".cache" "*.omasettings.bak" "*.bak.[0-9]*")

# -H: a tracked directory that is itself a symlink into a dotfiles repo is still
# that directory. Without it find lists nothing under the link, and the
# two-way mirror then empties the repo's copy on the next save.
tree_find() {
  local root="${1%/}" e
  local -a prune=()
  for e in "${TREE_EXCLUDES[@]}"; do prune+=(-name "$e" -o); done
  find -H "$root" \( "${prune[@]}" -false \) -prune -o -type f -print 2>/dev/null
}

# tree_files <root> — paths inside the tree, relative to it, sorted.
tree_files() {
  local root="${1%/}"
  tree_find "$root" | sed "s|^$root/||" | sort
}

tree_count() { tree_find "${1%/}" | wc -l | tr -d ' '; }

# Do the two trees hold the same files with the same contents?
tree_same() {
  local a="${1%/}" b="${2%/}"
  [[ -d "$a" && -d "$b" ]] || return 1
  [[ "$(tree_files "$a")" == "$(tree_files "$b")" ]] || return 1
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    cmp -s "$a/$f" "$b/$f" || return 1
  done < <(tree_files "$a")
  return 0
}

# tree_diff_summary <from-dir> <to-dir> — what restoring would change, named
# but never quoted. A tree is too big to show as a unified diff in a terminal
# or a panel, and the question at restore time is which files move, not which
# bytes.
tree_diff_summary() {
  local a="${1%/}" b="${2%/}" f n_add=0 n_chg=0 n_del=0
  local -a add=() chg=() del=()
  if [[ ! -d "$b" ]]; then
    echo "(doesn't exist: would be created with $(tree_count "$a") files)"
    return 0
  fi
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if [[ ! -e "$b/$f" ]]; then add+=("$f"); n_add=$((n_add+1))
    elif ! cmp -s "$a/$f" "$b/$f"; then chg+=("$f"); n_chg=$((n_chg+1)); fi
  done < <(tree_files "$a")
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    [[ -e "$a/$f" ]] || { del+=("$f"); n_del=$((n_del+1)); }
  done < <(tree_files "$b")
  printf '%d added, %d changed, %d only on this machine\n' "$n_add" "$n_chg" "$n_del"
  for f in ${add[@]+"${add[@]}"}; do echo "  + $f"; done | head -n 20
  for f in ${chg[@]+"${chg[@]}"}; do echo "  ~ $f"; done | head -n 20
  # Restoring never deletes: install_tree writes what the repo has and leaves
  # the rest, so these are listed as information, not as a pending removal.
  for f in ${del[@]+"${del[@]}"}; do echo "  · $f (left alone)"; done | head -n 10
}

# copy_tree_into_repo <src-dir> <dst-dir> — mirror one tree into the repo, in
# both directions: a file deleted on the machine goes from the repo too, or a
# tracked directory would only ever grow. The destination is required to be
# inside the repo, because this is the one place the plugin removes a tree.
copy_tree_into_repo() {
  local src="${1%/}" dst="${2%/}" f
  case "$dst/" in "$REPO_DIR"/*) ;; *) echo "refusing to mirror outside the repo: $dst" >&2; return 1 ;; esac
  mkdir -p "$dst"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    mkdir -p "$dst/$(dirname "$f")"
    cp -f "$src/$f" "$dst/$f"
  done < <(tree_files "$src")
  # Prune what the source no longer has.
  local keep; keep=$(tree_files "$src")
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    grep -qxF "$f" <<<"$keep" || rm -f -- "$dst/$f"
  done < <(tree_files "$dst")
  find "$dst" -mindepth 1 -type d -empty -delete 2>/dev/null || true
}

# install_tree <repo-dir> <dst-dir> <mode> — the restore side, with the same
# .bak.<epoch> of the whole directory that install_file makes of one file.
install_tree() {
  local src="${1%/}" dst="${2%/}" mode="$3" f
  local short_path=${dst/#$HOME/\~}
  if [[ ! -d $src ]]; then skip "$short_path/ — not in the repo"; return; fi
  if [[ -d $dst ]] && tree_same "$src" "$dst"; then
    ok "$short_path/ (already matches, $(tree_count "$src") files)"
    return
  fi
  # Resolved first: `cp -a` of a symlinked directory copies the link, and a
  # backup that points at the tree about to be overwritten keeps nothing.
  if [[ -e $dst ]]; then
    run cp -a -- "$(readlink -f -- "$dst")" "$dst.bak.$(date +%s)"
    skip "$short_path/ — previous version saved as .bak.<epoch>"
  fi
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    run install -D -m "$mode" "$src/$f" "$dst/$f"
  done < <(tree_files "$src")
  ok "$short_path/ ($(tree_count "$src") files, $mode)"
}
