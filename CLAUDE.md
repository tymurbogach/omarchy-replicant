# Omarchy Replicant: plugin code

This is the `omarchy-replicant` repo. It is public, and other Omarchy users install it with
`omarchy plugin add`. It is an Omarchy 4 plugin (Hyprland and Quickshell/QML) that saves a user's
configuration into a private GitHub repo of their own, and restores it on any machine.

This repo holds only the plugin's code, never user data. Each user gets a separate private data
repo, named `<hostname>-replicant` by default (`DEFAULT_REPO_NAME` in `bin/omarchy-replicant`). On
this machine, that repo is `cyberdyne-replicant`. Never mix the two repos. Shipped code names
nothing machine-specific or user-specific: personal entries go into the user's `.replicant-track`.

How the plugin works, and how to change it safely, are in two files that this one imports:

@docs/SPEC.md

@CONTRIBUTING.md

The most important rule is at the top of `docs/SPEC.md`: a question about the system is answered by
asking the system, never by reading a file that this plugin wrote.

## Language rule

Everything in the repo is English, as in the shared Omarchy agent rules. Two additions:

- The rule also covers the user's private data repo, not only this one.
- It has no exception for a user-facing string (a CLI message, a button label, a badge). This is a
  developer's personal tool, not a localised product. `tests/test-usability.sh` fails on letters
  that English does not use.

## Talking with Claude Code

This section is about the conversation, not the repo. The Language rule still applies to everything
that ends up in the repo.

- End each turn with a final summary in simple, plain Spanish (castellano simple).

## Hard rules

1. **Never edit `/usr/share/omarchy/` or `~/.local/share/omarchy`.** Every `omarchy update`
   overwrites them. `is_default_file` also compares against those paths.
2. **A command that writes to the real system is a dry run by default** (`reset-all`, `restore`), and
   it keeps a `.bak.<epoch>` of every file that it overwrites (`install_file`, `install_tree` in
   `bin/lib/tree.sh`). A new writing command follows the same pattern.
3. **`reset-all` (everything to Omarchy's defaults) and `restore --apply --all` (everything to what
   the repo holds) are two separate actions.** Never merge them in the CLI or in the panel.
4. **Verify every visual change to `Panel.qml` or `BarWidget.qml` with a real screenshot** after a
   reload. `repoState.configs[].sync_state` drives the badges. To add a state, trigger it on a real
   test file and look at it.
5. **A global destructive command asks for one summary confirmation**, unless `--yes` is given:
   `reset-all` and `restore --apply --all`. The exception is `install-theme` and `install-plugin`:
   each asks on its own, every time, because fetching a third party's current code is a different
   risk. Do not turn them into one bulk confirmation.
6. **The panel never opens a terminal that the user has to dismiss.** Editing opens the editor, a
   diff renders in the panel, and a destructive action confirms in the panel and runs with `--yes`.
   The exception is `create` and `clone`, which prompt for a login or a URL.
7. **The UI never looks for the CLI on `PATH`.** `omarchy plugin add` runs no install hook. All
   three QML entry points use `Qt.resolvedUrl("bin/omarchy-replicant")`. `link` and `unlink` are the
   opt-in for terminal use. `tests/run-all.sh` fails on a `.qml` file that mentions `local/bin`.
8. **The plugin writes nothing outside its own folder and `~/.local/share/omarchy-replicant/`, and
   `purge` names every trace**, the `.bak.<epoch>` copies included. The list is in `docs/SPEC.md`.
   A feature that leaves something elsewhere adds it to `cmd_purge`.
9. **The restore plan comes from the tracked lists, never from a hand-written list.**
   `plan_for_category` computes it. `tests/test-core.sh` fails if a saved file is in no area's plan.
10. **Restoring is not copying.** Every area declares what runs after it (`apply_for_category`):
    `hyprctl reload` and a config-error check, `omarchy restart terminal`, the theme through
    `omarchy-theme-set`. Do not add an area that copies files and stops.
11. **Never render a secret, and ask the entry, not the file name.** `is_secret_rel` asks
    `TRACKED_SECRETS`, and `repo_copy_for_rel`, `restore_mode_for` and `core_diff` go through it.
    `core_diff` never prints a secret's contents (`.pub` files excepted). The JSON carries a kind,
    a mode and variable names, never values. `tests/test-core.sh` plants a token and greps for it.
12. **Some names are taken.** `state` is a built-in property of every QML Item, and `GROUPS` is a
    bash special variable. Before you name a shell array or a QML property, check that it is free.

## Repo conventions

- The CLI (`bin/omarchy-replicant`) parses arguments, confirms and prints. The logic lives in the
  modules under `bin/lib/`, which `bin/replicant-core.sh` loads. Do not put business logic in the CLI.
- `MANIFEST` and `SECRETS_MANIFEST` are fixed, explicit lists. Do not turn them into auto-discovery:
  the guarantee is that a human decided what is tracked. Found entries have their own rules.
- Adding a setting is one line in `SETTINGS` in `bin/lib/settings.sh`. Give it a `fallback` only
  when the writer can create the key from nothing (the `toml-*` types).
- Hyprland Lua is edited by key, and only when the key appears exactly once. Anything else stays a
  whole-file entry that a person edits in a real editor.
- The plugin does not back up its own source. It records every installed plugin in
  `state/<machine>/omarchy-plugins.txt`.
- Commits to this repo use normal engineering messages. The data repo uses one commit for each
  decision, with the reason.

## Maintaining this file

- This file holds the rules for an assistant. The data model is in `docs/SPEC.md`, and the working
  rules are in `CONTRIBUTING.md`. Put a new fact in the file where a reader looks for it.
- A section earns its place with a bug that cost more than an hour, and that re-reading the code
  would not have prevented. Anything else belongs in a comment beside the code.
- Write the rule first and the story after it, in Simplified Technical English and without dashes.
- A new instance of an existing rule is a row in that rule's table, not a new section.
- When you add something, check whether something else has stopped being true.
