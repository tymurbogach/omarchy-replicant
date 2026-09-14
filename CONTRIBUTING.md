# Working on Replicant

This document describes how to change the plugin safely. `docs/SPEC.md` describes how the plugin
works. The hard rules below apply to every change, by a person or by an assistant. The most
important rule is at the top of `docs/SPEC.md`: a question about the system is answered by asking
the system, never by reading a file that this plugin wrote.

## Two repos

This repo is public, and other Omarchy users install it with `omarchy plugin add`. It holds only
the plugin's code, never user data. Each user gets a separate private data repo, named
`<hostname>-replicant` by default (`DEFAULT_REPO_NAME` in `bin/omarchy-replicant`). Never mix the
two repos. Shipped code names nothing machine-specific or user-specific: personal entries go into
the user's `.replicant-track`.

## Language rule

Everything in the repo is English. Two additions:

- The rule also covers the user's private data repo, not only this one.
- It has no exception for a user-facing string (a CLI message, a button label, a badge). This is a
  developer's personal tool, not a localised product. `tests/test-usability.sh` fails on letters
  that English does not use.

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
- No agent instruction files in the repo (`CLAUDE.md`, `AGENTS.md` and the like). The complete
  checkout becomes the plugin payload, and the marketplace review rejects files that steer coding
  agents. These rules live here instead.

## Keeping these rules

- The data model is in `docs/SPEC.md`, and the working rules are here. Put a new fact in the file
  where a reader looks for it.
- A hard rule earns its place with a bug that cost more than an hour, and that re-reading the code
  would not have prevented. Anything else belongs in a comment beside the code.
- Write the rule first and the story after it, in Simplified Technical English and without dashes.
- A new instance of an existing rule is a row in that rule's table, not a new section.
- When you add something, check whether something else has stopped being true.

## Before you commit

Run the one command that checks everything:

```bash
./tests/run-all.sh
```

It runs the five suites in parallel, then `bash -n`, shellcheck, qmllint, the QML trap guards, the
personal-data guard, the secret scan of the repo, and `omarchy-plugin-validate`. It takes about two
and a half minutes. Each suite prints how many checks it ran, and the last line gives the time.

| Suite | What it covers |
| --- | --- |
| `tests/test-core.sh` | The tracked lists, scopes, states, restore, plugins, the JSON payloads |
| `tests/test-settings.sh` | The settings registry and its writers |
| `tests/test-cli.sh` | The commands, their options, purge, backups, locks, `--help` |
| `tests/test-journey.sh` | Two machines and one repo, from the first save to a pull |
| `tests/test-usability.sh` | What the panel shows: its commands, keys, labels and words |
| `tests/qml/tst_replicant.qml` | The panel's pure logic in `replicant.js`, with `qmltestrunner` (Qt 6) |

While you work, run the suite that covers the change. Keep the full run for the commit.

shellcheck is required, and a missing shellcheck fails the run. Install it without root:

```bash
mise use -g shellcheck@latest
```

## Prove that a test catches the fault

- Write the test first. It must fail on the code before the fix and pass after it.
- To prove the first half, copy the tree, put the old file back in the copy with
  `git checkout -- <file>`, and run the suite there.
- `./tests/mutate.sh` breaks one line of production code in a copy of the repo and runs the suite
  that must notice. It holds the mutations as data, runs four copies at a time, and takes about six
  minutes. `./tests/mutate.sh 7` runs only the seventh.
- Add a mutation for each new guard. A guard that no one has seen fail is a guard that no one tested.
- A mutation whose text is not in its file exactly once fails as stale. When you move code, update
  the `file:` field.

## Continuous integration

`tests/Dockerfile` is an Arch Linux base with the tools that the suites call. The suites run in it
as a normal user, because several checks are about what a user cannot do. The workflow in
`.github/workflows/tests.yml` builds that image and runs `run-all.sh` on every pull request.
`qmllint` and `omarchy-plugin-validate` need Omarchy, so the container reports them as skipped.

The container has none of the files of a desktop, and it runs without `$USER`. Its first runs found
two faults that a development machine could not show. With no `$USER`, the layout wrote an empty
git identity. On a machine without the old personal files, the first `init` stopped with no message.

If a suite passes here and fails in CI, run it with a minimal environment, and hide the files of
this machine that the container does not have:

```bash
bwrap --dev-bind / / --tmpfs /etc/systemd/system \
  env -i HOME="$HOME" PATH=/usr/bin LANG=C.UTF-8 ./tests/test-journey.sh
```

## Rules for tests

- A test must never reach the real machine, the session or the network. `tests/lib.sh` puts a
  failing stub first on `PATH` for `sudo`, `pkexec`, `systemctl`, `hyprctl`, `omarchy`, `gh`,
  `xdg-open`, `notify-send`, `omarchy-theme-set`, `omarchy-restart-shell` and the launchers. A
  suite that needs one of them writes its own stub.
- A test must never open a window on the user's screen. A window that the user closes during a
  test also changes what the command returns.
- No suite may download the marketplace catalog. `tests/lib.sh` points `REPLICANT_CATALOG_URL` at a
  file that does not exist. A test that needs a catalog writes a fixture.
- A test must not depend on the git config of the person who runs it. `tests/lib.sh` points
  `GIT_CONFIG_GLOBAL` at a file with a test identity. A test of the code without any identity sets
  `GIT_CONFIG_GLOBAL=/dev/null`.
- A test must not depend on a file outside its fake `$HOME` that only some machines have, such as a
  unit in `/etc/systemd/system`. Plant a copy in the repo, or pin the answer, as with `is_laptop`.
- A fixture that looks like a credential is a credential to every scanner. Build the prefix from
  pieces (`P_GH="gh""p_"`), and run `bin/scan-secrets.sh tests bin` before you commit.
- `grep -q` in a pipeline under `set -o pipefail` reports failure on success, because the writer
  gets SIGPIPE. Capture the output first, then grep it.
- When a suite sources the core a second time, the core turns `set -e` back on. Put `set +e +u`
  after it, or the first failing command ends the suite with no summary.
- A section named after a guarantee must check that guarantee. Mutation testing found a section
  that passed whether or not the code worked.

## Working on the panel

- Verify every visual change to `Panel.qml` or `BarWidget.qml` with a real screenshot (`grim`) after
  you reload the plugin (hard rule 4). A process that does not crash is not enough.
- If the session is locked or the display is off, render the panel offscreen instead:
  `tests/panel-shot.sh /tmp/p.png configs appearance`. It uses Omarchy's own components and this
  machine's status. It shows the layout, but it does not replace the check after a reload.
- A part in `components/` reaches the panel only through its `panel` property. Where `Panel.qml`
  creates one, pass `panel: root`. Inside another part, pass `panel: <its id>.panel`, because a bare
  `panel: panel` binds the property to itself.
- Put logic that needs no QML in `replicant.js`, and test it in `tests/qml`.
- Follow the design rules below. A tab that builds its own card or row drifts from the others,
  and the panel looks inconsistent although every tab looks fine on its own.

## Design rules for the panel

- Every block of a tab is a `Card`. Its header has an icon, a title and a subtitle, and on the right
  a count and a status. A collapsible card has its chevron on the right edge.
- Every list in a card uses `ListRow`, or `FileRow`, `SettingRow` or `CommitRow`. Each puts its
  glyph in the same 20-pixel column, so the titles line up across cards and tabs.
- A button on a row is a `RowAction`: bordered, small, and with a name. An action on the whole card
  is a full-size bordered button. A flat button is an icon, or a tool at the foot of a tab.
- Do not draw an action that does not apply. A disabled button is a question that the panel does
  not answer.
- One colour, one meaning. The accent is yours and waits for Save. Amber came from another machine,
  or differs from the repo. Red destroys or failed. Green is done. Grey needs nothing.
- One word, one meaning. "Default" is what Omarchy ships, on every tab.
- A tint on a card says that the card asks for something. A value that only differs from a default
  asks for nothing, so its card has no tint.
- The file picker shows **Track** only on the row under the pointer. A list of identical buttons
  hides the names that a person came to read.
- Before `omarchy restart shell`, clear the compiled QML: `rm -rf ~/.cache/quickshell/qmlcache`.
  Quickshell does not reliably invalidate it, and the shell then runs the old code with no error.
- To prove which code runs, add a temporary `Component.onCompleted: console.log("...")` and look for
  it with `journalctl --user | grep`. Remove it before the commit: `run-all.sh` fails on `console.log`.
- Never restart the shell while the session is locked. The Omarchy shell is the lock screen, and a
  restart resets the fingerprint prompt under the user's finger.
- `LockedHint=yes` means locked. `LockedHint=no` means nothing, because a shell that restarted while
  locked never sets it. Check the journal instead:

  ```bash
  journalctl --user --since "60 seconds ago" | grep -q 'pam.subprocess.*omarchy-lock' && echo LOCKED
  ```

- Let `omarchy restart shell` finish. Killed halfway, it leaves the old shell running beside a new one.
- `omarchy-launch-shell` is a supervisor. To remove a second shell, kill the orphan whose parent is 1.
- If `grim` blocks, the display is probably off: `hyprctl monitors -j | jq '.[].dpmsStatus'`.

## QML traps

These produce a half-rendered panel with no error. `qmllint` passes, and the JSON is correct.

- `state` is a built-in property of every QML Item. The data property is `repoState`. Do not add a
  `state` property, and do not write an unqualified `state.`; `run-all.sh` fails on it.
- `Style.spacing.rowPaddingY` does not exist, and it evaluates to `NaN`. Use
  `Style.spacing.controlPaddingY`. When a delegate is blank, log its `width` and `height` first.
- A parent whose height comes from a child that is anchored to the parent's centre is a feedback
  loop. Qt logs `polish() loop`, and the item collapses. Give the row a fixed height, or anchor the
  child to the top.
- A child in a `Row` gets no width of its own. A `BorderSurface` at width 0 draws nothing.
- Write Nerd Font glyphs as code points, `root.mdi(0xF0450)`, with the icon name in a comment. A
  pasted glyph above U+FFFF can become another symbol after a re-encoding. `run-all.sh` fails on one.
- Look at a new glyph before you use it. Coverage says nothing about which icon a code point is:

  ```bash
  F=$(fc-match -f '%{file}' 'JetBrainsMono Nerd Font')
  printf '\U000F0450 F0450\n' > /tmp/g.txt
  magick -background '#101315' -fill '#cacccc' -font "$F" -pointsize 26 label:@/tmp/g.txt /tmp/g.png
  ```

## Measure before you optimise

- Find where the time goes with the shell's own trace:

  ```bash
  PS4='+ ${EPOCHREALTIME} ${FUNCNAME[0]:-main} ' bash -x bin/replicant-core.sh status --json --no-fetch 2> trace.txt
  ```

- Compare the JSON before and after an optimisation. It must be identical.
- Find which files make noise in the data repo before you change an inventory:

  ```bash
  git -C "$REPO" log -200 --name-only --format='' -- . | grep -v '^$' | sort | uniq -c | sort -rn
  ```

## Commits

- One concern for each commit, in English, in the imperative mood.
- Commits to this repo use normal engineering messages. The data repo uses one commit for each
  decision, with the reason. Do not confuse the two.
