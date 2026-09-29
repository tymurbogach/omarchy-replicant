# Contributing

Keep the public plugin separate from the private data repository. Do not add
personal paths, secret values, or machine names to this repository.

Use the single Replicant format. Do not add conversion, compatibility, or
alternate-policy code. Reject invalid repositories before a command reads or
changes their data.

Run `./tests/run-all.sh`, `omarchy plugin validate .`, and `qmllint` for each
changed QML file before you submit a change.

Bump `manifest.json` with every shipped change. A feature,
improvement, or behavior change takes a minor bump. A fix takes a patch
bump. A change under `bin/`, `components/`, `replicant.js`, or any root
QML file always ships, so it always needs a bump in the same commit or
pull request. Docs-only, test-only, or comment-only changes need no
bump. The version must strictly increase and never repeat or go down.
`tests/check-version-bump.sh` enforces this: it fails when shipped code
changes without a higher version. The panel offers updates by comparing
versions, so a change without a version bump never reaches the user.

Keep user-facing text in English. Keep commands safe by default. A command
that overwrites live files must provide a dry run and backups.
