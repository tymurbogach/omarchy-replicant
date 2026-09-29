# Tasks

Complete one small, verifiable task at a time. When a task is complete, update its checkbox and
`ROADMAP.md` in the same change.

## Usability patch

- [x] Make `Off` one effective UI state.
  - Project `scopeOverrides` into one row list.
  - Use that list for rows, cards, counters, filters, and bulk selection.
  - Reject bulk Save when any selected row is `Off`.
  - Remove accepted `Off` rows from the selection.
  - Restore the prior state and selection after a command failure.
  - Keep each row available in the All and Off filters.
- [x] Make installation placement explicit.
  - Let the interactive Omarchy command ask for left, center, or right.
  - Use center only as the fallback for a new installation.
  - Document an automated installation with an explicit section.
  - Document `omarchy bar move` for later changes.
  - Preserve the saved section during updates and shell restarts.
- [x] Make each file header look and behave like a disclosure control.
  - Keep a visible border at rest.
  - Use distinct hover, focus, and expanded states.
  - Keep the file name bold and reserve a chevron area.
  - Separate the expanded details from the header.
  - Keep Save and Restore independent from the disclosure click.
  - Preserve keyboard navigation and the full header hit area.
- [x] Align the functional documentation.
  - Explain that `Off` publishes the policy once.
  - Explain that later saves and restores skip the file.
  - Explain that Git keeps the last saved copy.
  - Keep the repository schema and public scope CLI unchanged.
- [x] Add regression coverage.
  - Cover an `Off` row, mixed selection, and optimistic pending state.
  - Cover selection removal and the failure rollback contract.
  - Keep engine coverage for save, restore, and copy exclusions.
  - Check the center manifest default and both README installation paths.
  - Update affected deterministic screenshots.
- [ ] Validate the complete journey.
  - Run `./tests/run-all.sh`, `qmllint`, and `omarchy plugin validate .`.
  - Test a fresh installation in left, center, and right.
  - Move the widget live and inspect `shell.json`.
  - Restart the shell and confirm that the section stays unchanged.
  - Capture Configs with a closed and an expanded file row.
  - Check contrast, hover, focus, keyboard input, and action clicks.
  - Record the evidence before this checkbox is complete.

Automated evidence for the open validation task:

- `./tests/run-all.sh`: passed in 251 seconds.
- QML logic: 59 passed and 0 failed.
- Deterministic screenshots: 8 passed and 0 failed.
- `qmllint`: passed for `Panel.qml` and `components/FileRow.qml`.
- `omarchy plugin validate .`: passed.
- Offscreen Configs captures: reviewed with the row closed and expanded.

## Reliability hardening for 0.14.0

- [x] Make every panel action truthful.
  - Remove `Copy without saving` and `doBackup`. A copy without a commit contradicts the
    transactional model.
  - Change the main Save action to `save --all --auto`.
  - Use distinct jobs and labels for Untrack, Forget, and Remove backups.
  - Replace bulk action identifiers with user-facing descriptions.
  - Show the setup screen only after a successful `{"initialized":false}` response.
  - Show a clear status error and Retry action when the CLI fails or returns invalid JSON.
  - Rename “GitHub HTTPS” to “GitHub API”. Keep API authentication mandatory for repository
    creation.
  - Keep SSH as a Git transport choice. Do not claim that an SSH key can create a GitHub repository.
- [x] Make the CLI fail closed.
  - Ensure `--help` stops execution wherever a command parser accepts it.
  - Preserve `-h` when it is a value, such as `set idle.lock -h` or `save -m -h`.
  - Make lock directory and descriptor failures stop the command with a useful error.
  - Load the core in `undo` without suppressing syntax or source errors.
  - Remove the undocumented `undo -y|--yes` mutation aliases.
  - Render unknown states as warning or unknown, never as saved.
  - Fix the missing parent directory in the editor fixture of `test-cli.sh`.

Completed 2026-09-27. Changed `bin/omarchy-replicant`, `components/FileRow.qml`,
`replicant.js`, `tests/test-cli.sh`, `tests/qml/tst_replicant.qml`, and `tests/mutate.sh`.
Focused checks passed: `test-cli.sh` (305 checks), QML tests, mutations 95 through 99,
`qmllint` for `FileRow.qml`, and `omarchy plugin validate .`. No known remaining risk.
- [x] Finish the compatibility transition.
  - Make plugin settings and reset counts consume `entries`, not `configs` or `secrets`.
  - Remove the deprecated `configs` and `secrets` fields from full status after all internal
    consumers and fixtures use `entries`.
  - Remove `savegame`, `backup`, `migrate-v2`, `sync`, and `init --savegame`.
  - Update every panel command, help entry, test, fixture, and document to use `save`, `changes`,
    `migrate-v3`, and `scope`.
  - Return an explicit error with the canonical replacement when a removed alias is used.

Completed 2026-09-28. Changed the CLI, status payload, panel row consumers, fixtures, documentation,
and compatibility tests. Focused checks passed: `test-cli.sh`, `test-save.sh` (77 checks),
`test-migration.sh` (27 checks), `test-schema.sh` (54 checks), QML controller tests (62 tests),
`test-usability.sh` (84 checks), `test-g8.sh`, and the deterministic screenshot renders. No known
remaining risk in this transition.
- [x] Close security and cleanup gaps.
  - Detect classic and post-quantum age identities in `scan-secrets.sh`.
  - Add scanner fixtures without storing a complete real identity in the repository.
  - Make `purge` name every retained and removed path.
  - Keep the repo, keys, legacy repos, and migration recovery data during normal `purge`.
  - Remove all of them only with `purge --repo`, after the existing key warning.
  - Test interrupted migration directories, `migration-warning`, identities, and legacy
    repositories.

Completed 2026-09-28. `scan-secrets.sh` detects classic and post-quantum age identities without
storing one in the repository. `purge` separates removable paths from retained recovery data and
includes keys, migration journals, warnings, and legacy repositories only with `--repo`. Focused
checks passed: `test-cli.sh`, `test-save.sh` (77 checks), `test-migration.sh` (27 checks), and
`test-migrate-v3.sh` (83 checks). No known remaining risk in this block.
- [ ] Reduce panel startup cost.
  - Keep the full status request independent from the controller queue.
  - Load setup status only when no repository exists.
  - Load suggestions when the Configs tracking UI first needs them.
  - Load backups and deleted history when the Restore tab first opens.
  - Load shortcuts when keyboard help first opens.
  - Give each deferred card an explicit loading, error, empty, and Retry state.
  - Measure initial display and complete hydration before and after the change.
  - Keep the documented metadata-cache limit for same-size, same-`mtime` edits.

Current evidence for the open task:

- `tests/test-usability.sh`: 92 checks passed.
- `tests/qml-controller.sh`: 62 checks passed.
- `qmllint` passed for the changed QML files, and `omarchy plugin validate .` passed.
- Offscreen Configs captures passed for a closed panel and an expanded `hyprland` card.
- `tests/bench-status.sh --check`: full and brief status both measured 30 ms in the isolated fixture.
- `./tests/run-all.sh`: all suites and static checks passed in 97 seconds.
- Live installation from GitHub loaded commit `fc17daf` without plugin warnings.
- Live placement checks passed for left, center and right. Live moves passed in both directions.
- Shell restart preserved `bar.layout.center.5.id` in `shell.json`.
- A real 3072x1920 Configs capture was reviewed after the restart.
- Mouse clicks, keyboard input and subjective contrast checks remain open for human review.
- [x] Align documentation with behavior.
  - Document the Restore action for incoming rows.
  - Remove the obsolete 0.5 upgrade note.
  - Stop telling v3 users that their entries live in `.replicant-track`.
  - Add `crypto.sh`, `state.sh`, `legacy.sh`, and `progress.sh` to the module table.
  - Document keys and migration recovery data in the trace inventory.
  - Replace the fixed “five suites” count with wording derived from `tests/run-all.sh`.
  - Document the 0.14 CLI removals and GitHub API requirement.
  - Leave the current TASKS and ROADMAP validation item open until its live checks exist.

Completed 2026-09-28. Updated the incoming-row Restore wording, removed the obsolete 0.5 note,
documented the v3 entry locations, added the current shell modules and recovery paths, described
the 0.14 CLI removals and GitHub API requirement, and derived the suite count from `run-all.sh`.

### Public interfaces

- `save --all --auto` becomes the main panel save command. `save-file <id>`,
  `bulk save`, `set` and `revert` remain for single entries and settings.
- The five deprecated CLI surfaces are removed in 0.14.0.
- Full `status --json` keeps `entries` as its only row collection. The repository
  has one format.
- `purge` output separates removed paths from retained recovery data.
- Panel status gains explicit loading and failure states. CLI failure no longer means “not
  initialized.”

### Test and acceptance plan

- Treat each top-level checklist item as one bounded work session. Record the changed files,
  focused test results, and remaining risks before starting a new session.
- Add regressions for invalid status JSON, missing CLI, non-leading help flags, lock creation
  failure, visible core load errors, and rejected `undo --yes`.
- Add entries-only tests for plugin rows and reset counts.
- Add scanner tests for `AGE-SECRET-KEY-1…` and `AGE-SECRET-KEY-PQ-1…`.
- Add purge tests for default retention and complete `--repo` removal.
- Add QML tests for friendly bulk text, correct result labels, unknown states, and lazy job
  activation.
- Prove each new guard with a mutation where practical.
- During each checklist item, run only its affected suites and focused mutations.
- Run `qmllint` on changed QML files and validate the plugin after each substantive plugin change.
- After each visual change, reload the plugin and inspect one real screenshot of the affected view.
- Do not repeat the complete suite, the full screenshot set, or the from-zero plugin cycle after an
  individual checklist item.
- After all top-level checklist items are complete, run `./tests/run-all.sh`, the full deterministic
  screenshot set, and the required from-zero live plugin cycle once.

### Assumptions

- This work targets version 0.14.0 because it removes public CLI compatibility.
- Repository creation does not use an SSH key without GitHub API authentication.
- The public copy operation without a commit does not return.
- Normal `purge` keeps all data needed to recover the repository or secrets.
- The documented brief-cache limitation remains.

## Examen exhaustivo 2026-09-29

Origen: revision de codigo, logica y docs. Sin cambios aun.
Ejecutar por bloques. Un bloque es una sesion pequena y verificable.

### Bloque 0 - Registrar
- [x] Anadir esta seccion a `TASKS.md`.
- [x] Verificar: `git diff -- TASKS.md` solo tocaba esta seccion al registrar.

### Bloque 1 - Critico
- [x] `Panel.qml:814-823`: copiar directo con `wl-copy --`, sin `sh -c`.
- [x] `tests/run-all.sh`: corre static + suites sin gate + gates G0-G8 + bench + validate + qmllint.
- [x] `bin/lib/incoming.sh`, `briefcache.sh`: bar y cache leen `REGISTRY`.
- [x] `bin/lib/scopes.sh`: `normalize_profile_name` para el fallback por hostname.
- [x] `bin/lib/repo.sh`: `create` con journal (`tx_shape_begin/commit`), push con `-u`, journal kept al fallar.
- [x] Verificar: bootstrap 50/50, transaction 73/73, usability 99/99, format ok, qmllint ok.
  Nota 2026-09-29: `test-state` (36/89), `test-save` (32/75) y `test-cli` (44/317)
  fallan IDENTICO en main limpio (suites con fixtures v1/v2 retirados). No es
  regresion. `run-all.sh` queda en rojo hasta sanear esas suites (Bloque 3).

### Bloque 2 - Alto
- [x] Journal en `purge`: `key-rotation.json` en recovery (se conserva sin
  `--repo`, se elimina con `--repo` dentro de `REPLICANT_HOME`).
- [x] Regla `secret+profile` unica en `scope_store` (bulk ya la tenia).
  Verificado: `scope <secret> profile` falla, `off` funciona.
- [x] `move_repo_copy` aparta el destino y restaura si `mv` falla.
  Verificado: roundtrip shared->profile->shared intacto, 0 restos.
- [x] Lock por `wants_apply` (token exacto, gana el ultimo).
  Verificado: `purge/backups --dry-run` no crean lock.
- [x] Teclado: `R.keyboardActionFor` (missing/incoming->restore,
  locked->mensaje de clave, resto->save) + test QML nuevo.
- [x] Bulk con locked: aviso en `BulkFooter` (bloquear sigue, ahora explica).
- [x] `SPEC.md` ampliado al formato que valida el codigo + bump a 0.16.1.
- [x] Tags locales v0.14.0, v0.15.1, v0.16.0 (NO pusheados).
- [x] Verificar: qmllint todo ok, `plugin validate` ok, qml 65/65,
  bootstrap 50/50, transaction 73/73, usability 99/99, crypto sin
  regresion (1 fallo previo identico), core sin regresion (104 previos,
  difieren solo version+hash).

### Bloque 3 - Medio
- [x] `status`: memo de `tree_files` (+invalidacion en copia), memo de
  `vault_blob_same` por fingerprint, y full JSON deriva numeros de `entries`
  (una evaluacion por fila). Medido: 8.5s -> 6.5s en fixture de 200 ficheros;
  `bench --check` pasa (0.07/0.25, 0.08/0.10). `settings` (1.8s) queda follow-up.
- [x] Cola con envejecimiento: `queuedAt` + `queueNextIndex` (15s) en
  `dispatchNext`; backgrounds son solo lectura. Tests QML nuevos. 67/67.
- [x] Scanner en un paso: un `grep -r` combinado + atribucion; path conserva
  aviso de binarios (antes duplicado x25). Fuga real cerrada: `--stdin`
  imprimia la credencial sin redactar. 17/17 shapes, sin falsos positivos.
- [x] Timeouts (10s) en `gh` de doctor/setup-status y `omarchy menu keybindings`.
- [x] Tiempos rancios a cualitativo (BarWidget, Service, incoming). Conteos
  README verificados correctos (43+3=46, 11 areas, 24 settings).
- [x] Shellcheck limpio: SC2106 fail-closed en recover, SC2155 split,
  SC2088 suprimido con motivo (literal "~").
- [x] Verificar: bench ok, bootstrap 50/50, transaction 73/73, usability
  99/99, leaks 18/18, interruptions 12/12, qml 67/67, crypto 1 previo
  identico, qmllint todo ok, validate ok. Bump a 0.16.2.

### Bloque 4 - Bajo
- [ ] `selectionSummary`, iconos, `derive_rel`, `suggest`, `update`, `purge`.
- [ ] Verificar: suite tocada y captura si hay UI.
