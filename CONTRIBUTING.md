# Contributing

Keep the public plugin separate from the private data repository. Do not add
personal paths, secret values, or machine names to this repository.

Use the single Replicant format. Do not add conversion, compatibility, or
alternate-policy code. Reject invalid repositories before a command reads or
changes their data.

Run `./tests/run-all.sh`, `omarchy plugin validate .`, and `qmllint` for each
changed QML file before you submit a change.

Keep user-facing text in English. Keep commands safe by default. A command
that overwrites live files must provide a dry run and backups.
