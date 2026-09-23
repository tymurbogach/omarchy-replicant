# shellcheck shell=bash
# repo.sh: Git repository lifecycle and remote transport.
# Sourced by replicant-core.sh. Functions return status and write diagnostics;
# the CLI owns command parsing, confirmation, and presentation.

repo_create() {
  local name="$1" do_push="${2:-0}" gh_user current_url url vis resp
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "invalid name: $name" >&2; return 1; }
  if [[ ! -d "$REPO_DIR/.git" ]]; then core_init; else core_backup; fi
  gh_user=$(gh api user --jq .login 2>/dev/null || gh auth status 2>&1 | grep -oP 'account \K\w+' | head -n1)
  [[ -n "$gh_user" ]] || { echo "no gh user" >&2; return 1; }
  echo "creating github.com/$gh_user/$name --private ..." >&2
  if gh repo view "$gh_user/$name" >/dev/null 2>&1; then
    vis=$(gh repo view "$gh_user/$name" --json visibility --jq .visibility 2>/dev/null || echo "")
    [[ "$vis" != PUBLIC ]] || echo "repo already exists and is PUBLIC; switch it to private" >&2
  else
    gh repo create "$name" --private --description "Omarchy replicant private savegame" >/dev/null 2>&1 || {
      echo "gh create failed" >&2; return 1;
    }
  fi
  url="https://github.com/$gh_user/$name.git"
  current_url=$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)
  if [[ -n "$current_url" && "$current_url" != "$url" ]]; then
    echo "repository already points at $current_url" >&2
    read -rp "Re-point it to $url? [y/N] " resp </dev/tty 2>&1 || resp=""
    [[ "$resp" == [yY] ]] || { echo "create cancelled" >&2; return 1; }
    git -C "$REPO_DIR" remote set-url origin "$url"
  elif [[ -z "$current_url" ]]; then
    git -C "$REPO_DIR" remote add origin "$url"
  fi
  git -C "$REPO_DIR" branch -M main 2>/dev/null || true
  git -C "$REPO_DIR" add -A
  if ! git -C "$REPO_DIR" diff --cached --quiet; then
    git -C "$REPO_DIR" commit -m "replicant: create $name $(date -Is)" || return 1
  fi
  if (( do_push )); then
    git -C "$REPO_DIR" push -u origin main 2>&1 || git -C "$REPO_DIR" push -u origin HEAD 2>&1 || return 1
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

repo_clone() {
  local url="$1"
  [[ -n "$url" ]] || { echo "usage: clone <git-url>" >&2; return 2; }
  if command -v omarchy-git-url-check >/dev/null 2>&1; then
    omarchy-git-url-check "$url" || { echo "refusing to clone '$url': it does not name a repository" >&2; return 1; }
  fi
  [[ -e "$REPO_DIR/.git" ]] && { echo "$REPO_DIR already exists — pull or remove it" >&2; return 1; }
  mkdir -p "$(dirname "$REPO_DIR")"
  git clone -- "$url" "$REPO_DIR" 2>&1 || { echo "clone failed (private repo without gh auth?)" >&2; return 1; }
  git -C "$REPO_DIR" config core.hooksPath .githooks 2>/dev/null || true
  if ! git -C "$REPO_DIR" rev-parse HEAD >/dev/null 2>&1; then
    echo "the clone worked but checked out nothing — the remote's default branch has no commits." >&2
    local branches
    branches=$(git -C "$REPO_DIR" branch -r --format='%(refname:short)' 2>/dev/null | sed 's|^origin/||' | grep -v '^HEAD' | paste -sd' ' -)
    [[ -n "$branches" ]] && echo "branches that do have them: $branches" >&2
    echo "nothing to restore from yet" >&2
    return 1
  fi
  rm -f -- "$REPLICANT_HOME/cache/state-v2.json" 2>/dev/null || true
  echo "cloned into $REPO_DIR — run omarchy-replicant restore --dry-run" >&2
}
