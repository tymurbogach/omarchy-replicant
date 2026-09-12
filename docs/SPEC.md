# How Replicant works

This document describes the data model of the plugin and the rules that the code follows.
`CONTRIBUTING.md` describes how to change the code safely. `CLAUDE.md` holds the rules for an AI
assistant, and it imports both files.

## The code

- `bin/omarchy-replicant` is the CLI. It parses arguments, asks for confirmation and prints. It holds
  no business logic.
- `bin/replicant-core.sh` sets the paths, sources the modules in `bin/lib/`, loads the tracked
  lists, and runs the command that it receives.
- `bin/lib/*.sh` hold the logic, one concern for each module. A module defines functions and data,
  and it runs nothing when it is sourced.
- `bin/lib/common.sh` holds what the CLI and the core both need: `plural` and the machine name.
- The QML files (`BarWidget.qml`, `Panel.qml`, `Service.qml`) run the CLI and read its JSON.

| Module | What it holds |
| --- | --- |
| `manifest.sh` | The shipped lists, the user's list, Omarchy's defaults, the repo version guard |
| `categories.sh` | The areas that the panel files every entry under |
| `scopes.sh` | Profiles, and whether each file is shared, kept per profile, or off |
| `track.sh` | Writing the user's list: `track` and `untrack` |
| `suggest.sh` | Proposing files that nothing tracks yet |
| `incoming.sh` | What another machine changed, and what differs on this one |
| `backups.sh` | The `.bak.<epoch>` safety net, `undo`, and the backups that setting edits make |
| `tree.sh` | Writing files and directory trees, with a backup of what they replace |
| `layout.sh` | The repo layout, the pre-commit hook, and the backup itself |
| `gitstate.sh` | One git call for the state of every row |
| `discover.sh` | Entries found rather than listed: plugin configs and Hyprland modules |
| `settings.sh` | The settings registry, its readers and its writers |
| `status.sh` | The JSON that the panel and the bar read, the diff and the log |
| `restore.sh` | The restore plan for each area, and how each area is put back |
| `plugins.sh` | Plugins and themes: origins, inventories, and installs on request |

Rules for the code:

- The core runs its dispatcher only when it is executed. A sourced file sees the positional
  parameters of its caller, so a guard stops a caller's `$1` from running a command.
- The CLI loads the core with `load_core`. If the core cannot load, the command stops with a message.
- Every top-level associative array uses `declare -gA`. The CLI sources the core inside a function,
  and a plain `declare` there makes a local of that function.
- Every variable in a function is `local`. Bash scopes dynamically, so a leaked name changes the
  caller. A test compares every global name before and after a backup.

## One rule above the others

> A question about the system is answered by asking the system. It is never answered by reading a
> file that this plugin wrote.

A value read back from a file that this plugin wrote reports intent, not effect. The two agree until
something else has an opinion. Each row below shipped as a bug, and each looked correct in review.

| The question | The artifact that lied | What answers it |
| --- | --- | --- |
| Has this file changed? | `git status` on the repo copy | `entry_differs`: `cmp` against the live file |
| Does this machine have unsaved work? | `repoState.dirty` | `count_changes`, the rows that the panel counts |
| What does closing the lid do? | `99-lid.conf`, which this plugin wrote | logind: a `block` inhibitor makes the file inert (`lid_blocked_by`) |
| Which theme is on? | The name saved in the repo | `omarchy-theme-current`, compared normalised |
| Is the session locked? | `LockedHint` | The lock's own PAM session in the journal |
| Where does this file's copy live? | A path built on the spot | `repo_copy_for_rel`, through `is_secret_rel` and `repo_path_for` |
| What does the Hyprland config consist of? | The Hyprland names in `MANIFEST` | Its own `require("hypr.…")` lines (`discover_hypr_modules`) |
| Which plugins' settings belong in the repo? | The plugins installed on this machine | Every machine's `omarchy-plugins.txt` (`discover_kept_plugin_configs`) |
| Which Input value does Hyprland use? | The key in `input.lua` that this plugin wrote | `hyprctl getoption` (`hypr_in_force`): a module loaded later wins |
| Is a plugin's work upstream? | `refs/remotes/origin/*` | Those and `FETCH_HEAD`: `omarchy plugin update` never moves the remote refs |
| Did the save reach GitHub? | "Everything saved and pushed." | The result of the push itself (`push_pending`) |

## Two machines, one repo

The plugin is built for a desktop and a laptop that share one private repo.

- `state/<machine>/` holds the inventory of each machine. A shared `state/` made each machine
  overwrite the other's package list on every save.
- A profile is claimed, never assumed. `guess_profile` asks the chassis, so every laptop guesses
  `laptop`. On the first save, `ensure_profile_recorded` writes the resolved name into
  `.replicant-profiles`.
- A role is taken when another machine is recorded under it, or when its tree exists and another
  machine has saved into this repo. Then the new machine uses its hostname, which is unique. The
  function only assigns: a machine that has a profile keeps it.
- Every tracked file has a scope in `.replicant-sync`: `shared`, `profile` or `off`. The file is in
  the repo, because "monitors are machine-specific" is a fact about the setup, not about one machine.
- `profile` stores the copy under `profiles/<profile>/config/<rel>`, so each profile keeps its own
  copy. `hypr/monitors.lua` starts as `profile`. Switching a file off means that nobody gets a backup.
- `repo_path_for` is the only function that knows where a copy lives. The copy pass, the prune pass,
  the restore plan and "revert to repo" all call it. `repo_copy_for_rel` adds the secrets directory.
- The prune pass sweeps `config/` and this profile's tree only. From here, another machine's profile
  tree looks untracked, and pruning it would delete that machine's only backup.

## The tracked lists

- `MANIFEST` and `SECRETS_MANIFEST` are public plugin source. They name only the paths that any
  Omarchy machine plausibly has. Nothing machine-specific goes into them, and `run-all.sh` fails on
  a personal path or name in `bin/`.
- `.replicant-track` in the user's repo holds the user's own entries. It lives in the repo, because
  "back up my script" is a decision about the setup.
- `rebuild_tracked` joins the shipped list, the user's list and the found entries into `TRACKED`
  and `TRACKED_SECRETS`. Every loop that means "everything tracked" reads those two arrays.
- `load_user_manifest` has a read-only fallback, and `ensure_track_file` does the migration. Without
  the fallback, the first command after an upgrade would see a 0.6 repo's copies as untracked.
- A shipped entry that exists neither here nor in the repo draws no row. An entry that the repo
  holds a copy of always shows, because "it was here and now it is not" must not be hidden.
- `untrack` refuses a shipped entry and says to use `scope <id> off`. Untracking removes the row and
  the repo copy, so a file that the next release tracks again would be lost.
- `RETIRED_SHIPPED` lists entries that an earlier release shipped. If the repo holds a copy,
  `migrate_retired_shipped` moves the entry into the user's list once, so the prune pass keeps it.

Entries that are found rather than listed join `TRACKED` like every other entry:

- The config of another plugin, found by the convention `~/.config/omarchy/<last segment of the
  id>.json`. A plugin that does not follow the convention is not found. That is the limit of a
  detector without a registry.
- A plugin config that the repo holds for a plugin that another machine's inventory records. A
  laptop without the plugin used to delete the desktop's settings on every save.
- Every Hyprland module that `hyprland.lua` requires, followed through the modules that it loads,
  in the live file and in the repo copy.
- When a restore brings back a module `hypr/<name>.lua`, it also brings back the store
  `plugins/<name>.json` of the plugin that writes it. OmaSettings writes `hypr/omasettings.lua` from
  `plugins/omasettings.json`.

## A directory entry is a trailing slash

An entry that ends in `/` is a tree. The slash stays on the id, the repo path and the restore plan,
so `is_dir_entry` is the only test anywhere.

- The copy mirrors both ways: a file deleted on the machine goes from the repo too. The copy refuses
  a destination outside the repo.
- The prune pass lets a directory entry claim everything under it. `owning_rel` maps a file inside a
  tree to the entry of the tree.
- `.git`, `node_modules`, caches and other tools' safety copies are excluded (`TREE_EXCLUDES`).
- The badge compares the whole tree with `tree_same`, so it heals itself like the file badge.
- The diff of a tree names the files that moved (`tree_diff_summary`). It never prints contents.
- `track` refuses a tree of more than 400 files, and it warns above 100.

## Big things are inventoried, never copied

- Themes are recorded as `name<TAB>origin` in `state/<machine>/omarchy-themes.txt`. The eight themes
  on the first machine were 556 MB, and 400 MB of that was their own `.git` directories.
- Plugins are recorded as id, version, origin and method in `state/<machine>/omarchy-plugins.txt`.
- A restore never installs a third-party theme or plugin. It names each one with the command that
  installs it. `install-theme <name>` and `install-plugin <id>` fetch one, and the panel confirms
  each one on its own.
- The reason is the 2026-09 marketplace security review. Neither `omarchy theme install` nor
  `omarchy plugin add` takes a commit to pin, so the origin serves whatever it holds on that day.
- Before `install-plugin` installs a plugin, it prints what the Omarchy marketplace catalog says:
  the verification status, the commit that the marketplace checked, and whether the origin has
  moved since. It informs and never refuses. `install-plugin <id> --check` prints only that.
- The catalog (7.6 MB) is cached for an hour in `~/.local/share/omarchy-replicant/catalog.json`.
  Only an install that a person asks for fetches it. The status poll never does.
- A cloned plugin (`omarchy plugin clone`) has an origin, but its edits exist nowhere else.
  `cloned_plugins` names each one, and `doctor` says to track its directory.
- `edited_plugins` names a plugin whose checkout holds work that its origin does not have. It first
  compares the files with `FETCH_HEAD` and every remote branch tip, through a temporary index.
- A theme that a person made by hand has no origin. `doctor` names it, and the answer is to track
  its directory.
- Theme names are compared normalised: `omarchy-theme-current` answers "Enter The Matrix", and the
  file records "enter-the-matrix".
- The clone of the user's own repo (`clone`, `pull`) is not pinned. It has no third party, and
  bringing down the latest state from another machine is the point of the tool.

## An inventory earns its place

An inventory file stays only if a restore consumes it, or if a person rebuilds a machine from it.

- A restore consumes `omarchy-plugins.txt` and `omarchy-themes.txt`.
- A person rebuilds from `pacman-*.txt`, `drift-vs-omarchy.txt`, `defined-secrets.txt`,
  `cifs-mounts.txt` and `user-services.txt`.
- `user-services.txt` records only the units whose file is in `~/.config/systemd/user`. The units
  that the distribution enables change on every package update and are nobody's setup.
- `system.txt`, `mise.txt`, `npm-global.txt`, `containers.txt` and `system-services.txt` were
  retired, because they failed both tests. The backup removes them from this machine's directory.
  Another machine's inventory is not this machine's to tidy.

## What "changed" means

- "Unsaved" is a question about content. `entry_differs` compares the live file with the repo copy,
  and the result is ORed with `git status`. Content catches "never copied in", and git catches
  "copied in, never committed".
- `entry_differs` is the only definition of that comparison. `count_changes` sends the counts to
  the bar in the brief payload, so the bar and the panel read the same number.
- The badge heals itself. Edit a file and put it back, and `cmp` matches again.
- The badge order is: off, missing, incoming, unsaved, default, unpushed, saved.
- `incoming` outranks `unsaved` for safety: the two look the same and ask for opposite buttons.
  `unsaved` outranks `default`, because a revert to the default still needs saving. `default`
  outranks `unpushed`, so that untouched files do not drown the real changes before the first push.
- The core and the QML compare states as plain strings. Guard 7 in `run-all.sh` fails when the QML
  tests a state that the core never emits. `test-core.sh` fails when the core emits a state that
  the panel, its legend or the README does not name.

## A difference has a direction

"This file and its copy differ" has two opposite answers with two machines. Only the moment when the
commits arrive knows which one is right, so that moment writes it down.

- `pull` calls `core_incoming <before> <after>`. It maps the changed repo paths to rows and records
  them in `~/.local/share/omarchy-replicant/incoming`, which is local to the machine.
- Only this profile's tree counts. Another profile's copy is kept apart on purpose.
- `is_incoming_rel` is always ANDed with "the copies still differ", so the mark clears itself.
- "Save everything" holds incoming entries back and names them. `save-file <id>` is the way to save
  this machine's version, and the panel's per-file Save is disabled on those rows.
- `test-journey.sh` walks the whole flow with two machines and a bare repo.

## Saving

- `savegame` copies, commits and pushes. `--auto` writes the subject from the changed paths, and
  `-m` gives a subject. Plain `savegame` commits the inventory and leaves the config for a person
  to commit with a reason.
- `savegame` pushes every commit that the remote does not have, and it sets the upstream on the
  first push. It says what happened: pushed, no remote, held with `--no-push`, or failed.
- A failed push exits 1. With two machines on one repo, a push that another machine beat is the
  normal case, and the answer is to pull and save again.
- `set` and `revert` commit through `savegame -m`, which commits every pending file together with the
  setting. That is intended. `scope`, `track` and `untrack` commit only their own paths.
- A lock (`flock` on `~/.local/share/omarchy-replicant/.replicant.lock`) serialises every command
  that writes. `undo`, `backups` and `purge` take it only when they apply, because a dry run must
  not create the lock file. `REPLICANT_LOCK_WAIT` sets the wait for the tests.

## Secrets

- `bin/scan-secrets.sh` is the only list of credential shapes. The data repo's pre-commit hook and
  the backup both use it. The backup scans `config/`, this machine's `state/` and this profile's tree.
- The hook is rewritten whenever it differs from the plugin's version. It fails closed: a missing
  scanner blocks the commit.
- A secret is never rendered. `core_diff` says only whether a secret differs, and the JSON carries a
  kind, a mode and variable names, never values. See hard rule 11 in `CLAUDE.md`.
- A tracked secret that only root can read does not end the backup. The backup names it with the
  `sudo install` command that copies it.
- `suggest_kind` marks a file that holds a credential (`gh/hosts.yml`, `.netrc`, `*token*`), so it is
  offered as a secret. As plain config, an OAuth token would sit in the repo at mode 644.

## The safety net

- Every write to the machine keeps what it overwrote as `<file>.bak.<epoch>`: `install_file`,
  `install_tree` and `root_apply` all do it.
- `list_backups` is the only glob that finds them. `purge` uses it too, so `purge` and `backups`
  cannot disagree.
- `undo` is a swap. It puts the newest backup back and keeps the replaced version as the new backup,
  so undo can be undone and the pile does not grow. It does not run the area's apply step.
- A setting edit keeps three backups for each file. It prunes only the backups that it made, which
  it lists in `~/.local/share/omarchy-replicant/setting-backups`. It never prunes a restore's backup.

## What the plugin writes, and where

The plugin writes nothing outside its own folder and `~/.local/share/omarchy-replicant/`, except the
backups and the optional link. `purge` names every trace (hard rule 8):

- `repo/`, the user's data repo, only with `--repo`.
- `.replicant.lock`, `.last-fetch`, `incoming`, `staged/`, `setting-backups` and `catalog.json`.
- The `.bak.<epoch>` copies beside the files that it overwrote. For a directory entry, a copy is a
  whole tree.
- `~/.local/bin/omarchy-replicant`, if `link` made it.

## suggest proposes, and a blocklist would not work

`core_suggest` uses a positive test: a known config extension, an executable in `~/.local/bin`, a
systemd unit, or a file in an Omarchy hook or template directory. The files under `~/.config` that
are not config outnumber the ones that are. `is_app_state_dir` removes whole Chromium and Electron
profiles by their marker files. Nothing is tracked until a person presses Track.

## An older machine never deletes what a newer one tracks

- `.replicant-version` in the repo records the highest version that has written it.
- `may_prune` refuses the prune pass when the running client is older. The client still copies its
  own files in.
- `record_repo_version` only raises the number, so an old client cannot lower it.
- This protects from 0.7.0 onwards. For a 0.6 machine, the answer is to upgrade it, and `doctor`
  says so.

## A writer migrates first

A fallback that makes a read correct does not make a write correct. A read-modify-write against a
list that the fallback invented is a delete. So every writer of `.replicant-sync` calls
`ensure_scope_file` first, and every writer of `.replicant-track` calls `ensure_track_file` first.

## Root-owned files

- `/etc/systemd/logind.conf.d/99-lid.conf` is the only setting that root owns.
- `root_apply` tries `pkexec`, then passwordless `sudo -n`. If neither works, it prints the exact
  command and fails. Omarchy ships no polkit agent by default, so in the panel this is the common case.
- The file is staged in `~/.local/share/omarchy-replicant/staged/` first, so that the privileged step
  is one copy of a file the user can read. The staged file stays after a failure, because the
  printed command names it.
- `restore-file` on a file outside `$HOME` goes through `root_apply`. A full `restore` prints the
  `sudo` command for each such file instead, so that it does not ask for a password many times.

## Settings

- Adding a setting is one line in the `SETTINGS` registry in `bin/lib/settings.sh`: 15 fields that
  are documented above the array. The panel renders the control from the type.
- Values are stored in one unit and shown in another. Omarchy stores idle timers in seconds, and
  the panel edits minutes. The CLI always speaks the stored unit.
- `value_text` writes the exact value out in full, so the stepper's rounding is never mistaken for
  the value. The two revert buttons compare the rendered text, so `1` and `1.0` count as the same.
- The keyboard layouts come from `localectl list-x11-keymap-layouts` (`@x11-layouts` in the
  registry). A short fixed list is the fallback.
- Hyprland Lua is edited by key, and only when the key appears exactly once. A nested-table editor
  would need a real Lua parser, and these files decide whether the session starts.
- `hypr_in_force` asks Hyprland which value it uses, because a module loaded later can override the
  file. The row then says which file sets the value.

## Performance

Measured on 2026-09-13, on a machine with 60 rows:

- `status --json`, which the panel reads, takes about 3.9 s.
- `status --json --brief`, which the bar runs once a minute, takes about 0.9 s. More than a third
  of that is one fork for each call of `scope_for` and `repo_path_for` (roadmap item F3).
- Measure before you optimise. `CONTRIBUTING.md` shows how.
