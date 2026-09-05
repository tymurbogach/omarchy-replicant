# Omarchy Replicant — plugin (code)

This is the **`omarchy-replicant`** repo — public, the plugin's project, meant to be shared with
other Omarchy users via `omarchy plugin add` / the omarchyplugins directory. It's an Omarchy 4
plugin (Hyprland + Quickshell/QML) that saves a user's configuration into a **private** GitHub
repo of their own (created automatically) and restores it on any machine. A port, as an
installable plugin, of the [[omarchy_thinkpad]] pattern (`~/omarchy_thinkpad`) — not copied
literally, adapted to be portable across machines instead of tied to one.

This repo is **only the plugin's code** — no user data. Each user who installs it gets their
**own separate private repo** for their actual data (dotfiles, secrets, inventory), named
`<their-hostname>-replicant` by default (see `DEFAULT_REPO_NAME` in `bin/omarchy-replicant`) —
never `omarchy-replicant` itself, that name is taken by this plugin. On this machine that private
repo is `cyberdyne-replicant`. Never mix the two repos. The plugin must not hardcode anything
machine- or user-specific except through `MANIFEST`/`SECRETS_MANIFEST` in
`bin/replicant-core.sh`.

## Language rule

- **The entire project is in English**: code, comments, commit messages, CLI output, panel UI
  text, docs. No Spanish anywhere in either repo (this one or the sibling data repo), including
  new code, new commands, and new panel sections.
- Exception: none. If a string is user-facing (CLI message, button label, badge text), it's
  still English — this is a developer's personal tool, not a localized product, and mixing
  languages makes future edits error-prone (partial greps, inconsistent tone).

## Talking with Claude Code

This is about the conversation with the assistant, not the project — the Language rule above
still applies with no exception to anything that ends up in the repo (code, comments, commits,
CLI output, docs).

- End each turn with a final summary in simple, plain Spanish (castellano simple).
- Whenever a task calls for it — editing Hyprland/Omarchy desktop config, terminal configs,
  themes, idle/lock, keybindings, the bar — invoke the `omarchy` skill rather than improvising
  from memory.

## The one bug this project keeps having

Four sections below are the same bug wearing different clothes, and naming it once is worth more
than finding it a fifth time:

> **A question about the SYSTEM is answered by asking the system — never by reading the artifact
> you wrote.**

The artifact is always right there, always cheaper to read, and always one indirection away from
the truth:

| The question | The artifact that lied | What actually answers it |
| --- | --- | --- |
| Has this file changed? | `git status` on the repo copy | `entry_differs` — `cmp` against the live file |
| Does this machine have unsaved work? | `repoState.dirty` | `count_changes`, the rows the panel counts |
| What does closing the lid do? | `99-lid.conf`, which this plugin wrote | logind — a `block` inhibitor makes the file inert (`lid_blocked_by`) |
| Which theme is on? | the name saved in the repo | `omarchy-theme-current`, compared normalised |
| Is the session locked? | `LockedHint` | the lock's own PAM session in the journal |
| Where does this file's copy live? | a path built on the spot | `repo_copy_for_rel` → `is_secret_rel` + `repo_path_for` |

Every one of those shipped, and every one looked correct in review. Before writing a reader for
anything, ask which side of the line it sits on: **a value read back from a file this plugin wrote
is reporting intent, not effect.** They agree right up until something else has an opinion.

## Hard rules

1. **Never edit `/usr/share/omarchy/` or `~/.local/share/omarchy`** (symlink to the pacman
   package). It gets overwritten on every `omarchy update` — any change there is lost, and it
   can also break "is this identical to the default" detection (`is_default_file()` in
   `bin/replicant-core.sh`), which compares directly against those paths.
2. **Any operation that writes to the real system is dry-run by default** (`reset-all`,
   `restore`) and **backs up as `.bak.<epoch>`** before overwriting an existing file
   (`install_file` / `install_tree` in `bin/replicant-core.sh`). Don't add a new writing command that skips this pattern.
3. **`reset-all` (everything → Omarchy defaults) and `restore --apply --all` (everything → what's
   saved on GitHub) are two distinct actions** — never merge them. The UI (`Panel.qml`, the
   **Restore** tab) and the CLI keep them as separate commands so the user never confuses
   "factory" with "what's in my repo".
4. **Any visual change to `Panel.qml`/`BarWidget.qml` is verified with a real screenshot**
   (`grim`) after reloading the plugin — a process not crashing, or just reading the QML, is not
   enough. `repoState.configs[].sync_state` is the source of truth for the badges
   (● unsaved / ↓ incoming / ↑ unpushed / ◆ saved / ○ default / ⊘ off / · missing); if a new state is added,
   verify it by actually triggering it on a test file, not just by reading the code.
5. **Global destructive commands ask for a single summary confirmation** (not per-file) unless
   `--yes`/`-y` is passed explicitly — this applies to `reset-all` and `restore --apply --all`.
6. **The panel never opens a terminal the user has to dismiss.** Editing a file launches the
   editor directly (`omarchy-launch-editor`), a diff renders inline in the panel, and a
   destructive action confirms in the panel and then runs headless with `--yes`. The one
   exception is `create` and `clone`, which genuinely prompt (GitHub login, a repo URL).
   `omarchy-launch-floating-terminal-with-presentation` wraps whatever it runs in the Omarchy
   logo *and* a "press a key to close" prompt, so using it for a read-only action costs two
   interactions to see one file. The user asked for this to stop; don't reintroduce it.
7. **The UI never looks for the CLI on `PATH`.** `omarchy plugin add` runs no install hook, so
   nothing puts `omarchy-replicant` in `~/.local/bin` — a fresh install that pointed there left
   every button in the panel silently doing nothing while the bar icon looked fine. All three QML
   entry points resolve it with `Qt.resolvedUrl("bin/omarchy-replicant")`, which is correct even
   for a symlinked dev checkout. `link`/`unlink` are the opt-in for terminal use.
   `tests/run-all.sh` fails if a `.qml` mentions `local/bin` or drops the `Qt.resolvedUrl` form.
8. **The plugin writes nothing outside its own folder and `~/.local/share/omarchy-replicant/`, and
   `purge` can name every trace of it** — including the `.bak.<epoch>` copies it leaves beside the
   files it overwrites, which for a directory entry is a whole tree next to the original. Anything
   a future feature leaves elsewhere must be listed in `cmd_purge`. `purge` is dry-run by default
   and never touches the GitHub repo. See *The safety net has to be reachable* for the glob that
   finds them and why there is only one copy of it.
9. **The restore plan is derived from `MANIFEST`, never hand-written.** `plan_for_category()`
   computes "repo path → destination → mode" from the one list. There used to be a second,
   hand-maintained copy of that mapping inside `cmd_restore`, which meant adding a file to
   `MANIFEST` backed it up but never restored it — a bug you only discover on the day you need
   the backup. `tests/test-core.sh` fails if any saved file is absent from every category's plan.
10. **Restoring is not copying.** Every category declares what has to run afterwards
   (`apply_for_category`): Hyprland gets `hyprctl reload` plus a `configerrors` check, terminals
   get `omarchy restart terminal`, the theme is replayed through `omarchy-theme-set` rather than
   copied, plugins are reinstalled with `omarchy plugin add` from the recorded origin. This is the
   plugin's stated selling point ("the right way to back up Omarchy"), it is shown in the panel
   under every open category, and it is in the README table — don't add a category that copies
   files and stops.
11. **Never render a secret — and ask the entry, not the filename.** Every rule that protects a
   secret used to key on the path prefix `ssh/` or `env/`, which held for the three the plugin
   ships. `track --secret` then let a user add one under any name — `~/.config/gh/hosts.yml`
   derives to `gh/hosts.yml` — and all of them silently stopped applying: it was copied *into*
   `secrets/` and read back *out of* `config/` (so the panel called a saved file unsaved and
   revert-to-repo could never find it), it would have been restored at mode 644 with an OAuth
   token in it, and `core_diff` did not recognise it as a secret at all. `is_secret_rel()` asks
   `TRACKED_SECRETS` instead; `repo_copy_for_rel`, `restore_mode_for` and `core_diff` all go
   through it. `tests/test-core.sh` plants a token and greps every output for it. `core_diff` refuses to print the contents of any tracked secret
   (`.pub` files excepted) and says only whether they differ; `build_secrets_json` carries a kind,
   a mode and variable *names*, never values. A diff on screen is a diff on any screen share.
12. **Names that are already taken.** `state` is a built-in property of every QML Item,
   and `GROUPS` is a bash special variable — `local GROUPS=(...)` aborts the enclosing function
   with "variable may not be assigned value", which silently turned `restore` into a no-op for
   an entire release. Before naming a shell array or a QML property, check it is yours to use.

# How the data works

## Two machines, one repo

The plugin is built for a desktop *and* a laptop sharing one private repo, which rules out two
shapes that look fine with a single machine:

- **`state/` is scoped by hostname** (`state/<machine>/`). A shared inventory meant each machine
  overwrote the other's package list on every save and every pull looked like a change.
  `ensure_repo_layout` migrates a flat `state/*.txt` under the current machine.
- **A profile is claimed, never assumed.** `guess_profile` asks the chassis, so every laptop
  guesses `laptop` — and two laptops on one repo both wrote
  `profiles/laptop/config/hypr/monitors.lua`, the second save silently overwriting the first
  machine's only backup of its screen layout. That is the bug `state/<hostname>/` was introduced
  to fix, one level up: profiles are named by ROLE, and roles collide. `ensure_profile_recorded`
  writes the resolved name into `.replicant-profiles` on the first save, so the next machine can
  see the role is taken and fall back to its hostname, which is unique by construction. A role
  counts as taken when another machine is *recorded* under it **or** when its tree exists and some
  other machine has saved into this repo — the second half is what covers every repo written
  before the check existed. It only ever assigns: a machine that already has a profile keeps it,
  so nothing moves in a repo that is already working.
- **Every tracked file has a scope** — `shared`, `profile` or `off` — in `.replicant-sync` **in the
  repo**, because "monitors are machine-specific" is a fact about the setup, not about one machine.
  `profile` is the one that makes two machines practical: the file lives at
  `profiles/<profile>/config/<rel>`, so each profile keeps its own copy and neither overwrites the
  other. Switching a file off means nobody gets a backup; scoping it means everybody gets their
  own. `hypr/monitors.lua` is seeded `profile`, not off.
- **`repo_path_for()` is the only place that knows where a file's copy lives.** The copy pass, the
  prune pass, the restore plan and the "revert to repo" button all call it, so a file can never be
  saved to one path and restored from another. The prune pass sweeps only `config/` and *this*
  profile's tree — another machine's profile directory looks entirely untracked from here, and
  pruning it would delete that machine's only backup.

## The shipped list is universal; the personal list is the user's

`MANIFEST` is public plugin source, so it may only name paths any Omarchy machine plausibly has.
It used to carry one person's Claude hooks, their audit script, their `~/dev/mise.toml` and a
fingerprint-reader unit — which every marketplace installer then saw as a screenful of "missing"
rows for files they had never heard of, while none of their own files were tracked at all.

Everything personal lives in **`.replicant-track` in the user's repo**, next to `.replicant-sync`
and `.replicant-profiles` and for the same reason: "back up my audit script" is a decision about
the setup, not about one machine.

- `MANIFEST` + `USER_MANIFEST` are joined into **`TRACKED`** by `rebuild_tracked()`. Every loop that
  means "everything tracked" reads `TRACKED`/`TRACKED_SECRETS`; the two source arrays are only for
  telling a shipped row from a user row (`source: "manifest"` vs `"user"`, which is what gates the
  panel's Untrack button).
- **`load_user_manifest` has a read-only fallback and `ensure_track_file` does the real migration** —
  the same split, and the same reason, as `scope_for`/`ensure_scope_file`. Without the fallback, the
  first command after an upgrade would see a 0.6 repo's saved copies as untracked and the prune pass
  would delete every one of them. `tests/test-core.sh` proves both halves.
- A shipped entry that exists neither on this machine nor in the repo **draws no row**. The core list
  is written for everybody, so any one machine is expected to be missing part of it. One the repo
  *has* a copy of always shows, because "it was here and now it isn't" is exactly what a backup tool
  must not hide.
- `untrack` refuses a shipped entry and says to use `scope <id> off` instead — untracking removes the
  row *and* the repo copy, so doing it to a core entry would make a file the next release tracks
  again vanish with no way back.

## A directory entry is a trailing slash, everywhere

`MANIFEST`/`.replicant-track` entries ending in `/` are trees. The slash is carried through the id,
the repo path and the restore plan as a plain string, which is what lets `is_dir_entry` be the only
test anywhere. What each pass has to do differently:

- **copy**: `copy_tree_into_repo` mirrors *both ways* — a file deleted on the machine goes from the
  repo too, or a tracked directory only ever grows. It refuses a destination outside `$REPO_DIR`.
- **prune**: a directory entry claims everything under it *by prefix*. Without that case the sweep
  sees every file in the tree as untracked and deletes the whole thing one file at a time, on the
  save that just wrote it. `owning_rel()` exists for the same reason: "is this switched off" is a
  question about the *entry*, and a file three levels inside a tree has no entry of its own.
- **`.git` is excluded** (`TREE_EXCLUDES`). A repo nested in a repo is not backed up by copying its
  objects around.
- **state**: `tree_same` is `cmp` over the whole tree, so the self-healing badge works unchanged —
  edit a file inside, the entry says unsaved; put it back, it clears.
- **diff**: `tree_diff_summary` names which files moved, never their contents. A tree is too big to
  render, and the useful answer is the file list.

## Big things are inventoried, never copied

The eight custom themes on this machine are **556 MB**, 400 of it their own `.git` directories.
Tracking `~/.config/omarchy/themes/` as a directory — which is what the plan said to do — would have
put all of it in a git repo. Every user theme Omarchy knows about is a git clone, so what travels is
the URL: `state/<machine>/omarchy-themes.txt` records `name<TAB>origin`, and `restore_themes` runs
`omarchy theme install` for the missing ones **before** `restore_theme` applies the name. That order
is the bug the pair exists to close: `omarchy theme set enter-the-matrix` on a machine that does not
have the theme fails, and the most visible thing about the setup comes back as nothing.

Same shape as plugins, and the honest caveat is the same: reinstalling gets the *upstream* copy, not
local edits. A hand-made theme has no origin — `doctor` names it and the answer is to track its
directory.

Theme names are compared **normalised**: `omarchy-theme-current` answers "Enter The Matrix" and the
file records "enter-the-matrix". They differ in case *and* separator, so case-folding alone still
made every restore claim the theme needed re-applying.

## An inventory earns its place or it is noise

Measured on the first repo this plugin ever wrote: `state/` touched **46 of the first 100
commits**, and almost none of them carried a real change. `system.txt` opened with `date: <now>`;
`mise.txt` carried `(pruned in 9h)`, a countdown; `system-services.txt` listed the eighteen units
*the distribution* enables, which move on every package update and are nobody's setup.

The test an inventory file has to pass, and it is short:

> **Does a restore consume it, or would a person rebuild a machine from it?**

Consumed by restore: `omarchy-plugins.txt`, `omarchy-themes.txt`. Rebuilt from by a person:
`pacman-*.txt`, `drift-vs-omarchy.txt`, `defined-secrets.txt`, `cifs-mounts.txt`. Retired for
failing both: `system.txt`, `mise.txt` (redundant — `mise/config.toml` is tracked as config and is
the authoritative list), `npm-global.txt`, `containers.txt`, `system-services.txt`.

Two rules fall out of doing this:

- **A generator that merely stops writing leaves its last output in the repo forever.** The prune
  pass sweeps `config/` and the profile tree, never `state/`, so a retired name sits there looking
  current. `state_snapshot` removes retired names explicitly — and only from **this machine's**
  directory, because another machine's inventory is not ours to tidy. That is the same rule the
  prune pass follows and it exists for the same reason.
- **`user-services.txt` records only units whose file is in `~/.config/systemd/user`.** The
  distribution's enabled units are not a setup decision. Paired with the unit file itself, which is
  tracked as ordinary config, three lines are enough to bring a user's own service back — and it
  stops moving every time a package updates.

Related: a value the user changes for the mood of the day (the active theme) is scoped `off`
rather than tracked. The *themes* are inventoried and reinstalled; which one is on right now is
not a fact worth a commit.

## What "changed" means, and who gets to answer

The headline instance of the rule above, and the one that made this plugin lie about its own job.

`build_configs_json` used to answer it with `git status --porcelain` on the **repo copy**, which
only becomes true once `core_backup` has copied the live file in — so a file edited on the machine
and never saved reported itself as **saved on GitHub**. It survived review because the test that
covered it ran `core_backup` first, which is exactly what hid it.

- **The answer is content**, `entry_differs`, OR'd with the git check: content catches "never
  copied in", git catches "copied in, never committed".
- **`entry_differs` is the only definition of that comparison.** Two copies of it is how a badge
  and a bar icon come to disagree about the same file — `BarWidget.qml` read `repoState.dirty` for
  three releases after the panel stopped, so the bar sat on the calm hexagon saying "✓ in sync"
  over an unsaved config all day. The bar polls `--brief` and has no rows, so `count_changes`
  sends the number down in the payload; brief went from 0.04 s to 0.18 s once a minute for it.
- **It is self-healing.** Edit a file, put it back, `cmp` matches again and the badge clears on its
  own. There is no flag to go stale.

Three ordering rules fell out, all deliberate: **`incoming` outranks `unsaved`** (safety — the two
look identical and ask for opposite buttons), **`unsaved` outranks `default`** (reverting to
Omarchy's default is itself a change that needs saving, and used to show the calm ○), and
**`default` outranks `unpushed`** (before the first push every untouched file would light up as
"to push" and drown the few that changed).

**When you rename a state, the QML does not follow.** `Panel.qml` compared
`sync_state === "modified"` after the core stopped emitting it, so every category card said
"in sync" while its own rows showed unsaved changes. Both sides are bare strings and nothing
connects them — guard 7 in `tests/run-all.sh` now fails when the QML tests for a state the core
never emits.

## A difference has a direction, and only one moment knows it

`unsaved` is `! cmp -s "$src" "$(repo_path_for "$rel")"`, which is the right question and half an
answer: it says the two copies differ, never which one is newer. With two machines on one repo —
the premise of the whole plugin — the other half is the difference between a backup and a
delete. Pull a change the laptop made and the desktop showed the red ● whose button is Save;
pressing it committed the desktop's older file over the laptop's work, in one click, with the
panel having recommended exactly that.

Content cannot answer it and no flag on a file can be trusted to stay true. What *is* certain is
the moment the commits arrive, so that is where it is written down:

- **`cmd_pull` → `core_incoming <before> <after>`** maps the changed repo paths back to the rows a
  person can press a button on (`owning_rel`, so a file three levels inside a tracked tree marks
  the tree's row) and records them in **`$REPLICANT_HOME/incoming`** — machine-local, because
  "what this machine has not caught up with" is not a fact about the setup and has no business in
  the repo. Only *this* profile's `profiles/<p>/config/` counts; the other machine's profile copy
  is deliberately not shared and marking it incoming would tell the desktop to restore the
  laptop's monitor layout onto itself.
- **`is_incoming_rel` is never trusted alone.** Every caller ANDs it with "and the copies still
  differ", which is what makes the mark self-healing in exactly the way the unsaved badge is:
  restore the file and it clears, save over it deliberately and it clears. Nothing has to remember.
- **`incoming` outranks `unsaved`** in the badge precedence, and it is the only ordering rule here
  that is about safety rather than tidiness.
- **`core_backup` holds incoming entries back** and names them. "Save everything" is never a
  request to commit a stale copy over another machine's work; the escape hatch is naming the file
  (`save-file <id>`), and the panel's per-file Save is disabled on those rows for the same reason.

`tests/test-journey.sh` walks the whole thing, because every unit either side of the gap was
already passing when the bug existed.

## The safety net has to be reachable or it is not a net

Every write to the real machine keeps what it overwrote as `<file>.bak.<epoch>` — `install_file`,
`install_tree` and `root_apply` all do it, and every confirmation dialog in the panel promises it.
For four releases the only code that could *find* one was `cmd_purge`, which removes the plugin.
Eleven of them were sitting on this machine, unnamed and unreachable: that is a mess, not a net.

- **`list_backups [rel]`** in the core is the single glob. `cmd_purge` goes through it too — the
  trailing-slash bug hard rule 8 exists for lived in that glob, and two copies of it is how purge
  and `backups` would come to disagree about what is on the machine.
- **`core_undo` is a swap, not a restore.** Obeying rule 2 naively would leave a second backup on
  every undo, so undoing twice grows the pile it exists to drain. It consumes the newest backup and
  writes what it replaced in its place: the count stays where it was, and undo can be undone —
  which is the one thing anybody pressing that button wants to be sure of.
- **It does not run the category's apply step.** `restore-file` does, because it is putting the
  saved setup back. Undo is "that was wrong, give me the previous minute", and reloading Hyprland
  under someone who has just realised they made a mistake is not a favour.
- The panel puts it at the bottom of **Restore**, under "If a restore went wrong", one row per id
  (the newest, since that is the one Undo takes) with the rest counted as "+N older". A `same`
  backup — byte-identical to the live file — disables its own Undo and says why: a button that
  would change nothing is worse than no button.

## `suggest` proposes; a blocklist would never have worked

The first version of `core_suggest` offered 1Password's `Local State`, Chromium's `Preferences`, a
`.sock.pid` and a log file — the things under `~/.config` that are *not* config outnumber the things
that are, and they are invented faster than anyone can exclude them. It is now a **positive** test:
a known config extension, or an executable in `~/.local/bin`, or a systemd unit. On top of that,
`is_app_state_dir` catches the whole Chromium/Electron profile layout by its own marker files, which
is what removes 1Password, Code and chromium in one rule rather than three.

`suggest_kind` marks a file that holds a credential (`gh/hosts.yml`, `.netrc`, `*token*`) so it is
offered as a **secret**. Tracking one as ordinary config would leave an OAuth token world-readable
in a git checkout.

## An older machine must never delete what a newer one tracks

The prune pass removes whatever is not in the **running** version's list. With two machines on one
repo — the premise of the whole plugin — the machine still on the old release therefore deletes
every file the upgraded one tracks, on its next save. This is not a hypothetical: while building
0.7.0 the `~/.config/nvim` tree the new code had just saved was gone by the time anyone looked,
because the installed plugin was still 0.6.3 and had saved once in between.

`.replicant-version` in the repo records the highest version that has ever written it, and
`may_prune()` refuses when the running client is older. The client still copies its own files in;
it just does not get to decide that somebody else's are stale. `record_repo_version` only ever
raises the number, so an old client saving cannot lower it and re-arm the deletion.

**This only protects from 0.7.0 onwards** — an already-released client cannot be taught to check.
For a 0.6 machine the answer is to upgrade it, and `doctor` says exactly that. The reproduction, run
against the real v0.6.3 core, is in `tests/test-core.sh`.

## Every writer of a repo-shape file must migrate first

`core_scope` once rewrote `.replicant-sync` from whatever `read_scopes` returned. On a repo that
still had the v0.5 `.replicant-exclude`, that read returned nothing — so changing one file's scope
silently discarded the user's entire off-list. Reading has a fallback (`scope_for` honours the
legacy file until the migration runs); **writing needs the real migration**, so every writer calls
`ensure_scope_file` first. `tests/test-core.sh` fails if it does not.

The general rule: a fallback that makes reads correct does not make writes correct. A read-modify-
write against a file the fallback invented is a delete.

## Root-owned files: ask, or say you could not

`/etc/systemd/logind.conf.d/99-lid.conf` is the one thing worth configuring that is not ours to
write. `root_apply()` tries pkexec, then passwordless `sudo -n`, and otherwise prints the exact
command and fails **leaving /etc untouched**. Omarchy ships no polkit agent by default, so the
third branch is the common one in the panel — which is the point: a settings control that quietly
does nothing is worse than one that explains. The whole file is staged under `$HOME` first, so the
privileged step is a single copy of a file the user could have read, never an editor run as root.

## Values are stored in one unit and shown in another

`SETTINGS` fields 14/15 (`scale`, `display`) exist because Omarchy stores idle timers in seconds
and nobody thinks in "600". The panel edits minutes and multiplies back; **the CLI always speaks
the stored unit** (`set idle.lock 600` is still seconds) so scripts never have to know what the
panel happens to display. `value_text` carries the exact current value written out in full — the
stepper rounds 150 s to 3 min, and the row says "2 min 30 s" underneath so the rounding can never
be mistaken for the value.

Comparisons for the two revert buttons are made on the *rendered* text, not the raw string:
`shell.toml` holding `1` and a fallback of `1.0` are the same density, and a revert button that
would change nothing is worse than no button.

## Repo conventions

- `bin/omarchy-replicant` is the CLI (subcommand parsing, terminal UX); `bin/replicant-core.sh`
  is the pure logic (MANIFEST, backup, state detection, JSON for the panel) — don't duplicate
  business logic in the CLI, it belongs in the core.
- Third-party plugin auto-discovery (`discover_plugin_entries()` in `replicant-core.sh`):
  convention = `~/.config/omarchy/<last-segment-of-id>.json` next to the plugin's
  `manifest.json`. If a new plugin doesn't follow that convention, it won't show up on its
  own — that's not a bug, it's the deliberate limit of a generic, registry-free detector.
- **The repo mirrors the manifest, both ways.** `core_backup` copies tracked files in *and*
  prunes `config/` files that are no longer tracked, so dropping a MANIFEST line doesn't leave a
  copy behind forever. A tracked file whose source is missing on this machine keeps its last
  saved copy — "not on this machine right now" is not "no longer tracked".
- **The plugin does not back up its own source.** It used to, which cluttered the file list with
  four rows the user could not act on, and `restore` never had a group for them. What is recorded
  instead is `state/omarchy-plugins.txt`: every installed plugin's id, version and git origin, so
  a second machine can be rebuilt with `omarchy plugin add`.
- **Adding a setting is one line** in the `SETTINGS` registry in `replicant-core.sh`: 15
  pipe-separated fields, documented above the array. `Panel.qml` renders the control from the
  `type`, so no QML change is needed for a new setting of an existing type. Give it a `fallback`
  only when the writer can create the key from nothing (the `toml-*` types) — otherwise the panel
  would offer a control over a value that does not exist. `tests/test-settings.sh` checks the
  field count and the id uniqueness of every line.
- **Hyprland Lua is edited by key, and only when that key is unambiguous.** `lua_get`/`lua_set`
  act on a single uncommented `key = value` line and refuse when the key appears zero or twice.
  That is the deliberate limit: a nested-table editor needs a real Lua parser to be safe, and
  these files decide whether the graphical session starts. Anything a single key can't express
  stays a whole-file `MANIFEST` entry, edited in a real editor.
- `MANIFEST`/`SECRETS_MANIFEST` are deliberately fixed, explicit lists for the "core" dotfiles
  (shell, ssh, git, hypr, etc.) — don't turn them into generic auto-discovery, you'd lose the
  guarantee that only what a human decided to track gets tracked.
- Commits to this repo (code) use normal engineering messages — don't confuse this with the
  "one commit per decision, with the why" convention of the **data** repo, which is a different
  thing and lives in the other repo.

# The panel

## Quickshell caches compiled QML — clear it or you are testing old code

**Never restart the shell while the session is locked.** The Omarchy shell *is* the
lock screen, so `omarchy restart shell` tears the lock down and builds it again — and
the fingerprint prompt starts over from zero, with a 30-second timeout, every time. On
2026-09-04 five restarts between 10:56 and 11:00 landed on top of a lock the user was
already fighting: the prompt reset under their finger until they gave up and rebooted
the machine. Check first, and wait rather than restart:

```bash
loginctl show-session "$(loginctl | awk '/'"$USER"'/{print $1; exit}')" -p LockedHint
```

`LockedHint=yes` means the only safe action is to leave it alone. **But `LockedHint=no` does not
mean unlocked.** On 2026-09-05 at 02:05 the shell's lock screen was up and cycling the fingerprint
prompt while logind reported `LockedHint=no`, `IdleHint=no`, `Active=yes` — every one of them
wrong. The hint is set by whoever calls `SetLockedHint`, and a shell that was restarted (or killed)
while locked never gets to set it. Ask the thing that is actually locked instead:

```bash
journalctl --user --since "60 seconds ago" | grep -q 'pam.subprocess.*omarchy-lock' && echo LOCKED
```

A lock session runs `omarchy-lock-fingerprint` (or `-password`) through PAM and re-arms it every
30 s, so a hit inside the last minute is live evidence. `LockedHint=yes` is still conclusive; only
its `no` is worthless. Check both, and prefer the journal.

Two more things learned the same night, both about the restart itself:

- **`omarchy restart shell` must be allowed to finish.** Killed halfway it leaves the old shell
  running and starts a second one — two bars, two panels, and a `quickshell -n -p` pair in `ps`.
- **`omarchy-launch-shell` is a supervisor**, so killing the `quickshell` it watches just makes it
  spawn a replacement. The one to remove is the orphan whose PPID is 1 (systemd); the supervised
  one has `omarchy-launch-shell` as its parent and a short-lived child of its own, which is normal.

And a false alarm worth not repeating: **`grim` blocking forever usually means the display is
DPMS-off**, not that anything is wedged. `hyprctl monitors -j | jq '.[].dpmsStatus'` answers it in
one line — `false` means powered down and there are no frames to copy. This matters more
than it looks: the shell restart is the innermost loop of working on this plugin, and
the person at the keyboard has no way to tell a restart from a crash.

**After changing any `.qml` file, `rm -rf ~/.cache/quickshell/qmlcache` before
`omarchy restart shell`.** Quickshell keeps compiled QML (`.qmlc`) there, and it does
*not* reliably invalidate on a plugin reinstall (`omarchy plugin remove` + `add`
recreates the same paths). The shell will log `Local plugin changed, reloading` and
still run the **old** compiled version — silently, with no error.

This cost hours once: a whole feature plus several fixes appeared to "not work",
the panel rendered a contradictory mix of old and new state, and every layer checked
out fine in isolation (CLI JSON correct, `qmllint` clean, brace structure correct, no
runtime warnings) because the running code simply wasn't the code on disk.

**How to prove which code is actually running:** add a temporary
`Component.onCompleted: console.log("...")` and check `journalctl --user | grep`.
Other plugins' `console.log` shows up as `DEBUG qml:` — if yours doesn't appear at
all, the component isn't being instantiated from your file, and the cache is stale.
That check takes seconds and beats hours of reasoning about correct-looking code.

## Two QML traps that silently produce a half-rendered panel

Both of these cost a full debugging session. Neither produces an error you'd notice: `qmllint`
passes, the CLI's JSON is correct, and the panel just quietly renders wrong.

**1. `state` is a built-in property of every QML Item.** The panel's data used to live in
`property var state`, but inside any nested item (`Column`, `Row`, `Text`, `Button`) the bare
name `state` resolves to *that item's* own built-in state string — `""` — not ours. The symptom
is a panel where the header is right (root scope) while every nested section believes there is no
repo: buttons disabled, "No local repo yet" showing, and whole sections invisible.
The property is now called **`repoState`**, which removes the trap entirely rather than relying on
every nested reference remembering to say `root.`. Don't rename it back, and don't introduce a
`state` property in a new component. `tests/run-all.sh` greps for an unqualified `state.` and
fails on it.

**2. `Style.spacing.rowPaddingY` does not exist.** `rowPaddingX` does, `rowPaddingY` does not, so
`row.implicitHeight + Style.spacing.rowPaddingY * 2` evaluates to `NaN`, the delegate gets a NaN
height, and the list renders section headers with invisible rows between them. Use
`Style.spacing.controlPaddingY`. When a delegate renders blank, log its
`width/height/implicitHeight` first — a `NaN` shows up immediately.

Related layout rule: a `Row` anchored with `anchors.verticalCenter` inside an item whose
`implicitHeight` is derived from that same Row is a parent-height ↔ child-position feedback loop
(Qt logs `polish() loop` and the section collapses). Give such rows a fixed height.

## A third trap: a child that is both sized by and positioned within its parent

A `BorderSurface` whose `implicitHeight` comes from its child column, with that column anchored
`verticalCenter` to it, is a parent-height ↔ child-position feedback loop: Qt logs `polish() loop`
and the item collapses to nothing. Two ways out, both used here:

- **Fixed row height** (`SettingRow`, `FileRow`): the row is a known height and the text elides.
- **Anchor the child to the top** (`RestoreCard`): the child's position no longer depends on the
  parent's height, so the height may be derived from the child.

And a child in a `Row` gets **no width of its own**. `StatCard` rendered as nothing at all until
it was given an explicit `width` — a `BorderSurface` at width 0 draws nothing and reports no
error.

## Nerd Font glyphs are code points, not pasted characters

The MDI glyphs this plugin uses all live above U+FFFF. Pasted into a `.qml` as literal characters
they survive normal editing but not every re-encoding, and a truncated four-byte sequence silently
becomes a *different* symbol — that is how `U+F0992` (plus-minus) once shipped as the "reset"
icon. They are held as code points and built with `root.mdi(0xF0450)`, with the MDI name in a
trailing comment so the next person can tell what it is meant to be without rendering it.
`tests/run-all.sh` fails on a pasted PUA glyph in any `.qml`.

**Verify a new glyph by looking at it**, not by checking the font covers it — coverage says
nothing about whether the code point is the icon you meant:

```bash
F=$(fc-match -f '%{file}' 'JetBrainsMono Nerd Font')
printf '\U000F0450 F0450   \U000F0167 F0167\n' > /tmp/g.txt
magick -background '#101315' -fill '#cacccc' -font "$F" -pointsize 26 label:@/tmp/g.txt /tmp/g.png
```

# Tests and verification

## The parts can all be right while the trip is broken

`tests/test-journey.sh` is the only suite that is not about a function. It stands two fake machines
up with their own `$HOME` and a bare repo in place of GitHub, and walks the thing the plugin
actually promises: the desktop saves, the laptop clones, restores, and ends up feeling like home
without inheriting what was only ever true of the desktop — then edits something and the desktop
picks it up.

It was written last and immediately found two things every unit test had passed over:

- **A clone can succeed and check out nothing.** When the remote's default branch is not the one
  the commits are on, git says "remote HEAD refers to nonexistent ref" and leaves an empty
  directory. Every restore afterwards reported "nothing to change" for every category — a restore
  tool announcing success having restored nothing. `cmd_clone` now checks `rev-parse HEAD` and
  names the branches that do have commits.
- **`--yes` was only honoured through `--all`**, so `restore --apply --only hyprland --yes` still
  stopped to ask, and with no terminal to ask on it died on `/dev/tty` and skipped the category.
  The panel had been passing `--all` *together with* `--only` to get around it, which reads like a
  contradiction because it was one.

Both are the same shape: a whole-journey failure that sits in the gap between two functions that
are each correct.

## A test fixture that looks like a credential IS one

`tests/test-cli.sh` checks the secret scanner one shape at a time, and the first
version wrote each shape out whole. GitHub's push protection rejected the commit —
correctly. Every scanner in the chain, theirs and ours, sees a string, not an
intention, and a repo that cannot be pushed is worse than a test that is slightly
awkward to read.

The prefixes are therefore assembled from pieces (`P_SLACK="xo""xb-"`), so the file
on disk contains no scannable token while the string handed to the scanner is exact.
Run `bin/scan-secrets.sh tests bin` before committing anything that adds one.

## A test must never open a window on the user's screen

`tests/test-cli.sh` exercises `edit --wait`, and its fake `$HOME` did nothing to stop the command
from finding the machine's real `omarchy-launch-editor`: the suite opened nvim on the screen of
whoever was running it, twice, on a file called `input.lua` that was not theirs. Stub every escape
hatch (`omarchy-launch-editor`, `xdg-open`, and the editor named in the fixture) into a directory
placed first on `PATH`. This is not only manners — a window the user closes mid-measurement changes
what the command returns, so the test can lie.

## `grep -q` on a pipeline under `pipefail` reports failure on success

`plan_for_category "$c" | grep -q "$x"` fails for every match that is not the last line: `grep -q`
exits at the first hit, the writer takes a SIGPIPE, and `set -o pipefail` turns that into a
non-zero pipeline. Capture first (`p=$(plan_for_category "$c"); grep -qF "$x" <<<"$p"`). This cost
a confusing test failure where the value being searched for was visibly present in the output.

## Verify before calling it done

**shellcheck is not optional and a missing one is not a pass.** For four releases the section
printed "skipped" in yellow and the suite still ended in "Everything passed". `run-all.sh` looks on
`PATH` then in `~/.local/share/mise/shims`, and **fails** when it finds neither:

```bash
mise use -g shellcheck@latest     # no root, and it travels in the tracked mise/config.toml
```

The first run it ever had found `SC2318` in `suggest_skip_reason`: `local f="$1" base="${f##*/}"`
reads an `$f` the same line has not assigned yet, so every check in that function computed from the
*caller's* scope — and worked only because the one caller happens to name its loop variable `f` too.
**Bash scopes dynamically, so a name collision substitutes for a real value and nothing errors.**
That is why `category_field`/`setting_field` no longer call their split array `f` either.

- **`./tests/run-all.sh`** — the four suites (core, settings, CLI, journey) plus `bash -n`, shellcheck,
  qmllint, the QML-trap greps and `omarchy-plugin-validate`. This is the one command; everything
  below it is what that command already does, plus the things a script cannot check.

  It takes about **five minutes**, which is long enough that waiting for it after every edit is
  most of a session. While iterating, run the one suite that covers what you touched; keep the
  full run for before the commit.

  | suite | time | covers |
  | --- | ---: | --- |
  | `tests/test-settings.sh` | 59 s | the SETTINGS registry and its writers |
  | `tests/test-core.sh` | 33 s | MANIFEST, scopes, state, the JSON payloads |
  | `tests/test-cli.sh` | 23 s | subcommands, purge, backups, `--help` |
  | `tests/test-journey.sh` | 17 s | two machines and one repo, end to end |

- **Mutation testing is how you find out whether the suite is lying.** Copy the repo, break one
  line of production code, run the suites, revert. Anything nobody notices is a coverage hole with
  a name. Fourteen mutations found three: the prune pass's `is_excluded` guard, `lid_blocked_by`
  (no test referenced it at all), and `plural`. The first one guards documented, silent data loss.

  It also found the shape to watch for: **a section named after a guarantee it does not check.**
  "switching a file off keeps what the repo already had" tested `hypr/monitors.lua`, which is
  profile-scoped out of the box and so never had a `config/` copy to keep — every check in it
  passed whether or not the prune pass honoured the off list.

- **Measure before refactoring anything about noise or cost.** The inventory purge came out of one
  command, not an opinion — and it named files nobody would have guessed:

  ```bash
  git -C "$REPO" log -200 --name-only --format='' -- . | grep -v '^$' | sort | uniq -c | sort -rn
  ```
- `omarchy-plugin-validate` on this directory after any structural change.
- Reload the plugin and visually inspect with `grim` (bar icon + open panel).
- `omarchy-replicant status --json | jq '.configs[] | {id, sync_state}'` after forcing the states
  by hand on a test file (one untouched, one edited and NOT saved, one committed but unpushed,
  one committed and pushed) — confirm `default`/`unsaved`/`unpushed`/`saved` show up correctly.
- `omarchy-replicant reset-all --dry-run` and `omarchy-replicant restore --dry-run` must not
  touch any file — compare hashes before/after if in doubt.

# Maintaining this file

## Adding to this file

It is six hundred lines. Nobody reads six hundred lines before touching code — including the
assistant it is written for — so every addition spends attention the existing rules were paying
for. It grew by a fifth in a single session, which is how a set of rules quietly becomes an
archive.

- A section earns its place by describing a bug that **cost more than an hour** and that
  **re-reading the code would not have prevented**. Everything else belongs in a comment beside
  the thing it is about, where it is read at exactly the right moment instead of hopefully.
- **Rule first, story second.** Several sections here still open with six lines of narrative
  before saying what to do.
- A new instance of an existing rule is **a row in that rule's table**, not a second section.
- Adding something is a good moment to check whether something else has stopped being true.
