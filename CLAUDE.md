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

## Hard rules

1. **Never edit `/usr/share/omarchy/` or `~/.local/share/omarchy`** (symlink to the pacman
   package). It gets overwritten on every `omarchy update` — any change there is lost, and it
   can also break "is this identical to the default" detection (`is_default_file()` in
   `bin/replicant-core.sh`), which compares directly against those paths.
2. **Any operation that writes to the real system is dry-run by default** (`reset-all`,
   `restore`) and **backs up as `.bak.<epoch>`** before overwriting an existing file (`poner()`
   in `bin/replicant-core.sh`). Don't add a new writing command that skips this pattern.
3. **`reset-all` (everything → Omarchy defaults) and `restore --apply --all` (everything → what's
   saved on GitHub) are two distinct actions** — never merge them. The UI (`Panel.qml`, the
   **Restore** tab) and the CLI keep them as separate commands so the user never confuses
   "factory" with "what's in my repo".
4. **Any visual change to `Panel.qml`/`BarWidget.qml` is verified with a real screenshot**
   (`grim`) after reloading the plugin — a process not crashing, or just reading the QML, is not
   enough. `state.configs[].sync_state` is the source of truth for the 3 badges (○ default /
   ● modified / ◆ saved); if a new state is added, verify it by actually triggering it on a test
   file, not just by reading the code.
5. **Global destructive commands ask for a single summary confirmation** (not per-file) unless
   `--yes`/`-y` is passed explicitly — this applies to `reset-all` and `restore --apply --all`.
6. **The panel never opens a terminal the user has to dismiss.** Editing a file launches the
   editor directly (`omarchy-launch-editor`), a diff renders inline in the panel, and a
   destructive action confirms in the panel and then runs headless with `--yes`. The one
   exception is `create` and `clone`, which genuinely prompt (GitHub login, a repo URL).
   `omarchy-launch-floating-terminal-with-presentation` wraps whatever it runs in the Omarchy
   logo *and* a "press a key to close" prompt, so using it for a read-only action costs two
   interactions to see one file. The user asked for this to stop; don't reintroduce it.
7. **Names that are already taken.** `state` is a built-in property of every QML Item (see below),
   and `GROUPS` is a bash special variable — `local GROUPS=(...)` aborts the enclosing function
   with "variable may not be assigned value", which silently turned `restore` into a no-op for
   an entire release. Before naming a shell array or a QML property, check it is yours to use.

## Repo conventions

- `bin/omarchy-replicant` is the CLI (subcommand parsing, terminal UX); `bin/replicant-core.sh`
  is the pure logic (MANIFEST, backup, state detection, JSON for the panel) — don't duplicate
  business logic in the CLI, it belongs in the core.
- Third-party plugin auto-discovery (`discover_plugin_entries()` in `replicant-core.sh`):
  convention = `~/.config/omarchy/<last-segment-of-id>.json` next to the plugin's
  `manifest.json`. If a new plugin doesn't follow that convention, it won't show up on its
  own — that's not a bug, it's the deliberate limit of a generic, registry-free detector.
- **Adding a setting is one line** in the `SETTINGS` registry in `replicant-core.sh`: 13
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

## Quickshell caches compiled QML — clear it or you are testing old code

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

## Verify before calling it done

- **`./tests/run-all.sh`** — the three suites (core, settings, CLI) plus `bash -n`, shellcheck,
  qmllint, the QML-trap greps and `omarchy-plugin-validate`. This is the one command; everything
  below it is what that command already does, plus the things a script cannot check.
- `omarchy-plugin-validate` on this directory after any structural change.
- Reload the plugin and visually inspect with `grim` (bar icon + open panel).
- `omarchy-replicant status --json | jq '.configs[] | {id, sync_state}'` after forcing all 3
  states by hand on a test file (one untouched, one edited but uncommitted, one committed and
  pushed) — confirm `default`/`modified`/`saved` show up correctly.
- `omarchy-replicant reset-all --dry-run` and `omarchy-replicant restore --dry-run` must not
  touch any file — compare hashes before/after if in doubt.
