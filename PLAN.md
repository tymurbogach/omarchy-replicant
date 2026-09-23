# Replicant v2 Implementation Plan

## Summary

This plan replaces the mutable Git worktree and plaintext secret storage with transactional saves,
encrypted secrets, unified state evaluation, bulk management, and deterministic UI navigation.

Current tests confirm that an unsaved file or directory returns to `saved` when its content matches
the repository again. Preserve this behavior. The redesign must also remove the remaining stale-draft
case caused by the current `backup` workflow.

Never copy personal repository data, paths, secret names, or credentials into this repository,
fixtures, logs, screenshots, or documentation.

## 1. Establish the Baseline

- [x] Record the current architecture and command behavior before refactoring.
- [x] Run `./tests/run-all.sh` and save the totals in the development journal.
- [x] Fix the QML test runner environment in `tests/run-all.sh`.
  - Unset `QT_QPA_PLATFORMTHEME`.
  - Set `QT_QPA_PLATFORM=offscreen`.
  - Confirm that all 25 current QML tests pass.
- [x] Add characterization tests for these existing guarantees:
  - A file edit produces `unsaved`.
  - Restoring the original bytes clears `unsaved`.
  - The same behavior applies to tracked directories.
  - Incoming changes take priority over local unsaved changes.
  - Restore creates a safety backup.
  - An older client cannot prune data from a newer repository.
- [x] Add a failing regression test for the current missing-file defect.
  - A saved entry that is absent locally must increase the `missing` count.
  - Brief status must not report `synced`.
  - The bar must show an actionable missing state.

## 2. Introduce the v2 Data Repository Schema

- [x] Add a schema version that rejects unknown or newer formats before any mutation.
- [x] Replace the legacy root metadata with this structure:

```text
.replicant/
  schema.json
  entries.json
  recipient.txt
  machines/
    <machine-id>.json
config/
profiles/
  <profile>/
    config/
vault/
  index.age
  blobs/
    <opaque-id>.age
state/
  <machine-id>/
templates/
.githooks/
  pre-commit
tools/
  scan-secrets.sh
```

- [x] Define `.replicant/schema.json` with:
  - `dataVersion: 2`
  - `secretFormat: "age-pq-v1"`
- [x] Define `.replicant/entries.json` as an object keyed by stable entry ID.
- [x] Give each non-secret entry these fields:

```json
{
  "path": "/absolute/live/path",
  "kind": "config",
  "scope": "shared",
  "source": "user"
}
```

- [x] Restrict `scope` to `shared`, `profile`, or `off`.
- [x] Restrict `source` to `user` or `override`.
- [x] Keep the shipped catalog in the plugin source.
- [x] Treat a missing v2 entry record as the shipped default policy.
- [x] Keep machine metadata limited to the machine ID, selected profile, client version, and schema version.
- [x] Validate all paths, IDs, scopes, and schema values before reading repository content.
- [x] Reject duplicate IDs, path collisions, nested tracked roots, repository paths, and unsupported file types.

## 3. Encrypt All Secret Data

- [x] Declare `age` and `age-keygen` as runtime dependencies.
- [x] Detect support for `age-keygen -pq` during preflight.
- [x] Fail with an exact install or upgrade instruction if post-quantum key generation is unavailable.
- [x] Follow the recipient and identity model from the official
      [age documentation](https://github.com/FiloSottile/age/blob/main/doc/age.1.html).
- [x] Store the shared private identity at `$REPLICANT_HOME/keys/identity.txt`.
- [x] Set its mode to `0600`.
- [x] Never copy the identity into Git, logs, command output, status JSON, backups, or temporary repository worktrees.
- [x] Store only the public recipient in `.replicant/recipient.txt`.
- [x] Add these commands:
  - `omarchy-replicant key init`
  - `omarchy-replicant key export <absolute-destination>`
  - `omarchy-replicant key import <source>`
  - `omarchy-replicant key status`
  - `omarchy-replicant key rotate`
- [x] Make `key init` generate one shared post-quantum identity and its recipient.
- [x] Require `key export` to use a destination outside the data repository and `$REPLICANT_HOME`.
- [x] Verify an exported identity by deriving and comparing its recipient.
- [x] Require each new machine to import the identity once before it can save or restore secrets.
- [x] Store secret metadata only inside `vault/index.age`.
- [x] Include secret path, scope, and blob ID inside the encrypted index.
- [x] Generate a random 128-bit blob ID for each secret.
- [x] Do not derive blob IDs from secret paths, names, or content.
- [x] Remove `defined-secrets.txt`.
- [x] Remove secret variable names from status output.
- [x] Keep only non-sensitive values such as `var_count`.
- [x] Use one encrypted blob per secret under `vault/blobs/`.
- [x] Compare live plaintext with the current decrypted blob before encryption.
- [x] Preserve the existing ciphertext when plaintext did not change.
- [x] Never place plaintext below the data repository or `$REPLICANT_HOME`.
- [x] Decrypt restores into a mode `0600` temporary file beside the destination.
- [x] Authenticate the complete ciphertext before replacing the destination.
- [x] Back up the current destination.
- [x] Use an atomic rename for the final replacement.
- [x] Remove temporary plaintext through a trap on success, error, signal, or cancellation.
- [x] Fail before repository mutation when the key is absent, invalid, or does not match the recipient.
- [x] Show secrets as `locked` when config status can continue but secret state cannot be evaluated.
- [x] Make `doctor` show the exact `key import` or `key status` remediation.
- [x] Document that key rotation cannot revoke access to historical ciphertext.
- [x] Require a new clean repository after a private key compromise.

## 4. Build One Entry Registry and State Evaluator

- [x] Add `bin/lib/registry.sh`.
- [x] Merge these sources into one normalized registry:
  - The shipped manifest.
  - `.replicant/entries.json`.
  - Discovered user entries.
  - The decrypted secret index.
- [x] Resolve each entry to one ID, kind, source, category, scope, live path, repository path, and restore policy.
- [x] Add `bin/lib/state.sh`.
- [x] Move all content comparison and state precedence rules into this module.
- [x] Represent independent facts before deriving a UI state:
  - Live presence.
  - Repository presence.
  - Content equality.
  - Default equality.
  - Local repository commit state.
  - Upstream state.
  - Incoming-path membership.
  - Secret lock state.
- [x] Derive `dirty` from live content comparison.
- [x] Do not store a durable dirty flag.
- [x] Preserve exact self-healing:
  - If bytes return to the saved version, clear `dirty`.
  - If a directory tree returns to the saved tree, clear `dirty`.
  - If a tracked entry returns to its shipped default, update `is_default`.
- [x] Count `missing`, `locked`, `incoming`, `unsaved`, and `unpushed` independently.
- [x] Derive `needs_action` from any actionable count.
- [x] Use this bar priority:
  1. Locked.
  2. Incoming or behind.
  3. Missing.
  4. Unsaved.
  5. Ahead or unpushed.
  6. Synced.
- [x] Make `build_configs_json`, secret status, change counts, save, diff, and restore use the same evaluator.
- [x] Delete duplicate comparison and state-precedence logic after parity tests pass.
- [x] Add a local brief-status cache at `$REPLICANT_HOME/cache/state-v2.json`.
- [x] Cache only source file identity, modification metadata, ciphertext object ID, and the previous result.
- [x] Never cache secret values, secret names, or plaintext hashes.
- [x] Invalidate the cache after save, pull, key import, key rotation, profile change, and restore.
- [x] Make full status bypass the cache and remain authoritative.
- [x] Test a content change that preserves the previous timestamp. Full status must still detect it.

## 5. Replace Dirty Worktrees with Save Transactions

- [x] Add `bin/lib/save.sh`.
- [x] Require the active data repository worktree to remain clean.
- [x] Create each save in a detached temporary Git worktree under `$REPLICANT_HOME/transactions/<uuid>/repo`.
- [x] Write a transaction journal to `meta.json`.
- [x] Record the base commit, selected IDs, stage, candidate commit, and push result.
- [x] Snapshot selected live entries into the transaction worktree.
- [x] Encrypt changed secrets there.
- [x] Regenerate inventory only for a global save or an explicit inventory save.
- [x] Validate the schema and run the secret scanner before the commit.
- [x] Create one commit for the complete save.
- [x] Verify that the active repository HEAD has not changed since the transaction started.
- [x] Fast-forward the active repository to the candidate commit.
- [x] Push the commit.
- [x] Remove the temporary worktree after success.
- [x] Keep the active repository unchanged when failure occurs before the fast-forward.
- [x] Return a non-zero exit code when the local commit succeeds but push fails.
- [x] Report `saved locally, push failed` without claiming full success.
- [x] Let the next save or explicit push retry the remote operation.
- [x] Add transaction recovery to `doctor`.
- [x] Let the user resume or discard an abandoned pre-commit transaction.
- [x] Never discard a committed transaction automatically.
- [x] Remove the pull-time stash and pop workflow.
- [x] Make pull reject an unexpected dirty active worktree with recovery instructions.
- [x] Make push outcomes consistent for save, policy, tracking, settings, and inventory commands.
- [x] Introduce `omarchy-replicant save`.
- [x] Keep `savegame` as a deprecated alias for one compatibility release.
- [x] Make `save-file` call `save --id <id>`.
- [x] Convert `backup` into a read-only alias for `changes`.
- [x] Use `changes` for review and `save --id ... -m "<reason>"` for a selective commit.
- [x] Create one commit for config and inventory changes during `save --all`.
- [x] Do not create a separate inventory-only commit during every save.

## 6. Add Atomic Bulk Policy Management

- [x] Add `omarchy-replicant policy set --scope <scope> -- <id...>`.
- [x] Keep entry type conversion separate from scope changes.
- [x] Validate all IDs, scopes, paths, permissions, and conversions before mutation.
- [x] Apply the complete bulk operation through one transaction and one commit.
- [x] Make any validation failure leave all entries unchanged.
- [x] Support these bulk actions:
  - [x] Save selected entries.
  - [x] Set selected entries to shared.
  - [x] Set selected entries to the current profile.
  - [x] Disable selected entries.
  - [x] Track selected suggestions.
  - [x] Convert selected user entries to secrets.
  - [x] Stop tracking selected user entries.
- [x] Hide operations that cannot apply to the complete selection.
- [x] Require one summary confirmation for destructive operations and type conversions.
- [x] Keep the existing 400-file hard limit for tracked trees.
- [x] Add a large-content warning with a default of 10 MiB.
- [x] Require `--allow-large` after that threshold.
- [x] Warn when Git pack data exceeds 100 MiB.
- [x] Detect binary files, nested repositories, sockets, devices, and recursive tracking before acceptance.
- [x] Never auto-track a suggestion.

## 7. Simplify the Shell Architecture

- [x] Keep `bin/omarchy-replicant` responsible for argument parsing, confirmation, and output only.
- [x] Move save and transaction behavior into `bin/lib/save.sh`.
- [x] Move encryption behavior into `bin/lib/crypto.sh`.
- [x] Move migration behavior into `bin/lib/migrate.sh`.
- [x] Move inventory behavior out of layout code and into `bin/lib/inventory.sh`.
- [x] Keep `bin/lib/layout.sh` responsible only for repository layout and schema upgrades.
- [x] Make `bin/lib/status.sh` serialize registry and state results without deriving policy.
- [x] Move repository lifecycle and remote transport into `bin/lib/repo.sh`.
- [x] Move backup entrypoint ownership into `bin/lib/backup.sh`.
- [x] Preserve stable command output until compatibility fields are removed.
- [x] Avoid unrelated refactors in settings and plugin-management modules.
- [x] Add shell module contract tests before deleting legacy functions.

## 8. Publish the v2 Status Contract

- [x] Add `schema_version: 2` to full status.
- [x] Publish one unified `entries` array.
- [x] Give each entry these fields:

```text
id
label
src
kind
source
category
scope
exists
saved
is_default
dirty
unpushed
incoming
sync_state
is_dir
nfiles
locked
```

- [x] Omit `src` for locked secrets when it would reveal encrypted metadata.
- [x] Add top-level `counts`, `encryption`, and `migration` objects.
- [x] Keep derived `configs` and `secrets` arrays for one compatibility release.
- [x] Make new QML consume `entries`.
- [x] Keep existing IPC methods for status, refresh, and initial panel tab.
- [x] Add `locked` to the documented state legend.
- [x] Add JSON contract tests for full and brief output.

## 9. Migrate to a Clean Repository

- [x] Add this command:

```text
omarchy-replicant migrate-v2 \
  --github-name <name> \
  --identity-backup <absolute-path> \
  [--yes]
```

- [x] Also support `--remote <url>` for an existing empty private remote.
- [x] Run the migration from a terminal, not inside the panel process.
- [x] Preflight all requirements before creating the destination:
  - The source repository is clean and synchronized.
  - The new remote is empty and private.
  - The remote name does not collide.
  - `age-keygen -pq` works.
  - A valid identity exists or can be generated.
  - The external identity backup path is absolute and safe.
  - Other recorded machines use a v2-capable client or are offline.
- [x] Build the new repository under `$REPLICANT_HOME/migration/<uuid>/repo`.
- [x] Migrate current policy, profile configuration, config snapshots, and inventories.
- [x] Encrypt every current secret and its metadata.
- [x] Do not copy legacy Git objects, refs, reflogs, or commit history.
- [x] Run schema validation and the secret scanner.
- [x] Create one root commit.
- [x] Push the new repository.
- [x] Clone or fetch it independently and verify the resulting tree and commit.
- [x] Rename the active legacy repository to `$REPLICANT_HOME/legacy-repo-<epoch>`.
- [x] Activate the v2 repository through an atomic rename.
- [x] Keep the legacy repository active when any step before activation fails.
- [x] Never delete the legacy local repository or remote automatically.
- [x] Show a persistent warning until the user confirms:
  - Relevant credentials have been rotated.
  - The legacy remote has been deleted.
  - The legacy local copy has been removed or secured.
- [x] Permit legacy v1 status, diff, dry-run restore, and migration.
- [x] Block v1 saves, tracking changes, scope changes, and secret mutations.
- [x] Tell the user to migrate before any blocked operation.
- [x] Test that the new remote has one root commit and no reachable legacy objects.

## 10. Add Bulk Management to the Panel

- [x] Add a Manage action to the Configs view.
- [x] Bind `m` to enter or exit manage mode.
- [x] Show checkboxes only in manage mode.
- [x] Support:
  - [x] Space to toggle an entry.
  - [x] Shift selection for a range.
  - [x] Ctrl+A to select visible entries.
  - [x] Clear selection.
  - [x] Invert visible selection.
- [x] Add a fixed bulk-action footer.
- [x] Show selected count, visible count, estimated file count, and estimated size.
- [x] Reuse the existing Card, ListRow, RowAction, and FilterBar components.
- [x] Add dedicated components only for the manage view and bulk-action footer.
- [x] Send one atomic command for each confirmed bulk operation.
- [x] Update policy optimistically only after the command is accepted.
- [x] Restore the previous UI state when the command fails.
- [x] Clear selection after successful completion.
- [x] Preserve selection after a recoverable error.
- [x] Extend tracking suggestions with kind, size, file count, and risk warnings.

## 11. Make Navigation State Deterministic

- [x] Replace `onActiveTabChanged: body.contentY = 0`.
- [x] Store independent scroll positions for each tab.
- [x] Add a navigation snapshot with:
  - Active tab.
  - Per-tab scroll position.
  - Expanded cards.
  - Expanded row.
  - Commit expansion state.
  - Search and filters.
  - Selected entries.
  - Return row or card ID.
  - Row offset from the viewport.
- [x] Capture the snapshot before diff, preview, confirmation, edit, or manage views open.
- [x] Restore it after the status refresh and layout pass.
- [x] Use `Qt.callLater` to restore after item geometry stabilizes.
- [x] Expose a row-anchor lookup from the Configs view and category cards.
- [x] Restore the same row at the same viewport offset when possible.
- [x] Fall back to the clamped raw scroll position if the row disappeared.
- [x] Reset only the current tab to the top when its filter changes intentionally.
- [x] Preserve UI state in memory for the current shell session.
- [x] Do not write search, selection, or navigation state to disk.
- [x] Reset the text viewer scroll position each time new content opens.
- [x] Reopen the panel after an editor exits when the terminal supports waiting.
- [x] Show an explicit result when the editor cannot wait and automatic return is unavailable.

## 12. Extract Panel Control Logic

- [x] Add `ReplicantController.qml`.
- [x] Move process ownership, command queues, refresh scheduling, and action dispatch out of `Panel.qml`.
- [x] Keep `Panel.qml` responsible for presentation and navigation.
- [x] Keep `replicant.js` pure and side-effect free.
- [x] Replace growing conditional action dispatch with command descriptors.
- [x] Preserve current component APIs until controller integration tests pass.
- [x] Split further only when a component has a clear state boundary.

## 13. Add Terminal and Panel Quality-of-Life Features

- [x] Add arrow-key and `j`/`k` navigation.
- [x] Use Enter to open the focused row.
- [x] Use Escape to close the current overlay or return one level.
- [x] Add `?` for a keyboard help overlay.
- [x] Add next-change and previous-change actions in the diff viewer.
- [x] Add copy actions for live and repository paths.
- [x] Add filters for changed, incoming, missing, locked, and large entries.
- [x] Sort actionable entries before saved entries while keeping stable ordering.
- [x] Show visible and total counts after every filter.
- [x] Add useful empty states with a direct next action.
- [x] Show distinct offline, ahead, behind, and local-only states.
- [x] Add a retry-push action when a commit is local only.
- [x] Report save stages: scanning, encrypting, committing, and pushing.
- [x] Permit cancellation only before the commit stage.
- [ ] Give every disabled action a visible reason.
- [ ] Ensure all essential operations work without a mouse.
- [x] Keep secret values and encrypted metadata out of notifications and clipboard actions.

## 14. Test Failure Modes and Security Boundaries

- [x] Add dedicated crypto, migration, transaction, and registry test suites.
- [x] Run integration tests in a container with an `age` build that supports `-pq`.
  `tests/run-all.sh` passes in the `replicant-tests` image. The container uses age 1.3.2.
- [x] Test missing, wrong, malformed, and permission-invalid identities.
- [x] Test tampered ciphertext. It must never replace live data.
- [x] Test interruption during encryption, commit, fast-forward, and push.
- [x] Test push failure after local commit.
- [x] Test recovery from an abandoned transaction journal.
- [x] Test two fake machines that import the same identity.
- [x] Test shared, profile, and machine-specific state across both machines.
- [x] Test that unchanged plaintext does not replace existing ciphertext.
- [x] Test that repository history contains no plaintext secret, secret path, or variable name.
- [x] Test that stdout, stderr, temporary files, and failure logs contain no plaintext secret.
- [x] Test that an invalid bulk ID produces no partial policy changes.
- [x] Test that one bulk action creates one commit.
- [x] Test missing-file counts and bar priority.
- [x] Test edit and exact revert for files and directories.
- [x] Test incoming changes combined with local changes.
- [ ] Test navigation restoration after diff, preview, edit, refresh, and row removal.
- [ ] Test viewer scroll reset separately from body scroll restoration.
- [x] Add pure JavaScript tests for navigation snapshots.
- [x] Add offscreen QML interaction tests for manage mode and focus.
- [x] Complete one real-shell screenshot review for each changed visual state.
- [x] Add mutation tests for schema validation, secret guards, atomic bulk behavior, and migration activation.

## 15. Acceptance Criteria

- [x] `./tests/run-all.sh` passes without display-server failures.
- [x] ShellCheck, QML syntax checks, manifest validation, and repository scanners pass.
- [x] `omarchy plugin validate .` passes.
- [x] A fresh installation can initialize a key, create a v2 repository, save, clone, import the key, and restore.
- [x] A migrated repository contains no legacy history or plaintext secret data.
- [x] The active data repository remains clean outside an explicit transaction.
- [x] Every write command reports local commit and remote push results accurately.
- [x] An edit followed by an exact content revert produces no pending change.
- [x] A missing saved entry never produces a synced bar state.
- [x] Closing diff, preview, edit, or confirmation returns to the same tab, row, expansion state, and viewport offset.
- [x] Bulk operations are atomic and create one commit.
- [x] Status performance does not regress by more than 10 percent against the recorded baseline.
- [x] Full status remains authoritative even when file timestamps are preserved.
- [x] No test, fixture, screenshot, document, commit message, or log contains personal repository data.

## Assumptions

- The redesign intentionally breaks the legacy data layout and uses an explicit clean migration.
- All user machines share one externally backed-up age identity.
- Losing every machine and the external identity backup makes encrypted secrets unrecoverable.
- The plugin does not install system packages automatically.
- Git remains the storage and synchronization mechanism for configuration and inventory data.
- Large binaries and high-volume application data remain outside Replicant.
- Legacy v1 receives read-only compatibility for migration, not continued write support.
- Compatibility fields remain for one release and are then removed through a documented schema change.
