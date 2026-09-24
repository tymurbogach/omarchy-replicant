#!/bin/bash
# G2: fresh initialization and private repository safety. Every case runs
# against a fake $HOME and a throwaway $OMARCHY_REPLICANT_HOME, with a stubbed
# gh that never reaches the network. A failed bootstrap must leave no partial
# repository and no staging directory behind.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CORE="$HERE/../bin/replicant-core.sh"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export OMARCHY_REPLICANT_HOME="$TMP/replicant"
mkdir -p "$HOME"

# shellcheck source=/dev/null
source "$CORE" 2>/dev/null
set +e +u

# make_gh <dir> <mode>: a stub gh that answers user lookup, repo view and repo
# create from files, never from the network. Mode selects the remote state:
#   missing  — repo view fails, create succeeds as private
#   private  — repo view succeeds with PRIVATE visibility
#   public   — repo view succeeds with PUBLIC visibility
#   createfail — repo view fails and create fails
make_gh() {
  local dir="$1" mode="$2"
  mkdir -p "$dir"
  cat > "$dir/gh" <<EOF
#!/bin/sh
echo "gh \$*" >> "$STUB_LOG"
created="$dir/created"
case "\$*" in
  *".login"*) echo "testuser"; exit 0 ;;
  *"repo view"*"visibility"*)
    case "$mode" in
      private) echo "PRIVATE"; exit 0 ;;
      public) echo "PUBLIC"; exit 0 ;;
      *) [ -f "\$created" ] && { echo "PRIVATE"; exit 0; }; exit 1 ;;
    esac ;;
  *"repo view"*)
    case "$mode" in
      private|public) exit 0 ;;
      *) [ -f "\$created" ] && exit 0; exit 1 ;;
    esac ;;
  *"repo create"*)
    case "$mode" in
      createfail) echo "stub: gh create failed" >&2; exit 1 ;;
      *) touch "\$created"; exit 0 ;;
    esac ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$dir/gh"
}

no_staging_left() {
  # No init/clone staging directory may survive next to the repo or state dir.
  local left
  left=$(find "$OMARCHY_REPLICANT_HOME" "$(dirname -- "$REPO_DIR")" -maxdepth 1 \
    \( -name '.replicant-init-*' -o -name '.replicant-clone-*' \) 2>/dev/null || true)
  [[ -z "$left" ]]
}

section "missing and v1 repositories are distinguished"
check "a directory without git is missing" "missing" "$(repo_state)"
git init -q -b main "$REPO_DIR" 2>/dev/null
check "a git repo without a schema marker is v1" "v1" "$(repo_state)"
check "…and its data version still reads 1" "1" "$(repo_data_version)"
rm -rf -- "$REPO_DIR"

section "init without existing state builds v3 atomically"
export OMARCHY_REPLICANT_HOME="$TMP/replicant"
# shellcheck source=/dev/null
source "$CORE" 2>/dev/null
set +e +u
check_true "init succeeds on a missing repo" core_init
check "the schema marker says version 3" "3" \
  "$(jq -r .dataVersion "$REPO_DIR/.replicant/schema.json" 2>/dev/null)"
check "…and names the v2 secret format" "age-pq-v2" \
  "$(jq -r .secretFormat "$REPO_DIR/.replicant/schema.json" 2>/dev/null)"
check_false "no legacy track file in a fresh repo" test -f "$REPO_DIR/.replicant-track"
check_false "no legacy sync file in a fresh repo" test -f "$REPO_DIR/.replicant-sync"
check_false "no legacy profiles file in a fresh repo" test -f "$REPO_DIR/.replicant-profiles"
check_true "…with one initial commit" git -C "$REPO_DIR" rev-parse HEAD
check_true "…and no staging directory left behind" no_staging_left

section "failed initialization leaves no partial repository"
rm -rf -- "$REPO_DIR"
out=$(REPLICANT_FAIL_BOOTSTRAP_AT=validate core_init 2>&1); rc=$?
check "injected failure before validation fails" "1" "$(if (( rc != 0 )); then echo 1; else echo 0; fi)"
check_contains "…naming the stage" "validate" "$out"
check_false "…leaving no repo directory" test -e "$REPO_DIR"
check_true "…and no staging directory" no_staging_left
out=$(REPLICANT_FAIL_BOOTSTRAP_AT=activate core_init 2>&1); rc=$?
check "injected failure before activation fails" "1" "$(if (( rc != 0 )); then echo 1; else echo 0; fi)"
check_false "…leaving no repo directory" test -e "$REPO_DIR"
check_true "…and no staging directory" no_staging_left

section "create without existing state stays private"
rm -rf -- "$REPO_DIR"
make_gh "$TMP/gh-missing" missing
out=$(PATH="$TMP/gh-missing:$PATH" repo_create "testrepo" 0 https 2>&1); rc=$?
check "create succeeds against a missing remote" "0" "$rc"
check "the created repo is v3" "3" \
  "$(jq -r .dataVersion "$REPO_DIR/.replicant/schema.json" 2>/dev/null)"
check "…pointing at the private https remote" \
  "https://github.com/testuser/testrepo.git" \
  "$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null)"
check_contains "…saying it is private" "private" "$out"
check_true "…and no staging directory left behind" no_staging_left

section "create against an existing private remote reuses it"
make_gh "$TMP/gh-private" private
out=$(PATH="$TMP/gh-private:$PATH" repo_create "testrepo" 0 https 2>&1); rc=$?
check "create succeeds against a private remote" "0" "$rc"
check "…keeping the same origin" \
  "https://github.com/testuser/testrepo.git" \
  "$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null)"
check_true "…and no staging directory left behind" no_staging_left

section "create rejects an existing public remote before mutation"
make_gh "$TMP/gh-public" public
remote_before=$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)
head_before=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)
tree_before=$(hash_tree "$REPO_DIR")
out=$(PATH="$TMP/gh-public:$PATH" repo_create "testrepo" 0 https 2>&1); rc=$?
check "create fails against a public remote" "1" "$(if (( rc != 0 )); then echo 1; else echo 0; fi)"
check_contains "…naming the public repo" "PUBLIC" "$out"
check_contains "…never changing visibility automatically" "private" "$out"
check "…leaving the remote untouched" "$remote_before" \
  "$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)"
check "…leaving HEAD untouched" "$head_before" \
  "$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)"
check "…leaving the tree untouched" "$tree_before" "$(hash_tree "$REPO_DIR")"
if grep -q "push" "$STUB_LOG" 2>/dev/null; then
  t_bad "…performing no push (a push was logged)"
else
  t_ok "…performing no push"
fi
check_false "…never calling repo edit for visibility" \
  grep -q "repo edit" "$STUB_LOG"

section "create reports recovery commands after remote failures"
rm -rf -- "$REPO_DIR"
make_gh "$TMP/gh-createfail" createfail
out=$(PATH="$TMP/gh-createfail:$PATH" repo_create "testrepo" 0 https 2>&1); rc=$?
check "a failed gh create fails" "1" "$(if (( rc != 0 )); then echo 1; else echo 0; fi)"
check_contains "…with a recovery command" "gh auth login" "$out"
check_false "…leaving no repo directory" test -e "$REPO_DIR"
check_true "…and no staging directory" no_staging_left

section "a held first push keeps the local commit"
make_gh "$TMP/gh-push" missing
rm -rf -- "$REPO_DIR"
out=$(PATH="$TMP/gh-push:$PATH" REPLICANT_FAIL_BOOTSTRAP_AT=push repo_create "pushrepo" 1 https 2>&1); rc=$?
check "an injected failure before the first push fails" "1" "$(if (( rc != 0 )); then echo 1; else echo 0; fi)"
check_contains "…keeping the retry command" "push" "$out"
check_true "…keeping the local commit" git -C "$REPO_DIR" rev-parse HEAD
check_true "…and no staging directory left behind" no_staging_left

section "clone activates a v3 repository atomically"
v3src="$TMP/v3src"
git init -q -b main "$v3src" 2>/dev/null
git -C "$v3src" config user.name Tests 2>/dev/null
git -C "$v3src" config user.email tests@example.com 2>/dev/null
mkdir -p "$v3src/.replicant/machines" "$v3src/vault/blobs"
jq -nc '{dataVersion: 3, secretFormat: "age-pq-v2"}' > "$v3src/.replicant/schema.json"
printf '{}\n' > "$v3src/.replicant/entries.json"
git -C "$v3src" add -A 2>/dev/null
git -C "$v3src" commit -qm v3 2>/dev/null
rm -rf -- "$REPO_DIR"
out=$(repo_clone "$v3src" 2>&1); rc=$?
check "clone of a v3 repo succeeds" "0" "$(if (( rc != 0 )); then echo 1; else echo 0; fi)"
check "…activating it as v3" "v3" "$(repo_state)"
check "…with the schema marker intact" "3" \
  "$(jq -r .dataVersion "$REPO_DIR/.replicant/schema.json" 2>/dev/null)"
check "…with the same head" \
  "$(git -C "$v3src" rev-parse HEAD 2>/dev/null)" \
  "$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null)"
check_true "…and no staging directory left behind" no_staging_left

section "clone identifies legacy repositories as migration-only"
legacy_src="$TMP/legacy-src"
git init -q -b main "$legacy_src" 2>/dev/null
git -C "$legacy_src" config user.name Tests 2>/dev/null
git -C "$legacy_src" config user.email tests@example.com 2>/dev/null
printf 'legacy\n' > "$legacy_src/file.txt"
git -C "$legacy_src" add -A 2>/dev/null
git -C "$legacy_src" commit -qm legacy 2>/dev/null
rm -rf -- "$REPO_DIR"
out=$(repo_clone "$legacy_src" 2>&1); rc=$?
check "clone of a v1 repo succeeds" "0" "$rc"
check_contains "…calling it migration-only" "migrat" "$out"
check "…marking it read-only" "v1" "$(repo_state)"
check_false "…with no legacy writes allowed" \
  env -u REPLICANT_TEST_ALLOW_LEGACY_WRITES bash -c 'source "$0" 2>/dev/null; core_backup' "$CORE"

section "failed clone leaves no partial repository"
rm -rf -- "$REPO_DIR"
out=$(REPLICANT_FAIL_BOOTSTRAP_AT=validate repo_clone "$legacy_src" 2>&1); rc=$?
check "injected failure before clone validation fails" "1" "$(if (( rc != 0 )); then echo 1; else echo 0; fi)"
check_false "…leaving no repo directory" test -e "$REPO_DIR"
check_true "…and no staging directory" no_staging_left
rm -rf -- "$REPO_DIR"
out=$(repo_clone "/nonexistent/remote-$RANDOM.git" 2>&1); rc=$?
check "clone of an unreachable remote fails" "1" "$(if (( rc != 0 )); then echo 1; else echo 0; fi)"
check_contains "…with a recovery command" "clone" "$out"
check_false "…leaving no repo directory" test -e "$REPO_DIR"
check_true "…and no staging directory" no_staging_left

summary
