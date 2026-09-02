# Omarchy Replicant — plugin (code)

An Omarchy 4 plugin (Hyprland + Quickshell/QML) that adds `omarchy-replicant`: saves the user's
configuration into a **private** GitHub repo of their own (created automatically) and restores
it on any machine. A port, as an installable plugin, of the [[omarchy_thinkpad]] pattern
(`~/omarchy_thinkpad`) — not copied literally, adapted to be portable across machines instead of
tied to one.

This repo is **only the plugin's code** (public, distributable via `omarchy plugin add`). The
user's actual data (dotfiles, secrets, inventory) lives in the sibling repo
**`omarchy-replicant`** (private) — never mix the two. The plugin must not hardcode anything
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
   saved on GitHub) are two distinct actions** — never merge them. The UI (`Panel.qml`, "Danger
   zone" section) and the CLI keep them as separate commands so the user never confuses "factory"
   with "what's in my repo".
4. **Any visual change to `Panel.qml`/`BarWidget.qml` is verified with a real screenshot**
   (`grim`) after reloading the plugin — a process not crashing, or just reading the QML, is not
   enough. `state.configs[].sync_state` is the source of truth for the 3 badges (○ default /
   ● modified / ◆ saved); if a new state is added, verify it by actually triggering it on a test
   file, not just by reading the code.
5. **Global destructive commands ask for a single summary confirmation** (not per-file) unless
   `--yes`/`-y` is passed explicitly — this applies to `reset-all` and `restore --apply --all`.

## Repo conventions

- `bin/omarchy-replicant` is the CLI (subcommand parsing, terminal UX); `bin/replicant-core.sh`
  is the pure logic (MANIFEST, backup, state detection, JSON for the panel) — don't duplicate
  business logic in the CLI, it belongs in the core.
- Third-party plugin auto-discovery (`discover_plugin_entries()` in `replicant-core.sh`):
  convention = `~/.config/omarchy/<last-segment-of-id>.json` next to the plugin's
  `manifest.json`. If a new plugin doesn't follow that convention, it won't show up on its
  own — that's not a bug, it's the deliberate limit of a generic, registry-free detector.
- `MANIFEST`/`SECRETS_MANIFEST` are deliberately fixed, explicit lists for the "core" dotfiles
  (shell, ssh, git, hypr, etc.) — don't turn them into generic auto-discovery, you'd lose the
  guarantee that only what a human decided to track gets tracked.
- Commits to this repo (code) use normal engineering messages — don't confuse this with the
  "one commit per decision, with the why" convention of the **data** repo, which is a different
  thing and lives in the other repo.

## Verify before calling it done

- `omarchy-plugin-validate` on this directory after any structural change.
- Reload the plugin and visually inspect with `grim` (bar icon + open panel).
- `omarchy-replicant status --json | jq '.configs[] | {id, sync_state}'` after forcing all 3
  states by hand on a test file (one untouched, one edited but uncommitted, one committed and
  pushed) — confirm `default`/`modified`/`saved` show up correctly.
- `omarchy-replicant reset-all --dry-run` and `omarchy-replicant restore --dry-run` must not
  touch any file — compare hashes before/after if in doubt.
