# shellcheck shell=bash
# repo.sh: Git repository lifecycle and remote transport.
# Sourced by replicant-core.sh. Functions return status and write diagnostics;
# the CLI owns command parsing, confirmation, and presentation.

# bootstrap_fail_at <stage>: fail when REPLICANT_FAIL_BOOTSTRAP_AT names this
# stage (validate, activate, or push). Tests inject a failure at every
# bootstrap boundary through it, proving that no partial repo survives.
bootstrap_fail_at() {
  [[ "${REPLICANT_FAIL_BOOTSTRAP_AT:-}" == "$1" ]] || return 0
  printf 'bootstrap: injected failure before %s\n' "$1" >&2
  return 1
}

# Repository-shape writes (scope, policy, track, keys) commit through the
# transaction engine in bin/lib/transaction.sh: journal first, one commit of
# exactly the staged paths, push after activation. Nothing here commits
# directly, so no git failure can pass silently.

# repo_remote_url: the origin URL, or nothing. Read-only helper so the CLI
# never shells out to git itself.
repo_remote_url() { git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true; }

# repo_hooks_path: the repo's core.hooksPath, or nothing. Read-only helper
# so the CLI never shells out to git itself.
repo_hooks_path() { git -C "$REPO_DIR" config core.hooksPath 2>/dev/null || true; }

# repo_create <name> [do_push] [transport]: point a fresh v3 repo at a new
# private GitHub repo. Every remote preflight runs before any local mutation:
# a rejected or failed remote leaves the local repo exactly as it was. A
# PUBLIC remote is refused, never flipped: flipping it would be a visibility
# change the user never asked for. Origin is set last, after the local repo
# validates, so a failed create never leaves a re-pointed origin behind.
repo_create() {
  local name="$1" do_push="${2:-0}" transport="${3:-https}" gh_user current_url url vis
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ && ${#name} -le 100 && "$name" != "." && "$name" != ".." ]] || { echo "invalid name: $name" >&2; return 1; }
  [[ "$transport" == https || "$transport" == ssh ]] || { echo "invalid transport: $transport" >&2; return 1; }
  gh_user=$(gh api user --jq .login 2>/dev/null || gh auth status 2>&1 | grep -oP 'account \K\w+' | head -n1)
  if [[ -z "$gh_user" ]]; then
    echo "no gh user — run 'gh auth login', then retry 'omarchy-replicant create $name'" >&2
    return 1
  fi
  echo "creating github.com/$gh_user/$name --private ..." >&2
  if gh repo view "$gh_user/$name" >/dev/null 2>&1; then
    vis=$(gh repo view "$gh_user/$name" --json visibility --jq .visibility 2>/dev/null || echo "")
    if [[ "$vis" == PUBLIC ]]; then
      echo "repo github.com/$gh_user/$name already exists and is PUBLIC — replicant holds secrets, so it never uses a public repo" >&2
      echo "switch it to private by hand (gh repo edit $gh_user/$name --visibility private), then retry; nothing was changed locally" >&2
      return 1
    fi
  else
    gh repo create "$name" --private --description "Omarchy replicant private savegame" >/dev/null 2>&1 || {
      echo "gh create failed — run 'gh auth login', then retry 'omarchy-replicant create $name'" >&2
      return 1
    }
    vis=$(gh repo view "$gh_user/$name" --json visibility --jq .visibility 2>/dev/null || echo "")
    if [[ -n "$vis" && "$vis" != PRIVATE ]]; then
      echo "the new repo github.com/$gh_user/$name is $vis, not private — switch it to private by hand, then retry; nothing was changed locally" >&2
      return 1
    fi
  fi
  if [[ "$transport" == ssh ]]; then
    url="git@github.com:$gh_user/$name.git"
  else
    url="https://github.com/$gh_user/$name.git"
  fi
  if [[ "$(repo_state)" == missing ]]; then
    core_init || return 1
  else
    core_backup || return 1
  fi
  current_url=$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)
  if [[ -n "$current_url" && "$current_url" != "$url" ]]; then
    echo "repository already points at $current_url — re-point it by hand (git -C $REPO_DIR remote set-url origin $url), then retry; nothing was changed" >&2
    return 1
  elif [[ -z "$current_url" ]]; then
    git -C "$REPO_DIR" remote add origin "$url" || return 1
  fi
  git -C "$REPO_DIR" branch -M main 2>/dev/null || true
  git -C "$REPO_DIR" add -A
  if ! git -C "$REPO_DIR" diff --cached --quiet; then
    git -C "$REPO_DIR" commit -m "replicant: create $name $(date -Is)" || return 1
  fi
  if (( do_push )); then
    if ! bootstrap_fail_at push; then
      echo "push to $url held by injected failure — the local commit is kept; retry 'git -C $REPO_DIR push -u origin main'" >&2
      return 1
    fi
    git -C "$REPO_DIR" push -u origin main 2>&1 || git -C "$REPO_DIR" push -u origin HEAD 2>&1 || {
      echo "push to $url failed — the local commit is kept; run 'omarchy-replicant pull', then retry 'git -C $REPO_DIR push -u origin main'" >&2
      return 1
    }
    echo "pushed to $url (private)" >&2
  else
    echo "remote $url; run omarchy-replicant save --auto to push" >&2
  fi
}

repo_push() {
  [[ -e "$REPO_DIR/.git" ]] || { echo "no repo — clone first" >&2; return 1; }
  local remote branch ahead err
  remote=$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)
  if [[ -z "$remote" ]]; then
    echo "nothing to push — there is no remote yet: run 'omarchy-replicant create --push'" >&2
    return 0
  fi
  branch=$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)
  if ! git -C "$REPO_DIR" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
    echo "→ First push of $branch to $remote" >&2
    if err=$(git -C "$REPO_DIR" push -u origin "$branch" 2>&1); then
      echo "pushed" >&2
      return 0
    fi
  else
    ahead=$(git -C "$REPO_DIR" log --oneline '@{u}..HEAD' 2>/dev/null | wc -l)
    if (( ahead == 0 )); then
      echo "nothing to push" >&2
      [[ -n $(git -C "$REPO_DIR" status --porcelain 2>/dev/null) ]] &&
        echo "  there are uncommitted changes — 'save --auto' commits and pushes them" >&2
      return 0
    fi
    echo "→ Pushing $(plural "$ahead" commit) to $remote" >&2
    if git -C "$REPO_DIR" push origin HEAD 2>&1; then
      echo "pushed" >&2
      return 0
    else
      err="push failed"
    fi
  fi
  echo "Saved locally, but the push to GitHub failed:" >&2
  printf '%s\n' "$err" | sed 's/^/    /' >&2
  echo "Another machine may have saved first. Run 'omarchy-replicant pull', then push again." >&2
  return 1
}

repo_pull() {
  [[ -e "$REPO_DIR/.git" ]] || { echo "no repo — clone first" >&2; return 1; }
  local dirt before branch after moved n
  dirt=$(git -C "$REPO_DIR" status --porcelain 2>/dev/null || true)
  if [[ -n "$dirt" ]]; then
    echo "pull: the repo has uncommitted changes — pull needs a clean worktree:" >&2
    printf '%s\n' "$dirt" | head -n 20 | sed 's/^/    /' >&2
    echo "Review them with 'changes' or 'git -C $REPO_DIR diff'." >&2
    echo "Save them with 'save --all -m \"why\"', or discard the worktree changes, then pull again." >&2
    return 1
  fi
  git -C "$REPO_DIR" fetch --all --prune >/dev/null 2>&1 ||
    echo "could not reach the remote — using what is already here" >&2
  before=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)
  branch=$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)
  if ! git -C "$REPO_DIR" pull --rebase --quiet origin "$branch" 2>&1; then
    git -C "$REPO_DIR" rebase --abort >/dev/null 2>&1 || true
    echo "pull failed — nothing was changed; look at $REPO_DIR" >&2
    return 1
  fi
  after=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)
  if [[ -z "$before" || "$before" == "$after" ]]; then
    echo "already up to date" >&2
    return 0
  fi
  moved=$(bash "$REAL_CORE" incoming "$before" "$after" 2>/dev/null)
  rm -f -- "$REPLICANT_HOME/cache/state-v2.json" 2>/dev/null || true
  if [[ -z "$moved" ]]; then
    echo "pulled — nothing of yours changed" >&2
    return 0
  fi
  n=$(printf '%s\n' "$moved" | grep -c .)
  echo "pulled — $(plural "$n" file) changed on another machine" >&2
  printf '%s\n' "$moved" | sed 's/^/  /' >&2
  echo "  'restore --apply' brings them onto this machine; until then they show as ↓ to restore" >&2
}

# repo_clone <git-url>: clone into a temp dir beside the final path (same
# filesystem, so the rename is atomic), validate the staged clone, and move
# it into place. A v1 or v2 clone is activated as a migration-only source:
# it stays readable, and every writer refuses it until migrate-v3 runs. Any
# failure removes the staging dir: a failed clone leaves no partial repo.
repo_clone() {
  local url="$1" parent stage
  [[ -n "$url" ]] || { echo "usage: clone <git-url>" >&2; return 2; }
  if command -v omarchy-git-url-check >/dev/null 2>&1; then
    omarchy-git-url-check "$url" || { echo "refusing to clone '$url': it does not name a repository" >&2; return 1; }
  fi
  repo_exists && { echo "$REPO_DIR already exists — pull or remove it" >&2; return 1; }
  parent="$(dirname -- "$REPO_DIR")"
  mkdir -p -- "$parent" || return 1
  stage="$(mktemp -d "$parent/.replicant-clone-XXXXXX")" || return 1
  if ! _repo_clone_build "$url" "$stage"; then
    rm -rf -- "$stage"
    return 1
  fi
  if ! bootstrap_fail_at activate; then
    rm -rf -- "$stage"
    return 1
  fi
  if ! mv -- "$stage" "$REPO_DIR"; then
    rm -rf -- "$stage"
    printf 'clone: could not activate the staged clone at %s — nothing was changed\n' "$REPO_DIR" >&2
    return 1
  fi
  git -C "$REPO_DIR" config core.hooksPath .githooks 2>/dev/null || true
  rm -f -- "$REPLICANT_HOME/cache/state-v2.json" 2>/dev/null || true
  echo "cloned into $REPO_DIR — run omarchy-replicant restore --dry-run" >&2
}

# _repo_clone_build <url> <stage>: clone and validate inside the staging dir.
# Writes nothing outside the stage. Prints the exact recovery command after
# every remote failure.
_repo_clone_build() {
  local url="$1" stage="$2" v branches
  if ! bootstrap_fail_at validate; then
    return 1
  fi
  git clone -- "$url" "$stage" 2>&1 || {
    echo "clone failed — the temporary clone was removed; check access, then retry:" >&2
    echo "  gh auth login" >&2
    printf '  omarchy-replicant clone %s\n' "$url" >&2
    return 1
  }
  if ! git -C "$stage" rev-parse HEAD >/dev/null 2>&1; then
    echo "the clone worked but checked out nothing — the remote's default branch has no commits." >&2
    branches=$(git -C "$stage" branch -r --format='%(refname:short)' 2>/dev/null | sed 's|^origin/||' | grep -v '^HEAD' | paste -sd' ' -)
    [[ -n "$branches" ]] && echo "branches that do have them: $branches" >&2
    echo "nothing to restore from yet — the temporary clone was removed" >&2
    return 1
  fi
  v=$(REPO_DIR="$stage" repo_data_version)
  case "$v" in
    1|2)
      printf 'cloned a version %s repository — it is migration-only here (read-only); migrate it to version 3 with migrate-v3, then retry\n' "$v" >&2
      return 0 ;;
    3)
      ( REPO_DIR="$stage" _schema_marker_valid ) || {
        printf 'clone: the staged schema marker is invalid — the temporary clone was removed; verify the remote, then retry omarchy-replicant clone %s\n' "$url" >&2
        return 1
      }
      ( REPO_DIR="$stage" v3_no_legacy_files ) || return 1
      validate_v3_entries "$stage/.replicant/entries.json" || {
        printf 'clone: the staged entries are invalid — the temporary clone was removed; verify the remote, then retry omarchy-replicant clone %s\n' "$url" >&2
        return 1
      }
      return 0 ;;
    *)
      printf 'clone: the remote uses data format %s, this client writes up to %s — update the plugin, then retry omarchy-replicant clone %s\n' "$v" "$SCHEMA_VERSION" "$url" >&2
      return 1 ;;
  esac
}
