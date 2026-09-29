#!/bin/bash
# G8 release review: architecture boundaries and single-format documentation.
# Static checks over the source tree: the CLI owns no git plumbing, the
# transaction module owns mutations, no retired format is named anywhere, and
# the docs describe the one repository format accurately.
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

section "no retired format remains"
check_false "no migration module in bin/" \
  bash -c 'ls "$1"/bin/lib/migrate.sh "$1"/bin/lib/legacy.sh 2>/dev/null | grep -q .' _ "$ROOT"
check_false "bin/ names no retired store" \
  bash -c 'grep -rnE "replicant-track|replicant-sync|replicant-profiles|savegame|migrate|legacy|dataVersion|secretFormat|LEGACY_|REMOVED_" "$1/bin" | grep -q .' _ "$ROOT"
check_false "no retired store in the policy paths" \
  bash -c 'grep -q "replicant-track" "$1"' _ "$ROOT/bin/lib/transaction.sh"

section "no duplicate resolution paths"
check_true "scope_for answers from the shared scope cache" \
  bash -c 'sed -n "/^scope_for/,/^}/p" "$1" | grep -q "SCOPE_OF"' _ "$ROOT/bin/lib/scopes.sh"
check_true "scope shape paths use the shared policy stores" \
  bash -c 'grep -q "tx_shape_policy_paths" "$1"' _ "$ROOT/bin/lib/scopes.sh"
check_true "track uses the shared policy stores" \
  bash -c 'grep -q "tx_shape_policy_paths" "$1"' _ "$ROOT/bin/lib/track.sh"
check_true "recover uses the shared policy stores" \
  bash -c 'grep -q "tx_shape_policy_paths" "$1"' _ "$ROOT/bin/lib/history.sh"

section "the single format is documented"
check_true "SPEC names the exact marker" \
  bash -c 'grep -q "{\"format\":\"replicant\"}" "$1"' _ "$ROOT/docs/SPEC.md"
check_true "SPEC names entries.json as the policy store" \
  bash -c 'grep -q "\.replicant/entries\.json" "$1"' _ "$ROOT/docs/SPEC.md"
check_false "SPEC names no version number" \
  bash -c 'grep -qiE "dataVersion|secretFormat|schema_version|version 3|\bv3\b|migrate" "$1"' _ "$ROOT/docs/SPEC.md"
check_true "SPEC states secrets are encrypted" \
  bash -c 'grep -qi "encrypt" "$1"' _ "$ROOT/docs/SPEC.md"

section "examples stay free of retired commands"
check_false "getting-started names no retired command" \
  bash -c 'grep -qE "migrate|savegame|replicant-track" "$1"' _ "$ROOT/docs/getting-started.md"

section "the release version is set"
check "plugin manifest carries a release version" "1" \
  "$(jq -r .version "$ROOT/manifest.json" 2>/dev/null | grep -cE '^[0-9]+\.[0-9]+\.[0-9]+$' || true)"

summary
