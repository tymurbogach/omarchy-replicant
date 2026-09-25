# Development journal

This file records the original baseline totals and architecture only.
It holds no repository paths, secret names, or credentials.

## Baseline run (before section 1 changes)

Commit `dd7b905`. Command `./tests/run-all.sh` passed in 48 s.

| Suite | Checks |
| --- | --- |
| test-core.sh | 479 passed |
| test-settings.sh | 177 passed |
| test-cli.sh | 292 passed |
| test-journey.sh | 73 passed |
| test-usability.sh | 55 passed |
| panel logic (qmltestrunner) | 25 passed, 0 failed |

Static sections all passed: shell syntax, shellcheck, QML syntax,
QML traps, no em dashes, no personal data, own secret scanner, manifest.

## Architecture as found

The CLI (`bin/omarchy-replicant`) parses arguments, confirms, and prints.
The core (`bin/replicant-core.sh`) sources the modules in `bin/lib/` and
runs the command. Content comparison lives in `entry_differs`
(`bin/lib/incoming.sh`): files compare with `cmp`, trees with `tree_same`.
The row badge order is off, missing, incoming, unsaved, default, unpushed,
saved. Incoming outranks unsaved, so a pull marks rows for Restore, never
for Save. `backup` copies files only. `savegame` copies, commits, and
pushes, and it holds incoming entries back.

The bar polls `status --json --brief` once a minute and reads the counters
`unsaved` and `incoming` from `count_changes`. The full payload builds the
rows the panel draws.

## Section 1 changes

QML runner environment (`tests/run-all.sh`): unset
`QT_QPA_PLATFORMTHEME` and set `QT_QPA_PLATFORM=offscreen` for the runner
call. Result stays at 25 passed, 0 failed.

Characterization tests added (all pass):

- An incoming file stays incoming when this machine edits it too
  (`tests/test-core.sh`).
- A restore keeps what it overwrote as a `.bak.<epoch>` backup
  (`tests/test-core.sh`).
- Older client behavior, file and tree self-healing, and incoming priority
  across machines were already covered and remain green.

Regression tests added (both fail as intended):

- `tests/test-core.sh`: a saved file deleted locally reads `missing` in the
  full payload, but the brief payload carries no `missing` count
  (expected `1`, got `null`). Cause: `entry_differs` reports no difference
  for a missing source, so `count_changes` skips it and the brief payload
  has no field for it.
- `tests/test-usability.sh`: `BarWidget.qml` names no missing state, so the
  bar keeps the hexagon icon and the tooltip says "in sync" over a deleted
  file. Section 4 (state evaluator) fixes both.

## Section 2 run (v2 schema)

New suite `tests/test-schema.sh`: 50 checks, all pass. Full
`./tests/run-all.sh`: settings 177, cli 292, journey 73 and QML 25 stay
green. The only failures are the two section 1 tripwires above (core
483/484, usability 55/56). All 38 mutations caught (`tests/mutate.sh`),
including 6 new ones for the schema guards.

What changed:

- New `bin/lib/schema.sh`: `repo_data_version` (missing file reads as 1,
  unreadable as unknown), `require_writable_schema` (1 and 2 may write,
  newer or unknown fail with the next step), `validate_v2_entries` plus
  `load_v2_entries` (structural jq rules plus duplicate IDs, path
  collisions, nested roots, repo paths, sockets and devices), and
  `machine_metadata_write` (machine ID, profile, client version, schema
  version, nothing else).
- A fresh repo is born v2: `ensure_v2_layout` writes `schema.json`
  (`dataVersion: 2`, `secretFormat: "age-pq-v1"`), empty `entries.json`,
  and `machines/<id>.json`. Repos with history keep what they have; a v2
  clone refreshes only its own machine file. `.replicant-version` is still
  recorded, so older clients will not prune a v2 repo.
- Every core writer starts with the gate: backup, track, untrack, forget,
  scope, sync (through scope), profile-set, recover (after its dry-run
  check), setting writes, reverts, restores, and undo. `savegame` checks
  the new `schema-gate` command before it commits. Reads, pull, dry runs,
  create, clone, init, reset, and purge stay ungated by design (each named
  in the module header).
- Entry `kind` allows `config` and `dir` (PLAN shows `config`; directories
  need a kind to round-trip, with dir paths ending in `/`). `recipient.txt`
  and `vault/` arrive with section 3.

Section 3 preflight: `age` 1.3.2 installed through mise (no root needed)
and `age-keygen -pq` generates a post-quantum hybrid key on this machine.
No key material lives in this repo; the probe key was a throwaway.

## Section 3 phase A run (keys and vault)

New suite `tests/test-crypto.sh`: 69 checks, all pass. Full
`./tests/run-all.sh`: settings 177, cli 292, journey 73, schema 50 and QML
26 stay green. The only failures are the two section 1 tripwires (core
485/486, usability 55/56). All 43 mutations caught (`tests/mutate.sh`),
including 5 new ones that each break one vault line and fail the suite.

What changed:

- New `bin/lib/crypto.sh`: `key init|export|import|status|rotate`, vault
  save/restore per secret, opaque 128-bit blob IDs from `/dev/urandom`,
  encrypted index with path, scope and blob ID. Plaintext lives only in
  temp files outside the repo, dropped explicitly on every return plus
  chained INT/TERM/HUP traps.
- `key init` refuses v1 repos and existing identities; `export` refuses
  repo/state-dir/relative destinations and verifies by recipient;
  `import` requires a parseable identity matching the repo recipient;
  `rotate` rebuilds in a temp dir and swaps only on full success, warning
  that old ciphertext stays readable with the old key.
- A v2 backup encrypts secrets and preserves ciphertext byte for byte; the
  first keyless save skips secrets loudly (otherwise init could never
  create the repo key init needs). With a vault present and no key, the
  save fails with the import remediation.
- A tampered blob never replaces live data on restore; status shows
  unsaved and the next save heals from live. Restores back up, rename
  atomically beside the destination (staged dir for paths outside `$HOME`,
  mirroring `ini_set` when root is unavailable).
- `locked` rows (no vars, no counts) with minimal QML render (`stateGlyph`,
  `stateWord`, `stateRole`, `needsAttention`; restore stays hidden since
  `wouldRestore` excludes it). Legend, README badges, the eight-states
  assertion and the QML states list updated. Brief `locked` count, var-name
  removal, `defined-secrets.txt` removal, doctor and full docs ride in
  phase B.
- `untrack`/`forget` drop vault blobs and index rows (CLI commits
  `vault/index.age` and `vault/blobs`); the pre-commit hook skips `*.age`;
  `savegame` keeps its fail-fast schema gate.

Two traps found by the tests, both fixed:

- `age -o` refuses an existing file, so every age output names a fresh
  path inside a `mktemp -d`, never a `mktemp` file.
- Command-substitution subshells run the inherited EXIT trap: chaining the
  caller's EXIT cleanup fired `rm -rf` of whole fixture trees mid-save.
  EXIT is never chained now; INT/TERM/HUP still chain for real signals.
- `core_untrack` checked `is_secret_rel` after removing the entry that
  made it true, so the vault branch never fired. It captures `was_secret`
  first now.
- Fresh repos are born v2, so v1-pinning suites (`test-core.sh`,
  `test-journey.sh`) pre-create their git dir before the first backup.
  v2 multi-machine flows stay in `test-crypto.sh` until migration.

## Section 3 phase B run (locked status, doctor, docs)

`tests/test-crypto.sh`: 89 checks (was 69), all pass. Full
`./tests/run-all.sh`: settings 177, cli 292, journey 73, schema 50
and QML 26 stay green. The only failures are the two section 1
tripwires (core 485/486, usability 55/56). All 47 mutations caught,
including 4 new ones for the phase B guards.

What changed:

- `build_secrets_json` reports no variable names on v2: `vars` is always
  empty, `var_count` keeps the count, and a locked row carries no count.
  The header comment says so.
- `defined-secrets.txt` is retired: the writer is gone, the file joins the
  retired sweep in `ensure` (one `rm`, so one mutation guards it), and SPEC
  no longer lists it as a rebuild source.
- `count_changes` prints `<unsaved> <incoming> <locked>`. On v2 it decrypts
  the index once: no key means every live secret counts as locked, with a
  key it compares each live file with `vault_blob_same`. The first field
  keeps its meaning, so the old two-field reader in `test-core.sh` still
  works. Brief and full status publish `locked`, and the text status names
  the `key import` remedy.
- `BarWidget.qml` reads `nLocked` with Locked first in glyph, tooltip and
  color, ahead of incoming. The brief merge needs no change: it copies every
  brief field over the known state.
- `doctor` gains Tools checks (`age`, post-quantum `age-keygen`) and a Keys
  section: exact `key status` wording plus one `run:` line from the new
  `key_remediation` (import when keyless or mismatched, init when the repo
  names no recipient, status when ready), plus a locked count warning. The
  `if key_out=$(...)` form matters: a plain assignment under `set -e` killed
  doctor on the keyless path before it printed anything.
- SPEC Secrets documents the vault layout, the key flows, `locked`,
  `count_changes` with three numbers, rotation that cannot revoke pushed
  ciphertext, and a clean repo after compromise. README Requirements lists
  `age` as the third tool.

One trap found by the tests, fixed: doctor died silently without the key
because `set -e` exits on a failing command substitution assignment.

## Section 4 phase A run (entry registry)

New suite `tests/test-state.sh`: 32 checks, all pass. Full
`./tests/run-all.sh`: core 485/486, settings 177, cli 292, journey 73,
schema 50, crypto 89 and QML 26 stay as before. The only failures are the
two section 1 tripwires, which phase 4B closes. All 49 mutations caught,
including 2 new ones for the registry guards.

What changed:

- New `bin/lib/registry.sh`, loaded last in `replicant-core.sh`:
  `registry_build` joins the shipped lists, the v2 entry records, the user
  and auto lists, and the decrypted vault index into `REGISTRY`, one
  tab-separated row per id (`id, kind, source, category, scope, live path,
  repository path, blob, locked`), sorted by id. A v2 record overrides the
  shipped row for its id; a user entry wins over an auto one; a missing
  record means the shipped default. An invalid `entries.json` fails loudly
  instead of resolving against the wrong paths. `registry_row_for` and
  `registry_field` read one row back.
- `REGISTRY` is declared `-g` at module top, so the global-leak test sees it
  before and after. Nothing consumes the registry yet: `TRACKED` stays
  authoritative until 4B migrates the consumers with parity tests.
- SPEC module table names `registry.sh`. The restore policy stays derived
  (secrets restore at 600 plus the category apply step), not a stored field.

## Section 4 phase B run (state evaluator and unification)

`tests/test-state.sh`: 62 checks (was 32), all pass. Full
`./tests/run-all.sh`: core 488/488, settings 177, cli 292, journey 73,
schema 50, crypto 89, usability 56/56, QML 26. Zero failures: both section
1 tripwires are closed. All 53 mutations caught, including 4 new ones.
Brief status takes about 0.44 s in a 10-row fixture world, against 0.43 s
before the change: within the 10 percent budget.

What changed:

- New `bin/lib/state.sh`, loaded last: `entry_differs` moved here from
  `incoming.sh`, plus `state_facts` (eight independent facts per registry
  row), `state_verdict` (one precedence) and `state_eval` (both in one
  pass, 17 tab fields). New `row_split` in `registry.sh`: tab is IFS
  whitespace, so `IFS=$'\t' read` collapses an empty middle field and a
  config row carries an empty blob. The parity suite caught it before any
  user did. `crypto_secret_same` is deleted; its one caller reads facts now.
- Consumers migrated one by one with byte parity against
  `tests/fixtures/state-parity/` (19 files, v1 and v2, keyed and keyless):
  `build_configs_json`, `build_secrets_json`, `count_changes`, `core_diff`,
  the backup copy loop and prune list, `plan_for_category`. Loops keep
  their order; only the answers come from the registry and the evaluator.
  `core_restore_file` stays as is: single-shot actions with no badge logic.
- `count_changes` prints four numbers now; brief and full publish `missing`
  and `needs_action` (any actionable count). The bar adds `nMissing` with
  Locked, Incoming, Missing, Unsaved, Ahead priority, alert glyph and amber.
  The core tripwire test uses a delta: earlier sections leave their own
  missing rows, so only the change the deletion causes is asserted.
- v2-only entry ids stay invisible to builders and counts until section 5
  wires entry management: showing a row the panel cannot act on would split
  the bar from the panel. Noted in code, not silently dropped.
- Bar verified on the real shell after reload (hard rule 4): qmlcache
  cleared, `omarchy restart shell`, new quickshell PID, zero QML errors in
  the journal, full-screen `grim` plus a bar crop showing the bar rendered
  with no half-render. The missing branch reuses the alert glyph and amber
  already live since phase B, so no new icon needed rendering proof; the
  live missing state itself was not staged, since that needs a real missing
  file in the data repo.

Traps found by the tests, all fixed:

- A locked secret with no live file resolved to locked and counted; it is
  missing instead (locked needs something to hold).
- `doctor` died silently without the key under `set -e` on a failing
  command-substitution assignment (phase B); same class, `if` form.
- The unit-test world needed one commit: uncommitted copies read dirty,
  which is correct and buried the healing assertions.

Incident during this phase: at 02:30 the whole tree was committed and
pushed to public main with the test identity (`0896e73 initial`), by a
process this session could not identify; every git write in the session's
scripts targets throwaway repos through `git -C`. With approval, main was
restored with `git reset --mixed dd7b905` plus `git push --force-with-lease`
(verified `dd7b905` on the remote), and all work continued uncommitted.
Lesson: no bare `git stash`, `commit` or `push` in the plugin checkout;
verify every `git -C` target before running suite-adjacent commands.

## Section 4 phase C run (brief-status cache)

`./tests/run-all.sh`: core 488, settings 177, cli 292, journey 73,
usability 56, schema 50, crypto 89, state 76/76 (was 62, plus 14 cache
checks), QML 26. Zero failures, 73 s. All 56 mutations caught, including
3 new ones for the cache guards.

What changed:

- New `bin/lib/briefcache.sh`, loaded last in `replicant-core.sh`:
  `briefcache_read` (hit prints the 5 cached numbers, any mismatch
  returns 1), `briefcache_write` (atomic snapshot through a temp file
  plus rename), `briefcache_invalidate` (one `rm -f`, never fails).
  Fingerprints per tracked entry are device plus inode, size, mtime,
  and for secrets the opaque blob ID plus the blob file's own stat.
  Directories store a hash of the file metadata listing, never
  contents. Scalars guarded alongside: repo HEAD, profile name,
  incoming-list hash, public key state. No secret values, no variable
  names, no plaintext hashes: the suite greps the cache for both.
- The cache holds counts only (`unsaved`, `incoming`, `locked`,
  `missing`, `needs_action`). Git fields (`dirty`, `ahead`, `behind`)
  still compute fresh on every brief poll, so push state never goes
  stale. Full status short-circuits before the cache read and stays
  authoritative: it compares bytes on every call.
- Invalidation is explicit at every writer: backup, incoming record,
  profile set, scope and sync, track, untrack, forget, single and bulk
  restore, undo, key init, import and rotate in the core, plus the
  CLI-side commits (`commit_repo_shape`), savegame, save-file, pull,
  clone and applied restore. The HEAD, profile, incoming and key
  guards catch anything a writer missed.
- Timestamp trap pinned by test: same size plus preserved mtime hits
  the brief cache (stale `0`) while full status and the direct count
  both report `1`. That is the documented price of a metadata cache.
  A corrupt cache falls back to full evaluation and heals itself.

Timing in a small fixture world: brief miss 618 ms, brief hit 288 ms,
full 1182 ms. The hit skips every `cmp` and every vault decrypt, so
the gap grows with the row count. Within the 10 percent budget: a
miss costs one extra metadata pass, a hit costs less than before.

Traps found by the tests, all fixed:

- The `needs_action` derivation was duplicated for the brief and full
  paths, which made the existing mutation stale (its text matched
  twice). Both paths share one derivation now.
- The timestamp-trap fixture first set the mtime to a stamp made
  after priming, which is a newer mtime and correctly misses. The
  trap needs the mtime from before the edit, restored with
  `touch -d @$oldmt`.
- Restoring the wrong content (`my own input` instead of the
  committed default) buried the trap under a real difference.

## Section 5 phase A run (save transactions)

`./tests/run-all.sh`: core 488, settings 177, cli 292, journey 76/76
(was 73, plus 3 dirty-worktree checks), usability 56, schema 50,
crypto 89, state 76, save 46/46 (new suite), QML 26. Zero failures.
All 59 mutations caught, including 3 new ones for the save guards.

What changed:

- New `bin/lib/save.sh`, loaded last in `replicant-core.sh`: `core_save`
  (`--all`, `--id` repeated, `--inventory`, `-m`, `--auto`,
  `--no-push`), `snapshot_one` (one entry into the repo, printing the
  repo-relative paths it wrote), `save_scan_tx`, `save_auto_subject`,
  `save_push` and `save_fix_modes`. A save snapshots live entries into
  a detached worktree at `$REPLICANT_HOME/transactions/<uuid>/repo`,
  writes `meta.json` beside it (base, scope, ids, message, stage,
  candidate, push result), commits once, verifies the active HEAD is
  still the base, fast-forwards, pushes, and removes the worktree.
  Anything that fails before the fast-forward leaves the active repo
  untouched; a committed transaction is never removed automatically.
- The snapshot reuses the existing copy passes with the repo paths
  redirected (`REPLICANT_TX_REPO`): the global snapshot re-runs
  `backup`, the selective one runs `snapshot-one`. No copy logic is
  duplicated, so v1 and v2 save through the same code. `.git` presence
  checks use `-e` now: a linked worktree carries a `.git` file, and
  `ensure_repo_layout` re-ran `git init` inside it before the fix.
- `save` is the command; `savegame` is a deprecated alias (bare maps
  to `save --inventory`, with `-m` or `--auto` to `save --all`).
  `save-file` is `save --id` with a default subject. `set` and
  `revert` save through `save --all -m`. One commit holds config and
  inventory together; the separate inventory-only commit is gone
  except for explicit `save --inventory`.
- A save needs a clean active worktree and says so with the file
  list. repos with no commits yet save inline (legacy path): there is
  no history to protect and no HEAD that could move.
- `purge` names `cache/` and `transactions/`. The brief cache is
  invalidated after the fast-forward.
- The CLI's `push_pending` is gone: its only caller was the old
  `cmd_savegame`, and pushes for saves live in `save_push` now.
  `cmd_push` keeps its own push path.

Traps found by the tests, all fixed:

- Git tracks only the exec bit, so the fast-forward checkout rebuilt
  v1 secret copies at 644 although the snapshot installed them at
  600. `save_fix_modes` re-applies 600 (and 700 on the secrets dir)
  after the fast-forward. Vault blobs keep checkout modes, which
  matches the old flow.
- An `--inventory` save with pending config fell into the
  message-less review instead of its standing subject. Inventory
  scope without `-m` always uses the inventory subject now.
- The scanner knows `ghp_` tokens, not `gho_` ones: the token test
  uses the classic shape like the core suite does.
- Two suites relied on saves absorbing backup litter (a doctor
  backup, an unborn repo after purge). The journey now asserts the
  refusal and recovers; test-cli absorbs the fixtures the way it
  already did for the save-file section.

## Section 5 phase B and section 6 phase A

`./tests/run-all.sh` passed with core 488, settings 177, cli 292,
journey 76, usability 56, schema 50, crypto 89, state 76, save 76,
and QML 26. The run took 79 s.

Transaction recovery is now part of `doctor`. The `tx list`, `tx resume`,
and `tx discard` commands handle abandoned journals. A committed transaction
needs an explicit force flag before removal. Pull rejects a dirty active
worktree and no longer uses stash and pop. `backup` is a read-only alias for
`changes`, and selective saves use `save --id`.

Section 6 phase A adds `policy set --scope <scope> -- <id...>`. The command
validates every selected ID and the scope before it writes `.replicant-sync`.
It applies the complete scope change and creates one repository-shape commit.
An invalid selection leaves the policy and commit unchanged. Entry type
conversion stays outside this command.

The new CLI tests cover the command help, invalid bulk selections, two-entry
scope changes, one-commit behavior, and return to the shared scope.

## Sections 8 and 9 phase A (status contract and migration)

`./tests/run-all.sh` passed in 84 s. The run includes 27 QML tests,
ShellCheck, QML syntax checks, the secret scanner, and plugin validation.

What changed:

- Full status now publishes schema version 2 with one `entries` array.
  Each entry exposes its source, scope, state, counts, and lock status.
  The old `configs` and `secrets` arrays remain for compatibility.
- The panel reads `entries` first and keeps the old arrays as a fallback.
  Locked secret entries omit their live path.
- `migrate-v2` builds a clean repository in a staging directory.
  It creates a post-quantum identity, encrypts secrets, validates the tree,
  pushes one root commit, verifies an independent clone, and activates the
  new repository with the legacy copy retained.
- Migration writes an external identity backup with mode 600 and a warning
  file that records the required legacy cleanup.
- The migration suite covers dirty-source rejection, encrypted output,
  remote history, identity matching, and locked status output.

## Section G8 (release review)

New suite `tests/test-g8.sh`: 46 checks, all pass. It pins the release
architecture and the v3 documentation: the CLI owns no git plumbing, the
transaction module owns mutations, legacy parsing lives in migration code,
no v2 writer remains, scope resolution has one path, and the docs name the
v3 schema record, the policy stores, `migrate-v3`, recovery and every key
workflow. `./tests/gate.sh G8` passes with 9 checks.

What changed:

- `bin/omarchy-replicant` lost its `git_repo` helper and its own cache
  invalidation. `diff`, `log` and `doctor` read through new core helpers
  (`core_diff_summary`, `core_log_text`, `repo_remote_url`,
  `repo_hooks_path`), and every mutation invalidates through
  `bash "$CORE" cache-invalidate`. The CLI parses, confirms, dispatches
  and renders only.
- `bin/lib/transaction.sh` gained `tx_shape_policy_paths`: the one list of
  policy stores every shape commit stages. Scope, policy, track, forget
  and recover build their commits from it. `core_profile_transact` runs
  through `core_shape_transact` like every other policy write.
- `bin/lib/migrate.sh` owns every legacy policy read through
  `migrate_legacy_*` wrappers. `scopes.sh`, `manifest.sh` and `track.sh`
  call the wrappers, never `legacy_*` directly.
- `ensure_v2_layout` is gone: nothing writes version 2 records anymore.
  The `validate_v2_entries`, `load_v2_entries` and `_v2_*` aliases stay as
  read-only aliases for the legacy parity suite.
- `scope_for` answers from the shared scope cache on version 3, the same
  cache `scope_into` reads, so resolution has one path.
- `docs/SPEC.md` documents the v3 schema record (`dataVersion` 3,
  `age-pq-v2`), the entries registry, the encrypted vault index, schema
  version 3, `migrate-v3` with its deprecated alias, public-repository
  refusal, transaction recovery (`tx list`, `tx resume`, `tx discard`,
  `doctor`) and every key workflow. `README.md` and
  `docs/getting-started.md` migrate with `migrate-v3`, name the v3 policy
  stores and carry the key workflows to the second machine.
- The plugin manifest is 0.13.0.

Transaction recovery, as documented: every mutation journals before it
commits. `tx list` shows abandoned transactions, `tx resume` fast-forwards
a committed one and pushes, `tx discard` drops a pre-commit one (a
committed one needs `--force`). The key rotation journal and the migration
journal cover the two operations that outlive one commit. Recovery never
discards committed work implicitly.

Verification: `./tests/run-all.sh` passed in 251 s with QML 57 passed and
0 failed. `./tests/mutate.sh` caught all 87 mutations, including the new
guards for the transaction engine, migration recovery and bulk validation.
`./tests/bench-status.sh --check` passes (full 0.09 s against a
0.25 s budget, brief 0.09 s against 0.10 s).
`./tests/test-g7-screenshots.sh` passes with 8 visual fixtures matched, so
the panel screenshots stand as reviewed.

Environment note: the full parallel `run-all.sh` inside the Docker test
image fails 3 checks in `test-interruptions.sh` (the push-interruption
section). The git wrapper that stops the save never engages there: under
parallel load the save does not reach the push stage inside the 4 s
interruption window. The same image passes the suite 12/12 run alone, the
local machine passes it 12/12, and a baseline image without these changes
fails the same 3 checks in the full parallel run. The failure is a
pre-existing load flake of that timing-sensitive suite, not a regression.
