# Roadmap

## Completed

- Version 0.13.0 delivered the version 3 repository, transactional saves, bulk operations, and the current panel.
- Version 0.13.1 makes version 2 policy overrides effective and preserves them during migration.
- Version 0.14.0 makes the CLI fail closed for help, locks, core load errors, undo, and unknown states.

## Current

- Version 0.15.0 makes recovery work on v3 repositories, makes the CLI fail
  closed for undo and track options, and makes the panel honest about pending
  scope, locked rows, keyboard reach and result history.
- Complete live installation and placement verification for the usability patch.
- Record the remaining shell restart and interaction evidence in `TASKS.md`.
- Complete deferred panel loading for version 0.14.0. Security cleanup and documentation alignment
  are complete.

## Next

- Keep repository migrations backward compatible and recoverable.
- Improve restore evidence without expanding the public repository format or scope CLI.
