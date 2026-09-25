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

- `./tests/run-all.sh`: passed in 253 seconds.
- QML logic: 59 passed and 0 failed.
- Deterministic screenshots: 8 passed and 0 failed.
- `qmllint`: passed for `Panel.qml` and `components/FileRow.qml`.
- `omarchy plugin validate .`: passed.
- Offscreen Configs captures: reviewed with the row closed and expanded.
