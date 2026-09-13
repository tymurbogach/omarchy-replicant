# Working on Replicant

This document describes how to change the plugin safely. `docs/SPEC.md` describes how the plugin
works. The rules in `CLAUDE.md` apply to every change, by a person or by an assistant.

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
- A part in `components/` reaches the panel only through its `panel` property. Where `Panel.qml`
  creates one, pass `panel: root`. Inside another part, pass `panel: <its id>.panel`, because a bare
  `panel: panel` binds the property to itself.
- Put logic that needs no QML in `replicant.js`, and test it in `tests/qml`.
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
