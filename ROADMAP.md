# Roadmap

A checklist of fixes, tests and cleanups from the review of 2026-09-12 (commit `2770a68`).
Tick an item when its fix is merged and its test is in the suite.

## How to use this list

- Work on one item per branch and pull request.
- Write the test first. It must fail on `main` before the fix and pass after it.
- While you work, run the suite that covers the item. Run `./tests/run-all.sh` before the commit.
- If an item turns out to be wrong, strike it through and add one line that says why. Do not delete it.

Priorities:

- **P0**: the plugin gives a wrong answer or loses data. Each one was reproduced.
- **P1**: a gap in safety or correctness. Each one was confirmed by reading the code.
- **P2**: tests and structure. These make the next bug cheaper to find.
- **P3**: docs, process, performance and polish.

Baseline: `./tests/run-all.sh` passes with 905 checks in 5 min 14 s. The repo has no CI.

## P0: bugs reproduced in a throwaway `$HOME`

- [x] **B1. `root_apply` reports success when it changed nothing.**
  `bin/replicant-core.sh:2142` returns `${rc:-1}`. `rc` starts at `0`, so the path where nothing
  can ask for root returns 0. `set lid.close ignore` then prints `Closing the lid -> ignore` and
  exits 0, and the panel shows no failure. Omarchy ships no polkit agent, so this is the common path.
  - Fix: return 1 on that path.
  - Test: stub `sudo` to fail and unset the session variables. Expect a non-zero exit from
    `root_apply` and from `set`.

- [x] **B2. The manual `sudo install` command names a file that no longer exists.**
  `root_apply` prints `sudo install -D -m 644 /tmp/replicant-lid.XXXXXX ...`. Then `ini_set` deletes
  that staged file (`bin/replicant-core.sh:2170`).
  - Fix: if root is not available, keep the staged file under `$REPLICANT_HOME/staged/`.
    List that directory in `cmd_purge` (hard rule 8).
  - Test: after a failed apply, the printed path exists and holds the new value.

- [x] **B3. `savegame` says "Everything saved and pushed." when nothing was pushed.**
  `bin/omarchy-replicant:220-237`. With no upstream, the push is skipped. When the push fails, the
  failure is ignored. A rejected push is an example, because another machine pushed first. Both
  cases print the same sentence and exit 0. With two machines on one repo, the rejected push is the
  normal case.
  - Fix: record the push result. If the push failed, say "committed, not pushed" with the reason,
    and exit non-zero.
  - Test: a repo with no remote. A bare remote that is one commit ahead.

- [x] **B4. `source "$CORE"` runs the dispatcher of the core with the caller's `$1`.**
  A sourced file sees the positional parameters of the function that sources it.
  `omarchy-replicant path machine` prints the hostname, then "unknown id". `track backup` runs
  `core_backup`. The fix in `cmd_install_theme` (`source "$CORE" ""`) is local. `resolve_src`
  (`path`, `edit`), `cmd_reset`, `cmd_get`, `cmd_set`, `cmd_sync`, `cmd_scope`, `cmd_track`,
  `cmd_untrack`, `cmd_profile`, `cmd_restore_file`, `cmd_settings` and `cmd_doctor` still have the bug.
  - Fix: guard the dispatcher at `bin/replicant-core.sh:3855` with
    `[[ "${BASH_SOURCE[0]}" == "$0" ]]`. Then remove the `""` workaround.
  - Test: `path machine` prints only the "unknown id" error.

- [x] **B5. `restore --only` with an unknown area reports success.**
  `restore --apply --yes --only hyperland` prints `restore complete` and `0 files written`.
  `cmd_restore` also accepts any unknown option (`bin/omarchy-replicant:500`, `*) shift;;`).
  - Fix: reject an `--only` value that `find_category` does not know. Reject unknown options, as
    `cmd_reset_all` does.
  - Test: both cases exit non-zero and name the valid areas.

- [x] **B6. `lid.closeDocked` offers `ignore` twice.** `bin/replicant-core.sh:2083`.
  - Fix: remove the duplicate.
  - Test: `tests/test-settings.sh` fails when an enum setting has a duplicate option.

## P1: gaps confirmed by reading

- [x] **C1. `revert` does not commit a profile-scoped setting.**
  `revert` stages only `config/` (`bin/omarchy-replicant:980`). If the file of the setting is
  profile-scoped, the revert is never committed. The README example
  `scope hypr/input.lua profile` causes this. `set` commits every pending file together with the
  setting. That is intended (owner decision, 2026-09-12).
  - Fix: make `revert` commit through `savegame -m`, as `set` does. Then both commands follow one rule.
  - Test: the revert of a profile-scoped `input.lua` lands in a commit.

- [x] **C2. Setting edits delete restore backups.**
  `backup_before_write` keeps three `<file>.bak.*` files and deletes the others
  (`bin/replicant-core.sh:2303-2311`). The glob also matches the backup that `install_file` makes
  during a restore, and the backups that `omarchy refresh config` makes. After a restore, three edits
  to one setting delete the undo for that restore.
  - Fix: prune only the backups that this function wrote. For example, record them in
    `$REPLICANT_HOME` and prune from that list.
  - Test: restore a file and change its setting four times. `undo` still finds the restore backup.

- [x] **C3. The secret scan at backup time skips profile-scoped files.**
  `core_backup` scans only `config/` and `state/<machine>/` (`bin/replicant-core.sh:1734`).
  The pre-commit hook catches the file later, but only if the hook runs (see C4).
  - Fix: also scan `profiles/<profile>/config/`.
  - Test: put a token in a profile-scoped file. `backup` fails.

- [x] **C4. The pre-commit hook fails open and is never updated.**
  The hook exits 0 when it cannot find the scanner. `ensure_repo_layout` writes the hook once
  (`bin/replicant-core.sh:1378`) and never again. The scanner beside it is kept up to date.
  - Fix: refresh the hook the same way as `scan-secrets.sh`. If the scanner is missing, block the commit.
  - Test: the next `backup` replaces an old hook. A missing scanner blocks a commit.

- [x] **C5. `clone` ignores its own URL check.**
  `command -v omarchy-git-url-check && omarchy-git-url-check "$url" || true`
  (`bin/omarchy-replicant:466`) continues when the check refuses the URL.
  - Fix: stop when the check fails.
  - Test: `clone 'ext::sh -c true'` exits non-zero and creates no directory.

- [x] **C6. The System area describes an action that does not occur.**
  Its method text is "Copied back with sudo, then systemctl daemon-reload"
  (`bin/replicant-core.sh:338`). `restore` never writes outside `$HOME`. It prints a `sudo`
  command (`bin/omarchy-replicant:610-618`), so `daemon-reload` never runs.
  - Fix now: make the text say what occurs. After B1 and B2: write through `root_apply`.
  - Test: the method text of each category matches what `cmd_restore` does for it.

- [x] **C7. Some commands that write do not take the repo lock.**
  The lock list (`bin/omarchy-replicant:1686`) does not include `purge` (with `--repo` it deletes
  the repo), `undo`, `backups --prune`, `install-theme` or `install-plugin`.
  - Fix: add them.
  - Test: while the lock is held, each command waits or fails with the lock message.

- [x] **C8. Personal data in shipped code.**
  The project rule is that shipped code names only what any Omarchy machine plausibly has.
  - `/etc/samba/credentials-pi` and `/etc/samba/credentials-nas` (`bin/replicant-core.sh:1588`).
  - Copies from `~/omarchy_thinkpad` (`bin/replicant-core.sh:1373-1427`).
  - `savegame` prints "(omarchy_thinkpad Rules 2 and 3)" to every user (`bin/omarchy-replicant:227`).
  - `bin/pacman-delta-ignore:2` names `bin/install-paquetes.sh`. The name is Spanish, and the
    script does not exist.
  - `bin/scan-secrets.sh:10` points to "CLAUDE.md § Rule 0". That rule does not exist.
  - Verify `~/.claude/.mcp.json` in `MANIFEST`. Claude Code keeps user MCP servers in
    `~/.claude.json`. MCP configs often hold tokens that the scanner has no pattern for, so track the
    file as a secret or remove it.
  - Fix: remove these names. Add the guard that the 2026-09-05 plan described, which is not in
    `run-all.sh`. It fails on `omarchy_thinkpad`, `credentials-pi` and `/home/`.
  - Test: plant each name once and confirm that the guard fires.

- [x] **C9. The list of keyboard layouts is fixed.**
  `input.kbLayout` offers `es,us,gb,de,fr,it,pt,latam` (`bin/replicant-core.sh:2072`). If a user
  has another layout, or two layouts (`us,ru`), the control cannot show or keep the value.
  - Fix: get the options from `localectl list-x11-keymap-layouts`, and always include the current value.
  - Test: a current value that is not in the list is available and survives a write and a read.

- [x] **C10. Follow-ups from 0.8.0.**
  - `doctor` reports an installed plugin as edited when its files match a pushed commit but its
    HEAD is behind (`edited_plugins` works offline). Compare the working tree with the upstream
    tree first.
  - `install-plugin`: show the marketplace verification (`verificationCommit` from
    `plugins.omarchy.org/catalog.json`), as Omaplug does.
  - When you restore only Hyprland, `hypr/omasettings.lua` comes back without its store,
    `plugins/omasettings.json`.

## P2: tests

- [x] **T1. Add a regression test for every P0 and P1 item** before its fix.
- [x] **T2. Add direct tests for risky functions that no test names.**
  `root_apply`, `backup_before_write`, `ini_set`, `toml_set` and `lua_set` (a comment after the
  value, a trailing comma, a key in two tables). Also `hypr_in_force` and `hypr_overrider` with a
  `hyprctl` stub, the four branches of `resolve_plugin_origin`, `core_incoming` (it ignores the
  files of other profiles) and `should_fetch`. Some of these run indirectly today. A direct test
  says which one broke.
- [x] **T3. Make a real system call fail by default.**
  In `tests/lib.sh`, put stubs first on `PATH` for `systemctl`, `hyprctl`, `omarchy`, `pkexec`,
  `sudo`, `xdg-open` and `omarchy-launch-editor`. Each stub logs the call and exits non-zero. A test
  that needs one of them opts in. Then two past incidents cannot occur again: a real logind reload,
  and nvim on the user's screen.
- [x] **T4. Run the suites in a container.**
  A `Dockerfile` (Arch base with bash, git, jq and shellcheck) runs the core, settings, CLI and
  journey suites. `qmllint` and `omarchy-plugin-validate` stay on the host.
- [x] **T5. Add CI.** A GitHub Actions workflow runs T4 on every pull request. Today, "Everything
  passed" means that the suite passed on one laptop.
- [x] **T6. Run the suites in parallel.**
  Each suite has its own temporary `$HOME`. Verify that first, then start the suites as background
  jobs in `run-all.sh`. Measure each section before you change it: the table in `CLAUDE.md` adds up
  to about 2 min 13 s, and the full run took 5 min 14 s.
- [x] **T7. Script the mutation tests.**
  `CLAUDE.md` describes mutation testing as a manual routine. Put the mutations in
  `tests/mutate.sh` as data (file, pattern, replacement). The script applies each mutation to a copy
  and runs the suites. It fails if a mutation survives.
- [ ] **T8. Add unit tests for the panel logic.**
  Move the pure functions (`stateGlyph`, `stateColor`, `stateWord`, `summary`, `advice`,
  `backupRows`, `agoText`, `nextScope`, `rowsFor`) from `Panel.qml` to a `.js` file that
  `Panel.qml` imports. Test that file with `qmltestrunner`, which is at `/usr/bin/qmltestrunner`.
  Layout still needs a screenshot (hard rule 4).

## P2: structure

- [x] **S1. Split `bin/replicant-core.sh`** (3,881 lines, 143 functions) into modules under
  `bin/lib/`: the tracked list and the user list, scopes and profiles, trees, install and backups,
  the settings registry and its writers, the status JSON, the restore plan, the plugin and theme
  inventory, and diff and log. The core keeps the dispatcher and sources the modules. Move code
  only. Use one module per commit, and keep the full suite green after each commit.
- [x] **S2. Make the dispatcher a `case` statement** behind the source guard from B4.
- [x] **S3. Move business logic from the CLI to the core.**
  The project convention says that the CLI parses arguments and prints output. Today the CLI holds
  the full restore loop (`cmd_restore`, 190 lines, with `restore_themes`, `restore_theme` and
  `restore_plugins`). It also holds the candidate selection of `reset-all`, the copy in `save-file`,
  the checks in `doctor` and `auto_commit_subject`.
- [ ] **S4. Split `Panel.qml`** (2,537 lines, eleven inline components) into one file for each
  component (`FileRow`, `SettingRow`, `CategoryCard`, `SuggestCard`, `RestoreCard` and the others).
  Clear the QML cache and take a screenshot after each move.
- [ ] **S5. Keep one definition of each shared fact.**
  The shell part is done: `bin/lib/common.sh` holds `plural` and the machine name for the CLI and
  the core. The QML part is left: `plural` and `mdi` in the two QML files, the CLI path, and the
  panel IPC. It needs a screenshot (hard rule 4).
  - `plural`: `bin/omarchy-replicant:39`, `bin/replicant-core.sh:44`, `BarWidget.qml:62` and
    `Panel.qml:193`. `bin/omarchy-replicant:459` builds the plural by hand again.
  - `mdi`, and the CLI path with the same seven-line comment, in three QML files. A shared `.js`
    file removes both.
  - The machine name: `hostname -s` in the CLI (`bin/omarchy-replicant:25`) and
    `hostnamectl --static` in the core (`bin/replicant-core.sh:20`). The two can differ.
  - The panel IPC: `Panel.qml:30` (`replicant`) and `BarWidget.qml:229`
    (`omarchy-replicant-panel`) both open the panel. Keep one and document it.
- [x] **S6. Remove dead or misleading code.**
  - The CLI fallback to `/usr/share/omarchy/bin/replicant-core.sh` (`bin/omarchy-replicant:12`).
    Nothing installs the core there.
  - `diff --terminal` (`bin/omarchy-replicant:344`). It uses the floating terminal and needs the CLI
    on `PATH`, against hard rules 6 and 7. The panel does not use it.
  - `pull -y` from the panel (`Panel.qml:372`). `pull` takes no options.
  - `init --savegame` in the "not initialized" message (`bin/replicant-core.sh:3206`). The flag does
    nothing.
  - `.ssh/id_*` and `.ssh/*.pem` in the `.gitignore` of the data repo. Secrets never go to `.ssh/`
    in that repo.
- [x] **S7. Declare the locals in `core_backup`.**
  `copied`, `missing`, `scopied`, `entry`, `src`, `rel`, `dst`, `known`, `name`, `d` and `SCAN`
  leak into the scope of the caller. Bash scopes dynamically, and `CLAUDE.md` documents a bug of
  this class.
- [x] **S8. Let a broken core fail loudly.**
  Each `source "$CORE" 2>/dev/null || true` hides a syntax error or a missing file. The next line
  then fails with a message that points to the wrong place.

- [ ] **S9. Show the marketplace facts in the panel before an install.**
  `install-plugin <id> --check` prints them (C10), but the Install button in the panel still asks
  for consent without them. Run `--check` when the button is pressed, and put its output in the
  confirmation. Take a screenshot after the change (hard rule 4).

## P3: docs and process

- [ ] **D2. Remove `docs/superpowers/plans/`.** The two files are finished internal work plans,
  not user docs. Their result is in the commits.
- [ ] **D3. Split `CLAUDE.md` (731 lines).**
  Its own section "Maintaining this file" says that 600 lines was already too long. Move "How the
  data works" to `docs/SPEC.md`, because the Omarchy rules ask for a SPEC when the logic is
  non-trivial. Move the traps to `CONTRIBUTING.md`. Keep `CLAUDE.md` short, with pointers. Point
  "Notes for contributors" in the README to `CONTRIBUTING.md`.
- [ ] **D4. Write docs and comments in Simplified Technical English.**
  More than 700 lines in tracked files contain an em dash. Many comments tell history ("It used
  to...", "This cost hours..."). Keep the rule and the reason in the comment, and move the story to
  the commit message.
  - Rewrite `README.md` and `docs/getting-started.md` in one pass.
  - Rewrite code comments only in files that a change already touches. One rewrite of about 5,600
    lines of commented code has high risk and low value.
  - Add a guard that fails on a new em dash in `README.md`, in `docs/` and in commit subjects.
- [ ] **D5. Correct `docs/getting-started.md`.**
  Line 57 says that the bar shows the GitHub mark when everything is saved. The bar shows
  `hexagon-multiple` (`BarWidget.qml:32-35`). Line 65 names only one of the two IPC targets (see S5).
- [ ] **D6. Add the marketplace headings to the README.**
  The Omarchy rules ask for Install, Usage, Configure, Remove, Requirements and License. The README
  has Requirements and "Removing it". Install is a code block with no heading, and License is one line.

## P3: performance (measure before and after)

- [ ] **F1. Run one full `status` when the shell starts, not two.**
  `Service.qml` and `BarWidget.qml` both run a full `status --json` at start, and each run costs
  about 1.4 s of CPU. Make the service ask for `--brief`, or use the answer of the bar.
- [ ] **F3. Look up scopes without a fork in the loops over every row.**
  Measured on 2026-09-13 with 60 rows: `status --json --brief`, which the bar runs every minute,
  takes about 0.9 s, and more than a third of it is `$(scope_for ...)` and `$(repo_path_for ...)`,
  one fork per call, in `count_changes` and `build_configs_json`. Add forms that write into a
  variable (`printf -v`) and use them in those two loops. Do it after S1, so that it changes one
  module and not the whole core.

- [x] **F2. Remove small forks from the status path.**
  `core_status` runs `git status --porcelain` twice (`bin/replicant-core.sh:3219-3220`).
  `build_setting_groups_json` runs `cut` for each field and `jq` for each group, unlike the other
  builders.
