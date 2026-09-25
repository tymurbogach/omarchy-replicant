# Replicant v3 Verification and Hardening Plan

  ## Delivery and Git Protocol

  - [x] Replace the current PLAN.md with this complete plan before changing code.
  - [x] Record 4c9c4b580d4d190ea2efd6e0b8449ffd790d091e as the audit baseline.
  - [x] Assign only one phase to each agent.
  - [x] Complete phases in numeric order.
  - [x] Add a failing regression test before each fix.
  - [x] Keep unfinished phase changes uncommitted for the next agent.
  - [x] Do not commit a phase until every phase gate passes.
  - [x] Mark completed phase checkboxes before its commit.
  - [x] Review git diff, git diff --check, and git status --short.
  - [x] Stage only files that belong to the current phase.
  - [x] Never add AGENTS.md.
  - [ ] Create one local commit after each completed phase.
  - [x] Never amend a completed phase commit.
  - [x] Never add AI attribution to commits.
  - [x] Never push, create a pull request, create a release, or create a tag.
  - [x] If a gate fails, do not commit the phase.
  - [ ] After all phases, leave the complete plugin and local commits for user review.
  - [ ] Only the user can authorize the final push.

  Use these exact phase commit messages:

   Phase    Commit message
  ━━━━━━━  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   G0       test: isolate automated verification
  ───────  ───────────────────────────────────────────────
   G1       feat: define the Replicant v3 schema
  ───────  ───────────────────────────────────────────────
   G2       fix: make repository bootstrap fail safe
  ───────  ───────────────────────────────────────────────
   G3       feat: migrate legacy repositories to v3
  ───────  ───────────────────────────────────────────────
   G4       refactor: unify repository transactions
  ───────  ───────────────────────────────────────────────
   G5       fix: align status bulk and settings state
  ───────  ───────────────────────────────────────────────
   G6       fix: harden secret restore handling
  ───────  ───────────────────────────────────────────────
   G7       fix: preserve controller and navigation state
  ───────  ───────────────────────────────────────────────
   G8       docs: finalize Replicant v3 verification

  ## Verified Baseline

  The current suite passes, including 41 QML tests and 63 mutation tests.

  The isolated status benchmark averages 30 ms. However, existing tests miss critical integration defects.

  ## Public Contract Changes

  - [x] Introduce repository dataVersion: 3.
  - [x] Set secretFormat to age-pq-v2.
  - [x] Add migrate-v3 for v1 and v2 repositories.
  - [x] Keep migrate-v2 as a deprecated forwarding alias for one release.
  - [x] Add the global --progress-json CLI option.
  - [x] Add key export --force.
  - [x] Represent unknown secret persistence as "saved": null.
  - [x] Add "savedKnown": false when the vault is locked.
  - [x] Keep normal human-readable CLI output compatible.
  - [ ] Bump the plugin version to 0.13.0 after all gates pass.

  ## Phase G0: Automated Test Infrastructure

  - [x] Add tests/gate.sh <phase> as the canonical phase runner.
  - [x] Add gates G0 through G8.
  - [x] Initialize an isolated HOME and XDG environment in every gate.
  - [x] Create local bare Git remotes for integration tests.
  - [x] Reject unexpected network access.
  - [x] Stub gh, editors, privilege tools, and external failures.
  - [x] Assert repository cleanliness after each test.
  - [x] Assert temporary file removal after each test.
  - [x] Fix tests/bench-status.sh so it never writes user state.
  - [x] Add a deterministic benchmark --check mode.
  - [x] Set full status budget to 250 ms.
  - [x] Set brief status budget to 100 ms.
  - [x] Add a public command coverage manifest.
  - [x] Map every help command to success, failure, and no-op tests.
  - [x] Fail when any public command has no mapped tests.
  - [x] Add a QML integration harness for the real controller.
  - [x] Add mock Omarchy QML modules for container tests.
  - [x] Update tests/Dockerfile with every required dependency.
  - [x] Save this complete plan in PLAN.md.

  Gate:

  ./tests/gate.sh G0
  ./tests/run-all.sh
  ./tests/bench-status.sh --check

  Commit:

  git commit -m "test: isolate automated verification"

  ## Phase G1: Canonical v3 Repository Schema

  Use this schema record:

  {
    "dataVersion": 3,
    "secretFormat": "age-pq-v2"
  }

  Store non-secret mutable policy in .replicant/entries.json:

  {
    "entry-id": {
      "path": "/absolute/live/path",
      "kind": "config",
      "scope": "shared",
      "source": "user"
    }
  }

  Store secret metadata only inside the encrypted vault index:

  {
    "version": 2,
    "secrets": [
      {
        "id": "secret-id",
        "path": "/absolute/live/path",
        "scope": "shared",
        "source": "user",
        "blob": "32-character-hex-id"
      }
    ]
  }

  - [x] Make v3 the only writable repository version.
  - [x] Keep v1 and v2 readable for inspection and migration.
  - [x] Move legacy readers into a migration-only module.
  - [x] Stop creating .replicant-track, .replicant-sync, and .replicant-profiles.
  - [x] Retain .replicant-version as the old-client prune guard.
  - [x] Store the active profile only in the current machine JSON record.
  - [x] Validate machine IDs before constructing paths.
  - [x] Validate every entries record before use.
  - [x] Validate every decrypted vault index before use.
  - [x] Reject duplicate IDs, paths, blobs, and secret paths.
  - [x] Reject control characters and path traversal.
  - [x] Reject invalid kinds, scopes, sources, and blob identifiers.
  - [x] Reject legacy policy files inside a v3 repository.
  - [x] Fail before mutation when validation fails.
  - [x] Build the registry from validated canonical records.
  - [x] Preserve shipped defaults without explicit overrides.
  - [x] Discover custom secrets directly from the encrypted index.
  - [x] Remove duplicate scope and profile resolution paths.

  Tests:

  - [x] Create and validate an empty v3 repository.
  - [x] Reject each malformed schema field.
  - [x] Reject duplicate JSON keys before jq collapses them.
  - [x] Track, save, reload, and untrack a custom secret.
  - [x] Change an entry scope and reload the registry.
  - [x] Restore the original scope and verify zero pending changes.
  - [x] Change a profile and reload machine metadata.
  - [x] Verify that fresh v3 repositories contain no legacy policy files.
  - [x] Reject writes after simulated legacy-file contamination.

  Gate and commit:

  ./tests/gate.sh G1
  ./tests/run-all.sh
  git commit -m "feat: define the Replicant v3 schema"

  ## Phase G2: Fresh Initialization and Private Repository Safety

  - [x] Distinguish a missing repository from an existing v1 repository.
  - [x] Create the v3 schema before applying the write gate.
  - [x] Build fresh repositories in temporary Git directories.
  - [x] Validate the complete repository before activation.
  - [x] Activate the repository with one atomic rename.
  - [x] Remove temporary repositories after every failure.
  - [x] Make create request private GitHub visibility.
  - [x] Verify visibility after repository creation.
  - [x] Reject existing public repositories before local mutation.
  - [x] Never change public visibility automatically.
  - [x] Avoid changing origin before every preflight succeeds.
  - [x] Make clone identify v1 and v2 repositories as migration-only.
  - [x] Report exact recovery commands after remote failures.

  Tests:

  - [x] Run init without existing state.
  - [x] Run create without existing state.
  - [x] Create against an existing private remote.
  - [x] Reject an existing public remote.
  - [x] Assert that public rejection performs no push or remote change.
  - [x] Inject failures before validation, activation, and first push.
  - [x] Verify that failed initialization leaves no partial repository.

  Gate and commit:

  ./tests/gate.sh G2
  ./tests/run-all.sh
  git commit -m "fix: make repository bootstrap fail safe"

  ## Phase G3: Atomic v1 and v2 Migration

  - [x] Implement migrate-v3 for both legacy formats.
  - [x] Generate a migration summary before accepting --yes.
  - [x] List every recorded machine in that summary.
  - [x] Make --yes acknowledge that those machines are upgraded or offline.
  - [x] Require a clean local repository.
  - [x] Require a configured and reachable remote.
  - [x] Require proven upstream synchronization.
  - [x] Refuse migration without upstream tracking.
  - [x] Check destination collisions before mutation.
  - [x] Back up and verify the existing identity before remote mutation.
  - [x] Copy only allowlisted state files.
  - [x] Exclude retired inventories such as defined-secrets.txt.
  - [x] Reconstruct custom secret paths from legacy metadata.
  - [x] Refuse migration when a secret path cannot be reconstructed.
  - [x] Preserve custom secrets, scopes, profiles, and machine records.
  - [x] Verify every encrypted index entry and blob.
  - [x] Decrypt and compare every secret before activation.
  - [x] Verify non-secret file digests and permissions.
  - [x] Push the staged repository only after complete local verification.
  - [x] Activate the staged repository only after remote verification.
  - [x] Restore the original identity and repository after activation failure.
  - [x] Keep a recovery journal until activation completes.
  - [x] Detect legacy writes made after migration.

  Tests:

  - [x] Migrate a representative v1 repository.
  - [x] Migrate the current v2 layout.
  - [x] Migrate a custom secret absent from shipped manifests.
  - [x] Migrate all scopes and multiple profiles.
  - [x] Migrate two recorded machines.
  - [x] Refuse an unknown secret path.
  - [x] Refuse dirty, ahead, behind, divergent, and missing-upstream states.
  - [x] Inject failure at every migration boundary.
  - [x] Verify identity restoration after every injected failure.
  - [x] Run the v0.11 client against v3 and detect its artifacts.

  Gate and commit:

  ./tests/gate.sh G3
  ./tests/run-all.sh
  git commit -m "feat: migrate legacy repositories to v3"

  ## Phase G4: One Transaction Engine

  - [x] Add bin/lib/transaction.sh.
  - [x] Move bulk transaction logic out of the CLI.
  - [x] Route save, bulk, policy, profile, and repository-shape writes through it.
  - [x] Route vault metadata and key rotation through it.
  - [x] Keep the CLI limited to parsing, confirmation, dispatch, and rendering.
  - [x] Require a clean worktree before starting.
  - [x] Create the journal before creating a candidate commit.
  - [x] Fail when any journal write fails.
  - [x] Write journals with temporary files and atomic renames.
  - [x] Build and validate mutations in temporary worktrees.
  - [x] Fast-forward the active repository after local validation.
  - [x] Push only after successful local activation.
  - [x] Preserve local commits when pushes fail.
  - [x] Report a local-only outcome and retry command.
  - [x] Make recovery inspect actual Git state.
  - [x] Remove ignored git add and git commit failures.
  - [x] Lock key init, key import, and key rotate.
  - [x] Coordinate key export with rotation.
  - [x] Refuse existing export destinations without --force.
  - [x] Install exported keys atomically with mode 0600.
  - [x] Preserve the previous key during unfinished rotation.
  - [x] Reconcile keys and repositories from the journal.
  - [x] Split core_save into planning, staging, validation, and activation.

  Tests:

  - [x] Test every mutator with an unwritable journal directory.
  - [x] Test hook, commit, fast-forward, and push failures.
  - [x] Test concurrent save, bulk, policy, and key commands.
  - [x] Send INT, TERM, and HUP at every stage.
  - [x] Simulate process death during key rotation.
  - [x] Verify that a usable identity always matches the active repository.
  - [x] Verify that recovery never discards committed work implicitly.
  - [x] Verify that each mutation creates at most one commit.

  Gate and commit:

  ./tests/gate.sh G4
  ./tests/run-all.sh
  git commit -m "refactor: unify repository transactions"

  ## Phase G5: Status, Bulk Operations, and Settings

  - [x] Exclude implicit entries missing from live and repository state.
  - [x] Keep explicitly tracked missing entries visible.
  - [x] Derive full and brief counts from one state model.
  - [x] Assert full and brief count equality for identical snapshots.
  - [x] Return saved: null for locked secrets.
  - [x] Include vault index changes in secret unpushed state.
  - [x] Rebuild status after every successful mutation.
  - [x] Fix newline, tab, and carriage-return validation.
  - [x] Measure total directory bytes before bulk tracking.
  - [x] Enforce the 10 MiB threshold for files and directories.
  - [x] Preserve the 400-file hard limit.
  - [x] Warn above 100 directory files.
  - [x] Reject .git files and directories.
  - [x] Detect binary content by encoding.
  - [x] Permit textual JSON, scripts, and application MIME types.
  - [x] Implement successful v3 bulk secret workflows.
  - [x] Make settings save only their owning entries.
  - [x] Preserve unrelated pending changes.
  - [x] Report when a local setting change was not persisted.
  - [x] Provide the exact retry command.

  Tests:

  - [x] Test every status state.
  - [x] Test full and brief count parity.
  - [x] Test large files, trees, binaries, and .git artifacts.
  - [x] Test every bulk action.
  - [x] Test remote rejection and concurrent bulk operations.
  - [x] Test settings persistence failures.
  - [x] Verify that settings never save unrelated entries.

  Gate and commit:

  ./tests/gate.sh G5
  ./tests/run-all.sh
  git commit -m "fix: align status bulk and settings state"

  ## Phase G6: Secret Restore and Leak Prevention

  - [x] Request privilege before decrypting root-owned destinations.
  - [x] Stream plaintext to a privileged same-directory temporary file.
  - [x] Rename only after a complete write.
  - [x] Never leave plaintext below REPLICANT_HOME.
  - [x] Never retain plaintext for recovery commands.
  - [x] Remove cross-filesystem temporary-file fallbacks.
  - [x] Fail when atomic replacement is unavailable.
  - [x] Preserve mode 0600.
  - [x] Preserve the correct owner.
  - [x] Verify age and age-keygen independently.
  - [x] Prevent secret values from reaching output, logs, journals, or arguments.

  Tests:

  - [x] Restore secrets inside and outside HOME.
  - [x] Restore to a simulated root-owned destination.
  - [x] Fail privilege acquisition before decryption.
  - [x] Fail writes before and after temporary-file creation.
  - [x] Interrupt decryption and installation.
  - [x] Scan temporary trees after every failure.
  - [x] Scan Git objects and history for plaintext markers.
  - [x] Inspect process arguments during secret operations.
  - [x] Reject tampered indexes and blobs.

  Gate and commit:

  ./tests/gate.sh G6
  ./tests/run-all.sh
  ./tests/test-leaks.sh
  git commit -m "fix: harden secret restore handling"

  ## Phase G7: Controller, Navigation, and UX

  Use this progress protocol:

  {"protocol":1,"type":"stage","stage":"scan","cancellable":true,"message":"Scanning"}
  {"protocol":1,"type":"result","outcome":"success","message":"Saved","recoveryCommand":null}

  - [x] Emit JSON Lines on stderr when --progress-json is present.
  - [x] Stream progress while commands run.
  - [x] Disable cancellation before commit starts.
  - [x] Support success, noop, cancelled, local-only, and failed.
  - [x] Replace delayed progress parsing with a streaming parser.
  - [x] Implement one queue for every controller process.
  - [x] Prioritize interactive jobs over background refreshes.
  - [x] Coalesce duplicate background jobs.
  - [x] Never discard an accepted user action.
  - [x] Return an explicit queue result.
  - [x] Apply optimistic state only after queue acceptance.
  - [x] Roll back optimistic state after failure or cancellation.
  - [x] Settle each job exactly once.
  - [x] Clear process metadata before the next job.
  - [x] Add explicit transient-view lifecycle functions.
  - [x] Capture tab, filter, mode, selected ID, scroll, and focus.
  - [x] Restore the snapshot after closing Edit or Show Changes.
  - [x] Restore it after Escape and confirmation cancellation.
  - [x] Clear snapshots after successful navigation.
  - [x] Select the nearest row when the old row disappears.
  - [x] Keep errors visible until dismissal or retry.
  - [x] Show local-only commits as pending pushes.
  - [x] Disable only conflicting actions.
  - [x] Preserve keyboard navigation during refreshes.

  Tests:

  - [x] Queue an action during background status.
  - [x] Coalesce repeated refreshes.
  - [x] Cancel before commit and verify no mutation.
  - [x] Reject cancellation after the commit boundary.
  - [x] Close every transient view through every path.
  - [x] Restore exact selection, scroll, filter, mode, and focus.
  - [x] Refresh while a transient view is open.
  - [x] Remove the selected row before restoration.
  - [x] Parse partial, combined, malformed, and delayed progress lines.
  - [x] Render deterministic offscreen screenshots.
  - [x] Compare screenshots with fixed visual fixtures.
  - [x] Test loading, empty, locked, failure, conflict, and local-only states.

  Gate and commit:

  ./tests/gate.sh G7
  ./tests/run-all.sh
  git commit -m "fix: preserve controller and navigation state"

  ## Phase G8: Architecture, Documentation, and Release Review

  - [x] Remove transaction ownership from bin/omarchy-replicant.
  - [x] Keep Git mutations inside the transaction module.
  - [x] Keep legacy policy parsing inside migration code.
  - [x] Remove obsolete v2 write helpers.
  - [x] Remove duplicate scope, profile, registry, and commit logic.
  - [x] Document the v3 schema in docs/SPEC.md.
  - [x] Document transaction recovery in docs/journal.md.
  - [x] Document every key workflow.
  - [x] State that repository secrets use age encryption.
  - [x] Explain that the repository never contains the identity.
  - [x] Document public-repository refusal.
  - [x] Document migration acknowledgement for other machines.
  - [x] Update examples to use migrate-v3.
  - [x] Update screenshots after visual tests pass.
  - [x] Remove inaccurate claims from the previous plan.
  - [x] Verify every public CLI command.
  - [x] Verify every panel action.
  - [x] Verify multi-machine workflows.
  - [x] Set the plugin version to 0.13.0.

  Final gate:

  ./tests/gate.sh G8
  ./tests/run-all.sh
  ./tests/mutate.sh
  ./tests/bench-status.sh --check
  docker build -f tests/Dockerfile -t replicant-tests .
  docker run --rm replicant-tests

  Before the final phase commit:

  - [x] Confirm that no required test was skipped.
  - [x] Run the secret and personal-data scanners.
  - [x] Run git diff --check.
  - [x] Review every remaining change.
  - [x] Mark all completed plan items.
  - [x] Confirm that no AGENTS.md file is staged.

  Commit:

  git commit -m "docs: finalize Replicant v3 verification"

  ## Final Handoff Without Push

  - [ ] Do not run git push.
  - [ ] Do not create a tag or GitHub release.
  - [ ] Confirm that the working tree is clean.
  - [ ] Confirm that the branch is ahead of its upstream.
  - [ ] Show all local implementation commits:

  git log --oneline 4c9c4b580d4d190ea2efd6e0b8449ffd790d091e..HEAD

  - [ ] Show the complete implementation summary:

  git diff --stat 4c9c4b580d4d190ea2efd6e0b8449ffd790d091e..HEAD

  - [ ] Report every test command and result.
  - [ ] Report any environment-only test limitation.
  - [ ] Provide commands for reviewing the complete diff.
  - [ ] Leave the plugin ready for local user testing.
  - [ ] Wait for the user to review and authorize any push.

  ## Assumptions

  - Use schema v3 instead of repairing v2.
  - Support direct migration from v1 and v2.
  - Treat v1 and v2 as read-only before migration.
  - Keep secret paths only inside the encrypted index.
  - Use local remotes instead of network services in tests.
  - Use stubs instead of real privilege escalation.
  - Preserve local commits after push failures.
  - Never push automatically during recovery.
  - Require acknowledgement for every known older machine.
  - Detect legacy artifacts before later v3 mutations.
