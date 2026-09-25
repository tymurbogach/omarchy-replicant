#!/bin/bash
# G8 release review: architecture boundaries and v3 documentation.
# Static checks over the source tree: the CLI owns no git plumbing, the
# transaction module owns mutations, legacy parsing lives in migration code,
# obsolete v2 write helpers are gone, duplicated resolution paths are unified,
# and the docs describe the v3 repository accurately.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/.." && pwd)"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

section "the CLI owns no git plumbing"
check_false "no direct git invocation in bin/omarchy-replicant" \
  bash -c 'grep -n "git -C" "$1" | grep -v "^.*#" | grep -q .' _ "$ROOT/bin/omarchy-replicant"
check_false "no local git_repo helper in the CLI" \
  bash -c 'grep -q "^git_repo()" "$1"' _ "$ROOT/bin/omarchy-replicant"
check_false "no local cache invalidation duplicate in the CLI" \
  bash -c 'grep -q "invalidate_brief_cache()" "$1"' _ "$ROOT/bin/omarchy-replicant"
check_true "the CLI invalidates through the core engine" \
  bash -c 'grep -q "briefcache_invalidate\|cache-invalidate" "$1"' _ "$ROOT/bin/omarchy-replicant"

section "git mutations live in the transaction module"
for fn in tx_shape_begin tx_shape_commit tx_shape_finish core_shape_transact \
  tx_begin tx_activate tx_mark_committed tx_shape_policy_paths; do
  check_true "transaction.sh defines $fn" \
    bash -c 'grep -q "^$2()" "$1"' _ "$ROOT/bin/lib/transaction.sh" "$fn"
done
check_true "save runs through the transaction journal" \
  bash -c 'grep -q "tx_meta_write\|tx_mark_committed" "$1"' _ "$ROOT/bin/lib/save.sh"
check_true "bulk runs through the transaction journal" \
  bash -c 'grep -q "tx_begin" "$1"' _ "$ROOT/bin/lib/bulk.sh"
check_true "profile changes use the shared shape transaction" \
  bash -c 'grep -q "core_shape_transact" "$1"' _ "$ROOT/bin/lib/scopes.sh"

section "legacy parsing lives in migration code"
for fn in migrate_legacy_profile_for_machine migrate_legacy_read_profile_map \
  migrate_legacy_user_entries migrate_legacy_personal_present \
  migrate_legacy_exclude_map migrate_legacy_migrate_exclude; do
  check_true "migrate.sh owns $fn" \
    bash -c 'grep -q "^$2()" "$1"' _ "$ROOT/bin/lib/migrate.sh" "$fn"
done
check_false "scopes.sh calls no legacy reader directly" \
  bash -c 'grep -nE "(^|[^_a-zA-Z])(legacy_read_profile_map|legacy_profile_for_machine|legacy_user_entries|legacy_personal_present|legacy_exclude_map|legacy_migrate_exclude)" "$1" | grep -vE "^[0-9]+:[[:space:]]*#" | grep -q .' _ "$ROOT/bin/lib/scopes.sh"
check_false "manifest.sh calls no legacy reader directly" \
  bash -c 'grep -nE "(^|[^_a-zA-Z])(legacy_read_profile_map|legacy_profile_for_machine|legacy_user_entries|legacy_personal_present|legacy_exclude_map|legacy_migrate_exclude)" "$1" | grep -vE "^[0-9]+:[[:space:]]*#" | grep -q .' _ "$ROOT/bin/lib/manifest.sh"
check_false "track.sh calls no legacy reader directly" \
  bash -c 'grep -nE "(^|[^_a-zA-Z])(legacy_read_profile_map|legacy_profile_for_machine|legacy_user_entries|legacy_personal_present|legacy_exclude_map|legacy_migrate_exclude)" "$1" | grep -vE "^[0-9]+:[[:space:]]*#" | grep -q .' _ "$ROOT/bin/lib/track.sh"

section "obsolete v2 write helpers are gone"
check_false "no v2 skeleton writer in bin/" \
  bash -c 'grep -rn "ensure_v2_layout" "$1/bin" | grep -q .' _ "$ROOT"
check_false "no v2 skeleton writer in tests/" \
  bash -c 'grep -rn "ensure_v2_layout" "$1/tests" --exclude=test-g8.sh | grep -q .' _ "$ROOT"

section "no duplicate resolution paths"
check_true "scope_for answers from the shared scope cache on v3" \
  bash -c 'sed -n "/^scope_for/,/^}/p" "$1" | grep -q "SCOPE_OF"' _ "$ROOT/bin/lib/scopes.sh"
check_true "scope shape paths use the shared policy stores" \
  bash -c 'grep -q "tx_shape_policy_paths" "$1"' _ "$ROOT/bin/lib/scopes.sh"
check_true "track uses the shared policy stores" \
  bash -c 'grep -q "tx_shape_policy_paths" "$1"' _ "$ROOT/bin/lib/track.sh"
check_true "recover uses the shared policy stores" \
  bash -c 'grep -q "tx_shape_policy_paths" "$1"' _ "$ROOT/bin/lib/history.sh"

section "the v3 schema is documented"
check_true "SPEC names the v3 schema record" \
  bash -c 'grep -q "dataVersion[^\n]*3" "$1" && grep -q "age-pq-v2" "$1"' _ "$ROOT/docs/SPEC.md"
check_true "SPEC names entries.json as the policy store" \
  bash -c 'grep -q "\.replicant/entries\.json" "$1"' _ "$ROOT/docs/SPEC.md"
check_true "SPEC publishes schema version 3" \
  bash -c 'grep -q "schema_version.*3" "$1"' _ "$ROOT/docs/SPEC.md"
check_true "SPEC documents migrate-v3" \
  bash -c 'grep -q "migrate-v3" "$1"' _ "$ROOT/docs/SPEC.md"
check_true "SPEC documents transaction recovery" \
  bash -c 'grep -q "tx resume\|tx-resume\|resume" "$1"' _ "$ROOT/docs/SPEC.md"
check_true "SPEC documents every key workflow" \
  bash -c 'for k in "key init" "key export" "key import" "key status" "key rotate"; do grep -q "$k" "$1" || exit 1; done' _ "$ROOT/docs/SPEC.md"
check_true "SPEC states secrets use age encryption" \
  bash -c 'grep -qi "age encryption\|encrypted.*age\|age.*encrypt" "$1"' _ "$ROOT/docs/SPEC.md"
check_true "SPEC states the identity never enters the repo" \
  bash -c 'grep -q "never.*identity\|identity.*never" "$1"' _ "$ROOT/docs/SPEC.md"
check_true "SPEC documents public-repository refusal" \
  bash -c 'grep -qi "public.*refus\|refus.*public\|never.*public" "$1"' _ "$ROOT/docs/SPEC.md"
check_true "SPEC documents migration acknowledgement" \
  bash -c 'grep -qi "acknowledg\|upgraded or offline\|every.*machine" "$1"' _ "$ROOT/docs/SPEC.md"

section "examples and guides use migrate-v3"
check_true "README migrates with migrate-v3" \
  bash -c 'grep -q "migrate-v3" "$1"' _ "$ROOT/README.md"
check_false "README shows no migrate-v2 command" \
  bash -c 'grep -q "migrate-v2 --remote\|migrate-v2 --github" "$1"' _ "$ROOT/README.md"
check_true "getting-started migrates with migrate-v3" \
  bash -c 'grep -q "migrate-v3" "$1"' _ "$ROOT/docs/getting-started.md"
check_true "getting-started names the v3 policy store" \
  bash -c 'grep -q "entries\.json" "$1"' _ "$ROOT/docs/getting-started.md"
check_true "the journal records transaction recovery" \
  bash -c 'grep -qi "transaction recovery\|tx resume\|recovery.*transaction" "$1"' _ "$ROOT/docs/journal.md"

section "the release version is set"
check "plugin manifest is 0.13.0" "0.13.0" \
  "$(jq -r .version "$ROOT/manifest.json" 2>/dev/null)"

summary
