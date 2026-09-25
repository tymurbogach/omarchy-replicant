# How Replicant works

This document describes the data model of the plugin and the rules that the code follows.
`CONTRIBUTING.md` describes how to change the code safely, and it holds the hard rules.

## The code

- `bin/omarchy-replicant` is the CLI. It parses arguments, asks for confirmation and prints. It holds
  no business logic.
- `bin/replicant-core.sh` sets the paths, sources the modules in `bin/lib/`, loads the tracked
  lists, and runs the command that it receives.
- `bin/lib/*.sh` hold the logic, one concern for each module. A module defines functions and data,
  and it runs nothing when it is sourced.
- `bin/lib/common.sh` holds what the CLI and the core both need: `plural` and the machine name.
- The QML files (`BarWidget.qml`, `Panel.qml`, `Service.qml`) run the CLI and read its JSON.
- `ReplicantController.qml` owns CLI processes, their queue and result dispatch.
- `components/` holds the parts of the panel, one file each. A part reaches the panel only through
  its `panel` property.
- `replicant.js` holds the pure functions that the QML files share. `tests/qml` tests them.

| Module | What it holds |
| --- | --- |
| `manifest.sh` | The shipped lists, the user's list, Omarchy's defaults, the repo version guard |
| `schema.sh` | The v3 repository schema: the version marker, the write gate, entries validation, machine records |
| `registry.sh` | One normalized row per entry from every source that names one |
| `categories.sh` | The areas that the panel files every entry under |
| `scopes.sh` | Profiles, and whether each file is shared, kept per profile, or off |
| `track.sh` | Writing the user's list: `track` and `untrack` |
| `suggest.sh` | Proposing files that nothing tracks yet, and the file picker (`browse-json`) |
| `incoming.sh` | What another machine changed, and what differs on this one |
| `backups.sh` | The `.bak.<epoch>` safety net, `undo`, and the backups that setting edits make |
| `tree.sh` | Writing files and directory trees, with a backup of what they replace |
| `layout.sh` | The repo layout and the pre-commit hook |
| `inventory.sh` | Machine inventories that a restore or rebuild can consume |
| `backup.sh` | Copies live configuration and secrets into the save repository |
| `repo.sh` | Git repository lifecycle and remote transport |
| `gitstate.sh` | One git call for the state of every row |
| `discover.sh` | Entries found rather than listed: plugin configs and Hyprland modules |
| `settings.sh` | The settings registry, its readers and its writers |
| `status.sh` | The JSON that the panel and the bar read, the diff and the log |
| `briefcache.sh` | The brief-status metadata cache and its invalidation |
| `save.sh` | Saves as transactions: snapshot, one commit, fast-forward, push |
| `transaction.sh` | The one journal and lifecycle every mutation shares: worktree transactions, shape commits, resume, atomic installs |
| `bulk.sh` | Validates and applies multi-entry changes in one transaction |
| `migrate.sh` | Migrates clean v1 and v2 repositories into a new encrypted v3 repository; owns every legacy policy read |
| `restore.sh` | The restore plan for each area, and how each area is put back |
| `plugins.sh` | Plugins and themes: origins, inventories, and installs on request |
| `history.sh` | Copies that left the repo, and bringing them back from git history |
| `update.sh` | The plugin's own updates: what its origin has, and how to install it |

Rules for the code:

- The core runs its dispatcher only when it is executed. A sourced file sees the positional
  parameters of its caller, so a guard stops a caller's `$1` from running a command.
- The CLI loads the core with `load_core`. If the core cannot load, the command stops with a message.
- Every top-level associative array uses `declare -gA`. The CLI sources the core inside a function,
  and a plain `declare` there makes a local of that function.
- Every variable in a function is `local`. Bash scopes dynamically, so a leaked name changes the
  caller. A test compares every global name before and after a backup.
- `Panel.qml` holds presentation state, navigation state and actions. The controller owns processes.
  Each tab is a part in `components/`
  (`OverviewTab`, `ConfigsTab`, `SettingsTab`, `RestoreTab`), and so is each piece of a tab.
- Every tab is built from the same parts: `Card`, `ListRow`, `RowAction` and `FilterBar`. The
  design rules for them are in `CONTRIBUTING.md`.
- A scope change in the panel shows at once (`setScope`). The panel runs the commands one at a
  time in their own queue, and the status that follows does not force a fetch. A full status that
  is built after the queue is empty replaces what the panel assumed.

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
  `laptop`. On the first save, `ensure_profile_recorded` writes the resolved name into this
  machine's record under `.replicant/machines/`. The machine JSON record is the only store of the
  active profile on version 3.
- A role is taken when another machine is recorded under it, or when its tree exists and another
  machine has saved into this repo. Then the new machine uses its hostname, which is unique. The
  function only assigns: a machine that has a profile keeps it.
- Every tracked file has a scope in `.replicant/entries.json`: `shared`, `profile` or `off`.
  The file is in the repo, because "monitors are machine-specific" is a fact about the setup,
  not about one machine.
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
- The user's own entries live in the user's repo: config entries as `user` records in
  `.replicant/entries.json`, secret entries in the encrypted vault index. They live in the repo,
  because "back up my script" is a decision about the setup. (Version 1 and 2 kept them in
  `.replicant-track`; the migration carries them over.)
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
- The Plugins card lists every plugin (`build_plugins_json`). The plugins directory says which ones
  are installed. Every machine's inventory adds the ones that only another machine has.
- The origin and the method in that list come from the inventory in the repo, because another
  machine installs from that record. A plugin installed after the last save shows as not recorded.
- A bar widget keeps its settings in its entry in `shell.json` (`in_bar`), which the Desktop & bar
  area saves. Only a plugin with a settings file of its own has a file row in the card.
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
- A person rebuilds from `pacman-*.txt`, `drift-vs-omarchy.txt`,
  `cifs-mounts.txt` and `user-services.txt`.
- `user-services.txt` records only the units whose file is in `~/.config/systemd/user`. The units
  that the distribution enables change on every package update and are nobody's setup.
- `system.txt`, `mise.txt`, `npm-global.txt`, `containers.txt`, `system-services.txt` and
  `defined-secrets.txt` were retired, because they failed both tests. The backup removes them from
  this machine's directory. Another machine's inventory is not this machine's to tidy.

## What "changed" means

- "Unsaved" is a question about content. `entry_differs` compares the live file with the repo copy,
  and the result is ORed with `git status`. Content catches "never copied in", and git catches
  "copied in, never committed".
- `entry_differs` is the only definition of that comparison. `count_changes` sends the counts to
  the bar in the brief payload, so the bar and the panel read the same number.
- The brief payload reuses a metadata cache at `$REPLICANT_HOME/cache/state-v2.json`. The cache
  holds file identity, modification metadata, ciphertext object IDs, and the previous counts. It
  holds no secret values, names, or plaintext hashes. Every writer invalidates it, and the repo
  HEAD, profile, incoming list, and key state guard it. Full status never reads it: a content
  change that preserves size and mtime still hits the brief cache, while full status compares
  bytes and always sees it.
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

- `save` snapshots, commits and pushes through one transaction. The snapshot
  lands in a detached worktree under `$REPLICANT_HOME/transactions/<uuid>/`,
  beside a `meta.json` journal (base commit, selected IDs, stage, candidate
  commit, push result). The active worktree must be clean: every copy in it
  is regenerable from live files. A repo with no commits yet saves inline.
- `save --all` holds config, secrets and inventory in one commit.
  `save --id` holds exactly the named entries (and overrules the incoming
  hold-back, like `save-file` always did). `save --inventory` holds only
  this machine's inventory. `--auto` writes the subject from the changed
  paths, and `-m` gives a subject. `savegame` is a deprecated alias for
  `save`, and `save-file` is `save --id` with a default subject.
- The save commits only when the schema validates and the secret scanner
  passes over the transaction. It then verifies that the active HEAD is
  still the base, fast-forwards to the candidate, and pushes. A failure
  before the fast-forward leaves the active repo untouched; a committed
  transaction is never discarded automatically.
- `save` pushes every commit that the remote does not have, and it sets the upstream on the
  first push. It says what happened: pushed, no remote, held with `--no-push`, or failed.
- A failed push exits 1. With two machines on one repo, a push that another machine beat is the
  normal case, and the answer is to pull and save again. The next save retries the push.
- `set` and `revert` save only the registry entry that owns the setting. Other live edits stay out of
  that commit. If persistence fails, the CLI prints the exact save or push command to retry.
- `scope`, `track` and `untrack` commit only their own paths.
- `policy set --scope <scope> -- <id...>` validates the complete selection before it changes
  `.replicant-sync`. It changes all selected scopes together and commits the repository shape once.
  Entry type conversion uses a separate command and never happens through this scope operation.
- `bulk save|scope|track|convert-secret|untrack` applies one validated selection in one transaction.
  Tracking requires confirmation. Destructive scope changes and type conversion require `--yes`.
  Files and trees larger than 10 MiB require `--allow-large`; `BULK_LARGE_LIMIT_BYTES` changes that
  threshold. A tree can hold at most 400 files, and the CLI warns above 100. Bulk tracking rejects
  `.git` files and directories, and it accepts text based on file encoding rather than MIME type.
  Secret operations require a version 3 repository and a valid local identity.
- A lock (`flock` on `~/.local/share/omarchy-replicant/.replicant.lock`) serialises every command
  that writes, key init, import, rotate and export included. `undo`, `backups`, `purge` and `recover`
  take it only when they apply, because a dry run must not create the lock file.
  `REPLICANT_LOCK_WAIT` sets the wait for the tests.
- Every mutation journals before it commits, through `bin/lib/transaction.sh`. Save and bulk
  snapshot in a detached worktree and require a clean tree; shape writes commit only their own
  paths beside unrelated pending edits. A journal that cannot be written fails the mutation.
  A failed push keeps the local commit with its journal and names the retry.
- Recovery inspects actual Git state, never only the journal. `tx list` shows abandoned
  transactions, `tx resume <uuid>` fast-forwards a committed one into the active repo and pushes,
  and `tx discard <uuid>` drops a pre-commit one (a committed one needs `--force`). Recovery never
  discards committed work implicitly, and `doctor` reports abandoned transactions with the exact
  resume or discard command.
- A shape commit stages only the paths that exist on disk or in the index, and commits only
  the staged subset with rename detection off: a path that stages nothing once made the commit
  fail while reporting success, so an untrack was never committed.

## A deleted copy comes back from history

- `forget <id>` is for a file that is gone from this machine. One of the user's entries is
  untracked. A shipped entry keeps its place in `MANIFEST`, and only its copy leaves the repo, so it
  shows again if the file comes back on any machine.
- `forget` refuses a file that still exists, because the next save would copy it in again.
  `untrack` and `scope <id> off` are the tools for that case.
- `deleted` lists the copies that a commit deleted and that `HEAD` does not hold, grouped by commit.
  It reads `config/`, `secrets/` and this profile's tree only. Git sees a move between scopes as a
  rename, so a move is not a deletion here.
- `recover <sha>` undoes the deletions of one commit. The copies come back from `<sha>^`, and so do
  the lines that the commit removed from `.replicant-track`. Then each entry is restored onto the
  machine with a backup. It is a dry run by default.

## The plugin updates itself through Omarchy

- `update-check` fetches `origin HEAD` into the plugin's own checkout, as `omarchy plugin update`
  does. The stamp is `FETCH_HEAD` in that checkout, so the check writes no file of its own.
- The panel asks at most every six hours (`REPLICANT_UPDATE_MAX_AGE`). A click on the version in
  the panel header and `update-check --fetch` always ask.
- Only a fast-forward is an update. A checkout with commits of its own holds somebody's work.
- `update` runs `omarchy plugin update <id> --yes`, which validates the new version and rolls back
  one that fails. `update` refuses a copy that is not the installed plugin, such as a development
  checkout that the shell loads through a symlink.
- `update --restart` removes Quickshell's compiled QML cache and restarts the shell in its own
  session. Quickshell does not reliably notice that the cache is stale.

## Secrets

- `bin/scan-secrets.sh` is the only list of credential shapes. The data repo's pre-commit hook and
  the backup both use it. The backup scans `config/`, this machine's `state/` and this profile's tree.
- The hook is rewritten whenever it differs from the plugin's version. It fails closed: a missing
  scanner blocks the commit. The hook lets vault ciphertext (`*.age`) through.
- A secret is never rendered. `core_diff` says only whether a secret differs, and the JSON carries a
  kind and a mode, never values. It carries only a count, and a locked row carries no count.
  See hard rule 11 in `CONTRIBUTING.md`.
- In version 3 every secret lives encrypted with age in `vault/blobs/` under a random opaque ID,
  with its path, scope, source and blob ID inside the encrypted `vault/index.age` (index version 2).
  The schema marker at `.replicant/schema.json` carries the record
  `{"dataVersion": 3, "secretFormat": "age-pq-v2"}`. Non-secret policy lives in
  `.replicant/entries.json`, keyed by entry id with an absolute live path, a kind (`config` or
  `dir`), a scope (`shared`, `profile` or `off`) and a source (`user` or `override`); secret
  metadata lives only inside the encrypted index, never beside it. The repo holds only the public
  recipient in `.replicant/recipient.txt`. The shared private identity lives at
  `$REPLICANT_HOME/keys/identity.txt` at mode 600 and never enters Git, logs, status JSON, backups,
  journals or temporary worktrees.
- One machine runs `key init`, backs the identity up with `key export` to a path outside the repo
  and the state dir, and each other machine adopts it once with `key import`. `key export` refuses
  an existing destination without `--force` and installs the backup atomically at mode 600.
  `key status` reports whether this machine can read the vault, and `doctor` repeats its remediation.
  Init, import and rotate take the repo lock, so an export never reads a half-rotated identity.
- A secret whose vault cannot be read shows as `locked`. The bar counts locked secrets apart from
  unsaved ones and asks for the key, never for a save. `count_changes` prints
  `<unsaved> <incoming> <locked>`, and both brief and full status publish `locked`.
- `key rotate` re-encrypts every blob and the index to a new recipient. The rotation journal
  opens before the vault is touched and closes after the rotated commit lands; a rotation that
  dies midway keeps its journal and its previous identity for recovery. Rotation cannot revoke
  ciphertext already pushed: it stays readable with the old key. After a private key compromise,
  start a new clean repository instead of rotating.
- A tracked secret that only root can read does not end the backup. The backup names it with the
  `sudo install` command that copies it.
- `suggest_kind` marks a file that holds a credential (`gh/hosts.yml`, `.netrc`, `*token*`), so it is
  offered as a secret. As plain config, an OAuth token would sit in the repo at mode 644.

## Status contract

- Full `status --json` carries `schema_version: 3` and one `entries` array. Each entry carries
  `id`, `label`, `kind`, `source`, `category`, `scope`, `exists`, `saved`, `savedKnown`, `is_default`,
  `dirty`, `unpushed`, `incoming`, `sync_state`, `is_dir`, `nfiles` and `locked`.
  A locked secret omits `src`.
- A locked secret carries `saved: null` and `savedKnown: false`, because the client cannot inspect the
  encrypted index. Other entries carry a boolean `saved` and `savedKnown: true`.
- Full and brief status derive their unsaved, incoming, locked and missing counts from the same entry
  state. Full status excludes implicit entries that are absent on the machine and in the repo.
- The full payload also carries `counts`, `encryption` and `migration`. The old `configs` and
  `secrets` arrays remain for one compatibility release. The brief payload keeps its small shape.
- `source` is `user` for a personal entry and `override` for shipped, discovered or migrated
  override entries. `kind` is `config`, `dir` or `secret`.

## Migration

- `migrate-v3` moves a clean v1 or v2 repository into a new encrypted v3 repository. It requires a
  clean and synchronized source repo, an empty private remote, a safe external identity backup path
  and post-quantum age support. Without `--yes` it prints the migration summary and stops; `--yes`
  acknowledges that every recorded machine is upgraded or offline. `migrate-v2` is a deprecated
  forwarding alias for one release: it migrates to version 3, never to version 2.
- A v1 or v2 clone stays readable for inspection but every writer refuses it until `migrate-v3`
  runs. The command lists every recorded machine in its summary before accepting `--yes`.
- The command stages under `$REPLICANT_HOME/migration/<id>/repo`, creates one root commit, pushes it,
  clones it independently and checks the result before activation. A recovery journal records the
  migration until activation completes. A failed preflight, encryption step, validation step, push
  or clone leaves the active source repo and the local identity exactly as they were.
- The old repository is renamed to `legacy-repo-<epoch>`. The command never deletes it or its remote.
  `migration-warning` remains until the user confirms credential rotation and legacy cleanup in the panel.
- The data repository is always private. `create` requests private visibility, verifies it after
  creation, and refuses an existing public remote before any local mutation. It never flips a public
  repository to private automatically.

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
- `.replicant.lock`, `.last-fetch`, `incoming`, `staged/`, `setting-backups`, `catalog.json`,
  `cache/` (the brief-status counts) and `transactions/` (abandoned save worktrees with journals).
- The `.bak.<epoch>` copies beside the files that it overwrote. For a directory entry, a copy is a
  whole tree.
- `~/.local/bin/omarchy-replicant`, if `link` made it.

Two more places are touched, and neither holds anything of the plugin's. `update-check` writes
`FETCH_HEAD` inside the plugin's own checkout. `update --restart` removes
`~/.cache/quickshell/qmlcache`, which Quickshell builds again.

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
list that the fallback invented is a delete. So every writer of the legacy `.replicant-sync` calls
`ensure_scope_file` first, and every writer of the legacy `.replicant-track` calls
`ensure_track_file` first. On version 3 both are no-ops: policy writes validate
`.replicant/entries.json` and the vault index before mutation instead.

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
