# Gate Third-Party Plugin/Theme Reinstalls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop `restore` from silently reinstalling third-party themes/plugins
from their origin's *current* HEAD, and replace it with an explicit,
per-item action the user takes on purpose — closing the
remote-git-execution-unpinned pattern a marketplace security review found at
`bin/omarchy-replicant:530` and `:585`, without touching the unrelated
finding at `:469` (cloning the user's own private repo, which is not a
third-party trust boundary and stays exactly as it is).

**Architecture:** No new subsystem. `missing_themes`/`missing_plugins`
already compute exactly the list that needs a decision; today that list is
consumed once, automatically, inside `cmd_restore`. This plan: (1) gives each
entry in that list a standalone install path (`core_install_theme` /
`core_install_plugin` in the core, `install-theme` / `install-plugin` as CLI
subcommands — the same split `core_restore_file` / `restore-file` already
uses for one tracked file), (2) makes `cmd_restore`'s existing
`restore_themes` / `restore_plugins` report-only instead of installing, (3)
exposes the pending list to the panel as its own JSON array so it can render
one row with one button per item, matching the existing per-category row
pattern in the Restore tab, and (4) tells terminal-only users about it too,
through `doctor`.

**Tech Stack:** bash (`bin/replicant-core.sh`, `bin/omarchy-replicant`), QML
(`Panel.qml`), the existing test harness (`tests/test-core.sh`,
`tests/test-cli.sh`, `tests/test-journey.sh`, `tests/run-all.sh`), `jq`. No
new dependencies.

**Spec:** This plan's spec is this conversation's investigation (no separate
spec doc). Summary: a marketplace automated review flagged unpinned
`git clone`/`git fetch` followed by code being trusted. Two call sites were
conflated in the original finding:

- `bin/omarchy-replicant:469` (`cmd_clone`) and `cmd_pull` (`:425-461`) —
  clone/fetch the user's own private backup repo. No third party can move
  that ref, nothing there is executed as code, and pinning it would break
  the tool's purpose (bring down the latest state pushed from another
  machine). **Not in scope for this plan** — this is the correct rebuttal to
  give the marketplace reviewer, and no code changes it.
- `bin/omarchy-replicant:530` (`omarchy theme install "$torigin"`) and `:585`
  (`omarchy plugin add "$porigin" --enable --yes`), both inside `cmd_restore`
  — reinstall third-party themes/plugins from a recorded origin URL, at
  whatever that origin's current HEAD is, automatically, during `restore`.
  Neither `omarchy theme install` nor `omarchy plugin add` accepts a ref/tag
  argument (confirmed via `omarchy theme --help` / `omarchy plugin --help`),
  so a literal commit-pin fix is not available at this call site without
  abandoning Omarchy's own plugin/theme management. **This is the fix in
  scope**: replace "automatic, silent, on every restore" with "one explicit
  action, reviewed by the user, at the moment they choose."

## Global Constraints

- Every write to the real machine stays dry-run-by-default and keeps a
  `.bak.<epoch>` where it overwrites a file (CLAUDE.md hard rule 2) — not
  directly applicable to `install-theme`/`install-plugin` themselves (they
  don't overwrite existing tracked files), but `restore`'s existing dry-run
  behavior for everything else must not regress.
- Global destructive commands ask once, not per file (CLAUDE.md hard rule
  5) — the new per-item Install buttons are a *deliberate, documented*
  exception to that rule for this one case (fetching a third party's current
  code is a different risk class than overwriting a file the user already
  reviewed once in their own manifest), and Task 7 writes that exception
  into CLAUDE.md explicitly so it is never "fixed" back to auto-install.
- The panel never opens a terminal the user has to dismiss (hard rule 6) —
  the new Install button goes through the existing `root.ask()` /
  `dangerProc` flow, same as every other panel action.
- `bin/omarchy-replicant` is CLI/terminal-UX only; `bin/replicant-core.sh` is
  the pure logic — new business logic (resolving an id to its origin,
  calling the right Omarchy command) goes in the core, and the CLI functions
  are thin wrappers, matching `core_restore_file` / `cmd_restore_file`.
- No Spanish anywhere in code, comments, commit messages, CLI output, or
  panel text (project language rule) — every string this plan adds is
  English.
- Any visual change to `Panel.qml` is verified with a real `grim` screenshot
  after reloading the plugin, not just by reading the QML (hard rule 4).
- A new Nerd Font glyph must be verified by rendering it, not just checked
  for font coverage — this plan avoids that cost entirely by reusing an
  existing icon property (`icFolder`), per Task 6.

---

## File Structure

| File | Responsibility in this plan |
| --- | --- |
| `bin/replicant-core.sh` | `core_install_theme`, `core_install_plugin` (resolve id → origin, call the right Omarchy command); `build_pending_reinstalls_json`; wiring into `status --json` |
| `bin/omarchy-replicant` | `cmd_install_theme`, `cmd_install_plugin` (thin CLI wrappers); dispatcher + `usage()` + `HELP` entries; `restore_themes`/`restore_plugins` inside `cmd_restore` become report-only; `cmd_doctor` gains a pending-reinstalls check |
| `Panel.qml` | `pendingReinstalls` computed property; a new Restore-tab section rendering one row per pending item; `install-theme`/`install-plugin` branches in `runConfirmed()` |
| `tests/test-core.sh` | Unit tests for `core_install_theme`, `core_install_plugin`, `build_pending_reinstalls_json` |
| `tests/test-cli.sh` | Tests for the new subcommands, the help-surface check picking them up automatically, and that `restore --apply --all --yes` no longer calls `omarchy theme install`/`omarchy plugin add` |
| `tests/test-journey.sh` | End-to-end: the laptop's restore does not auto-install the desktop's third-party theme; `install-theme` does, on request |
| `CLAUDE.md` | Documents the hard-rule-5 exception and the reasoning, in the existing "Big things are inventoried, never copied" section |

---

### Task 1: Core — `core_install_theme` and `core_install_plugin`

**Files:**
- Modify: `bin/replicant-core.sh` (new functions immediately after `missing_themes`, currently ending around line 3419 — after the closing `}` of `missing_themes` and before the `local_only_themes` comment block)
- Test: `tests/test-core.sh` (new section after "themes travel as URLs, not as 556 MB of wallpaper", currently ending at line 799)

**Interfaces:**
- Produces: `core_install_theme <name>` — looks `<name>` up in `missing_themes`, runs `omarchy theme install <origin>`, prints `"<name> installed from <origin>"` to stderr and returns 0 on success; prints an error to stderr and returns 1 if `<name>` is not a pending theme or the install fails.
- Produces: `core_install_plugin <id>` — same shape, over `missing_plugins`, respecting the `clone` vs `add` method column already recorded in the inventory.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test-core.sh`, right after line 799 (`check "a theme with no origin is never proposed for install" ...`):

```bash
section "installing one pending theme on demand"
mkdir -p "$TMP/fakebin"
FAKE_LOG="$TMP/omarchy-calls.log"
cat > "$TMP/fakebin/omarchy" <<EOF
#!/bin/bash
echo "\$*" >> "$FAKE_LOG"
exit 0
EOF
chmod +x "$TMP/fakebin/omarchy"
rm -f "$STATE_DIR/omarchy-themes.txt"
printf '# name\torigin\nmine\thttps://example.com/omarchy-mine-theme\n' > "$STATE_DIR/omarchy-themes.txt"
: > "$FAKE_LOG"
check_true "install-theme succeeds for a pending theme" \
  env PATH="$TMP/fakebin:$PATH" bash -c "source '$CORE' >/dev/null 2>&1; core_install_theme mine"
check_contains "…and calls omarchy theme install with the recorded origin" \
  "theme install https://example.com/omarchy-mine-theme" "$(cat "$FAKE_LOG")"
check_false "install-theme refuses an id that is not pending" \
  env PATH="$TMP/fakebin:$PATH" bash -c "source '$CORE' >/dev/null 2>&1; core_install_theme not-a-theme"

section "installing one pending plugin on demand"
mkdir -p "$STATE_DIR"
printf '# id\tversion\torigin\tmethod\ndemo.widget\t1.0.0\thttps://example.com/demo-widget\tadd\n' \
  > "$STATE_DIR/omarchy-plugins.txt"
: > "$FAKE_LOG"
check_true "install-plugin succeeds for a pending plugin" \
  env PATH="$TMP/fakebin:$PATH" bash -c "source '$CORE' >/dev/null 2>&1; core_install_plugin demo.widget"
check_contains "…and calls omarchy plugin add with the recorded origin" \
  "plugin add https://example.com/demo-widget --enable --yes" "$(cat "$FAKE_LOG")"
check_false "install-plugin refuses an id that is not pending" \
  env PATH="$TMP/fakebin:$PATH" bash -c "source '$CORE' >/dev/null 2>&1; core_install_plugin not-a-plugin"
```

Note: `$STATE_DIR`, `$CORE` and `$TMP` are already exported/defined earlier
in `tests/test-core.sh`; the `env PATH=... bash -c "source ...; ..."`
subshell is needed only because the fake `omarchy` must be found on `PATH`
inside a fresh shell that still has `replicant-core.sh` sourced — the
top-level test shell already sourced it once without the fake `PATH` in
place.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./tests/test-core.sh 2>&1 | tail -30`
Expected: FAIL — `core_install_theme: command not found` / `core_install_plugin: command not found`.

- [ ] **Step 3: Write the minimal implementation**

In `bin/replicant-core.sh`, immediately after the closing `}` of
`missing_themes` (after the line `done | sort -u` around line 3419), add:

```bash
# core_install_theme <name> — install ONE third-party theme from its recorded
# origin, on demand. Never called automatically: `restore` only ever reports
# a theme as pending (see restore_themes in the CLI) and this is the explicit
# action that actually fetches whatever is at that origin right now.
core_install_theme() {
  local want="${1:-}" tname torigin
  [[ -n "$want" ]] || { echo "usage: install-theme <name>" >&2; return 1; }
  while IFS=$'\t' read -r tname torigin; do
    [[ "$tname" == "$want" ]] || continue
    command -v omarchy >/dev/null 2>&1 || { echo "omarchy not found on PATH" >&2; return 1; }
    omarchy theme install "$torigin" || { echo "$tname — omarchy theme install failed ($torigin)" >&2; return 1; }
    echo "$tname installed from $torigin" >&2
    return 0
  done < <(missing_themes)
  echo "$want is not a pending third-party theme (already installed, or not in the inventory)" >&2
  return 1
}

# core_install_plugin <id> — the same action for a plugin. `missing_plugins`
# already carries the method column that tells clone (an edited built-in)
# from add (a real third-party plugin) — same two commands restore_plugins
# already knew how to call, just no longer called without being asked.
core_install_plugin() {
  local want="${1:-}" pid porigin pmethod
  [[ -n "$want" ]] || { echo "usage: install-plugin <id>" >&2; return 1; }
  while IFS=$'\t' read -r pid porigin pmethod; do
    [[ "$pid" == "$want" ]] || continue
    command -v omarchy >/dev/null 2>&1 || { echo "omarchy not found on PATH" >&2; return 1; }
    if [[ "$pmethod" == "clone" ]]; then
      omarchy plugin clone "$porigin" || { echo "$pid — omarchy plugin clone failed" >&2; return 1; }
      echo "$pid re-cloned from $porigin (any edits you made are not in this)" >&2
    else
      omarchy plugin add "$porigin" --enable --yes || { echo "$pid — omarchy plugin add failed" >&2; return 1; }
      echo "$pid installed from $porigin" >&2
    fi
    return 0
  done < <(missing_plugins)
  echo "$want is not a pending third-party plugin (already installed, or not in the inventory)" >&2
  return 1
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./tests/test-core.sh 2>&1 | tail -30`
Expected: PASS — all checks in both new sections green.

- [ ] **Step 5: Commit**

```bash
git add bin/replicant-core.sh tests/test-core.sh
git commit -m "feat: add core_install_theme/core_install_plugin for on-demand reinstall"
```

---

### Task 2: Core — `build_pending_reinstalls_json` and wiring into `status --json`

**Files:**
- Modify: `bin/replicant-core.sh` (new function near `build_backups_json`, ~line 1077; wire into the `status --json` assembly at the block around lines 3048-3104)
- Test: `tests/test-core.sh` (new section after Task 1's)

**Interfaces:**
- Consumes: `missing_themes` (from Task 1's location), `missing_plugins` (`bin/replicant-core.sh:3386`).
- Produces: `build_pending_reinstalls_json` — prints a JSON array to stdout, one object per pending theme/plugin: `{kind:"theme"|"plugin", id, origin, method}` (`method` is `""` for themes, `"add"`/`"clone"` for plugins). Consumed by Task 6's QML as `root.repoState.pending_reinstalls`.

- [ ] **Step 1: Write the failing test**

Add to `tests/test-core.sh`, after Task 1's new sections:

```bash
section "pending reinstalls, as JSON for the panel"
rm -f "$STATE_DIR/omarchy-themes.txt" "$STATE_DIR/omarchy-plugins.txt"
printf '# name\torigin\nmine\thttps://example.com/omarchy-mine-theme\n' > "$STATE_DIR/omarchy-themes.txt"
printf '# id\tversion\torigin\tmethod\ndemo.widget\t1.0.0\thttps://example.com/demo-widget\tadd\n' \
  > "$STATE_DIR/omarchy-plugins.txt"
pr_json=$(build_pending_reinstalls_json)
check "valid JSON" "0" "$(jq empty <<<"$pr_json" >/dev/null 2>&1; echo $?)"
check "two entries" "2" "$(jq 'length' <<<"$pr_json")"
check "the theme entry" "theme" "$(jq -r '.[] | select(.id=="mine") | .kind' <<<"$pr_json")"
check "…with its origin" "https://example.com/omarchy-mine-theme" \
  "$(jq -r '.[] | select(.id=="mine") | .origin' <<<"$pr_json")"
check "the plugin entry" "plugin" "$(jq -r '.[] | select(.id=="demo.widget") | .kind' <<<"$pr_json")"
check "…with its method" "add" "$(jq -r '.[] | select(.id=="demo.widget") | .method' <<<"$pr_json")"
rm -f "$STATE_DIR/omarchy-themes.txt" "$STATE_DIR/omarchy-plugins.txt"
check "empty inventory yields an empty array" "0" "$(build_pending_reinstalls_json | jq 'length')"
```

- [ ] **Step 2: Run to verify it fails**

Run: `./tests/test-core.sh 2>&1 | tail -20`
Expected: FAIL — `build_pending_reinstalls_json: command not found`.

- [ ] **Step 3: Write the minimal implementation**

In `bin/replicant-core.sh`, near `build_backups_json` (before its definition
at line 1077, so the two JSON-for-the-panel builders for "things that need a
person's decision" sit together):

```bash
# build_pending_reinstalls_json — third-party themes/plugins the inventory
# knows about but this machine does not have. `restore` never installs these
# on its own (restore_themes/restore_plugins in the CLI only report them) —
# this is the list the panel renders as its own row, one Install button per
# item, so fetching someone else's current code is always a decision made in
# the moment, not a side effect of "bring my stuff back".
build_pending_reinstalls_json() {
  {
    while IFS=$'\t' read -r tname torigin; do
      [[ -n "$tname" ]] || continue
      jq -nc --arg id "$tname" --arg origin "$torigin" \
        '{kind:"theme", id:$id, origin:$origin, method:""}'
    done < <(missing_themes)
    while IFS=$'\t' read -r pid porigin pmethod; do
      [[ -n "$pid" ]] || continue
      jq -nc --arg id "$pid" --arg origin "$porigin" --arg method "$pmethod" \
        '{kind:"plugin", id:$id, origin:$origin, method:$method}'
    done < <(missing_plugins)
  } | jq -sc '.'
}
```

Then wire it into `status --json`. In the block that builds the other
`*_json` variables (around line 3048):

```bash
    local configs_json secrets_json settings_json categories_json groups_json machines_json
    configs_json=$(build_configs_json)
    secrets_json=$(build_secrets_json)
    settings_json=$(build_settings_json)
    categories_json=$(build_categories_json)
    groups_json=$(build_setting_groups_json)
```

becomes:

```bash
    local configs_json secrets_json settings_json categories_json groups_json machines_json pending_reinstalls_json
    configs_json=$(build_configs_json)
    secrets_json=$(build_secrets_json)
    settings_json=$(build_settings_json)
    categories_json=$(build_categories_json)
    groups_json=$(build_setting_groups_json)
    pending_reinstalls_json=$(build_pending_reinstalls_json)
```

And in the final `jq -nc` call that assembles the whole object (around line
3089), add the new arg and field:

```bash
      --argjson setting_groups "$groups_json" --argjson machines "$machines_json" \
      --arg profile "$(current_profile)" --argjson profiles "$profiles_json" \
      '{initialized:true, branch:$branch, remote:$remote, remote_name:$remote_name,
        repo_dir:$repo_dir, machine:$machine, plugin_version:$plugin_version, home:$home,
        profile:$profile, profiles:$profiles,
        last_save:$last_save, last_subject:$last_subject,
        dirty:$dirty, untracked:$untracked, ahead:$ahead, behind:$behind, pending:$pending,
        unsaved:$unsaved, incoming:$incoming,
        configs:$configs, secrets:$secrets, settings:$settings,
        categories:$categories, setting_groups:$setting_groups, machines:$machines}'
```

becomes:

```bash
      --argjson setting_groups "$groups_json" --argjson machines "$machines_json" \
      --arg profile "$(current_profile)" --argjson profiles "$profiles_json" \
      --argjson pending_reinstalls "$pending_reinstalls_json" \
      '{initialized:true, branch:$branch, remote:$remote, remote_name:$remote_name,
        repo_dir:$repo_dir, machine:$machine, plugin_version:$plugin_version, home:$home,
        profile:$profile, profiles:$profiles,
        last_save:$last_save, last_subject:$last_subject,
        dirty:$dirty, untracked:$untracked, ahead:$ahead, behind:$behind, pending:$pending,
        unsaved:$unsaved, incoming:$incoming,
        configs:$configs, secrets:$secrets, settings:$settings,
        categories:$categories, setting_groups:$setting_groups, machines:$machines,
        pending_reinstalls:$pending_reinstalls}'
```

- [ ] **Step 4: Run to verify it passes**

Run: `./tests/test-core.sh 2>&1 | tail -20`
Expected: PASS.

Also run: `./tests/test-core.sh 2>&1 | grep -c '✗'` → expect `0` (nothing else
regressed — `status --json is well-formed`, section at line 661, exercises
the full assembly this task touched).

- [ ] **Step 5: Commit**

```bash
git add bin/replicant-core.sh tests/test-core.sh
git commit -m "feat: expose pending third-party reinstalls in status --json"
```

---

### Task 3: CLI — `install-theme` and `install-plugin` subcommands

**Files:**
- Modify: `bin/omarchy-replicant` (new `cmd_install_theme`/`cmd_install_plugin` near `cmd_restore_file` at line 1011; dispatcher case block at line ~1608; `usage()` heredoc at line ~1431; `HELP` array at line ~1554)
- Test: `tests/test-cli.sh`

**Interfaces:**
- Consumes: `core_install_theme`, `core_install_plugin` (Task 1).
- Produces: `omarchy-replicant install-theme <name>`, `omarchy-replicant install-plugin <id>` — exit 0 on success, exit 1 with a message on stderr otherwise.

- [ ] **Step 1: Write the failing test**

Add to `tests/test-cli.sh`, after the "doctor is read-only" section (around
line 273):

```bash
section "install-theme / install-plugin are on-demand, not part of restore"
mkdir -p "$TMP/fakebin"
FAKE_LOG="$TMP/omarchy-calls.log"
cat > "$TMP/fakebin/omarchy" <<EOF
#!/bin/bash
echo "\$*" >> "$FAKE_LOG"
exit 0
EOF
chmod +x "$TMP/fakebin/omarchy"
# MACHINE in replicant-core.sh is `hostnamectl --static` first, plain
# `hostname` as its fallback — never `hostname -s`. Guessing it from the test
# host's real hostname would silently point at the wrong state directory, so
# REPLICANT_MACHINE pins it to a fixed, test-only value instead.
STATEDIR="$REPO/state/testhost"
mkdir -p "$STATEDIR"
printf '# name\torigin\nmine\thttps://example.com/omarchy-mine-theme\n' > "$STATEDIR/omarchy-themes.txt"
: > "$FAKE_LOG"
check_true "install-theme installs a pending theme" \
  env PATH="$TMP/fakebin:$PATH" REPLICANT_MACHINE=testhost "$CLI" install-theme mine
check_contains "…by calling omarchy theme install" \
  "theme install https://example.com/omarchy-mine-theme" "$(cat "$FAKE_LOG")"
check_false "install-theme with no name fails" \
  env PATH="$TMP/fakebin:$PATH" REPLICANT_MACHINE=testhost "$CLI" install-theme
check_false "install-plugin with no id fails" \
  env PATH="$TMP/fakebin:$PATH" REPLICANT_MACHINE=testhost "$CLI" install-plugin
```

(This section runs after the repo already exists from earlier sections in
the file — `STATEDIR` mirrors how `$REPO` and the machine's state directory
are addressed elsewhere in this suite. `REPLICANT_MACHINE=testhost` must be
passed on every `$CLI` call in this section and Task 4's, so they all agree
on which state directory holds the fixture.)

- [ ] **Step 2: Run to verify it fails**

Run: `./tests/test-cli.sh 2>&1 | tail -20`
Expected: FAIL — `unknown command install-theme`.

- [ ] **Step 3: Write the minimal implementation**

In `bin/omarchy-replicant`, immediately after `cmd_restore_file` (after its
closing `}` at line 1018):

```bash
# cmd_install_theme <name> — install ONE third-party theme recorded in the
# inventory, on request. `restore` reports these as pending and never installs
# them itself (see restore_themes below) — this is the explicit action.
cmd_install_theme() {
  local name="${1:-}"
  [[ -n "$name" ]] || fail "usage: omarchy-replicant install-theme <name>"
  ensure_core
  # shellcheck disable=SC1090
  source "$CORE" 2>/dev/null || true
  core_install_theme "$name" || exit 1
}

# cmd_install_plugin <id> — the same action for a plugin.
cmd_install_plugin() {
  local id="${1:-}"
  [[ -n "$id" ]] || fail "usage: omarchy-replicant install-plugin <id>"
  ensure_core
  # shellcheck disable=SC1090
  source "$CORE" 2>/dev/null || true
  core_install_plugin "$id" || exit 1
}
```

In the dispatcher `case "$cmd" in` block (line ~1648, right before
`restore) shift; cmd_restore "$@";;`):

```bash
    clone) shift; cmd_clone "$@";;
    restore) shift; cmd_restore "$@";;
```

becomes:

```bash
    clone) shift; cmd_clone "$@";;
    install-theme) shift; cmd_install_theme "$@";;
    install-plugin) shift; cmd_install_plugin "$@";;
    restore) shift; cmd_restore "$@";;
```

In `usage()` (line ~1431), under the "Putting things back" section:

```
Putting things back            (dry run by default; .bak.<epoch> kept for everything)
  restore [--apply] [--all] [--only <area>] [--yes]
                              Everything, or one area, from the repo
  restore-file <id>           One file or directory back from the repo
  reset <id>                  One file back to Omarchy's default
  reset-all [--apply] [--yes] Everything with a known default back to factory
```

becomes:

```
Putting things back            (dry run by default; .bak.<epoch> kept for everything)
  restore [--apply] [--all] [--only <area>] [--yes]
                              Everything, or one area, from the repo
  restore-file <id>           One file or directory back from the repo
  reset <id>                  One file back to Omarchy's default
  reset-all [--apply] [--yes] Everything with a known default back to factory
  install-theme <name>        Install one third-party theme from your inventory — never automatic
  install-plugin <id>         Install one third-party plugin from your inventory — never automatic
```

In the `HELP` array (line ~1585), after the `[restore]` entry:

```bash
  [restore]="restore [--apply] [--all] [--only <area>] [--yes]
  Put back what is saved in your repo. A dry run by default, and every file it
  overwrites is kept as .bak.<epoch> first.
  Restoring is not copying: each area also runs what has to happen afterwards —
  hyprctl reload, a terminal restart, omarchy-theme-set, plugin reinstalls.
  This is not the same thing as 'reset-all', which goes to Omarchy's defaults."
)
```

becomes:

```bash
  [restore]="restore [--apply] [--all] [--only <area>] [--yes]
  Put back what is saved in your repo. A dry run by default, and every file it
  overwrites is kept as .bak.<epoch> first.
  Restoring is not copying: each area also runs what has to happen afterwards —
  hyprctl reload, a terminal restart, omarchy-theme-set. Third-party plugins
  and themes are NOT reinstalled by this command — see 'install-theme' /
  'install-plugin'. This is not the same thing as 'reset-all', which goes to
  Omarchy's defaults."
  [install-theme]="install-theme <name>
  Install one third-party theme recorded in your inventory, fetching whatever
  is at its origin right now. 'restore' only ever reports these as pending —
  this is the action that actually fetches one, on purpose."
  [install-plugin]="install-plugin <id>
  The same thing for a plugin: 'restore' reports it as pending, this installs
  it, fetching whatever is at its origin right now."
)
```

- [ ] **Step 4: Run to verify it passes**

Run: `./tests/test-cli.sh 2>&1 | tail -30`
Expected: PASS, including the pre-existing "every command the dispatcher
accepts is in --help" self-check (it derives the command list from the
dispatcher automatically — no change needed there).

- [ ] **Step 5: Commit**

```bash
git add bin/omarchy-replicant tests/test-cli.sh
git commit -m "feat: add install-theme/install-plugin subcommands"
```

---

### Task 4: The actual fix — `restore` stops installing third-party code on its own

**Files:**
- Modify: `bin/omarchy-replicant` (`restore_themes` at line 521, `restore_plugins` at line 566, and their two call sites at lines 609/613, inside `cmd_restore`)
- Test: `tests/test-cli.sh`, `tests/test-journey.sh`

**Interfaces:**
- Consumes: `missing_themes`, `missing_plugins` (unchanged), `skip()` (existing CLI helper).
- Produces: `restore_themes` / `restore_plugins` no longer take a `dry` argument (installing was the only thing that argument changed) and never call `omarchy theme install` / `omarchy plugin add`.

- [ ] **Step 1: Write the failing tests**

In `tests/test-cli.sh`, extend the section added in Task 3:

```bash
section "restore never installs third-party code on its own"
: > "$FAKE_LOG"
out=$(env PATH="$TMP/fakebin:$PATH" REPLICANT_MACHINE=testhost "$CLI" restore --apply --all --yes 2>&1)
check "restore --apply --all --yes does not call omarchy theme install" "0" \
  "$(grep -c 'theme install' "$FAKE_LOG" || true)"
check_contains "…and says how to install it instead" "install-theme mine" "$out"
```

In `tests/test-journey.sh`, near the top setup (after the `PROFILE_OF`
declaration around line 39, before "the desktop, with a setup worth
replicating"), add a fake `omarchy` on `PATH` for the whole suite:

```bash
# A fake `omarchy` recording every call it gets, so this suite can prove
# restore never fetches third-party code on its own — a real network call
# from a test would be its own bug, and nothing here caught it before.
mkdir -p "$TMP/fakebin"
export OMARCHY_FAKE_LOG="$TMP/omarchy-calls.log"
cat > "$TMP/fakebin/omarchy" <<'EOF'
#!/bin/bash
echo "$*" >> "$OMARCHY_FAKE_LOG"
exit 0
EOF
chmod +x "$TMP/fakebin/omarchy"
export PATH="$TMP/fakebin:$PATH"
```

Then extend the "the laptop restores" section (after line 184's
`on laptop restore --apply --all --yes >/dev/null 2>&1`):

```bash
check_false "the laptop did not auto-install the desktop's third-party theme" \
  test -d "$L/.config/omarchy/themes/mine"
check "…and restore never called omarchy theme install" "0" \
  "$(grep -c 'theme install' "$OMARCHY_FAKE_LOG" || true)"

section "installing a pending theme is a separate, explicit step"
: > "$OMARCHY_FAKE_LOG"
on laptop install-theme mine >/dev/null 2>&1
check_contains "install-theme calls omarchy theme install with the recorded origin" \
  "theme install https://example.com/omarchy-mine-theme" "$(cat "$OMARCHY_FAKE_LOG")"
```

- [ ] **Step 2: Run to verify they fail**

Run: `./tests/test-cli.sh 2>&1 | tail -20` and `./tests/test-journey.sh 2>&1 | tail -20`
Expected: FAIL — the fake log currently DOES contain a `theme install` call
from the automatic path.

- [ ] **Step 3: Write the minimal implementation**

In `bin/omarchy-replicant`, replace `restore_themes` (lines 521-537):

```bash
  restore_themes() {
    local dry="$1" tname torigin n=0
    while IFS=$'\t' read -r tname torigin; do
      [[ -n "$tname" ]] || continue
      n=$((n + 1))
      if (( dry )); then
        skip "dry-run: would run omarchy theme install $torigin  ($tname)" >&2
      else
        echo "  → omarchy theme install $torigin" >&2
        omarchy theme install "$torigin" >/dev/null 2>&1 \
          && ok "$tname installed" >&2 \
          || warn "$tname — omarchy theme install failed ($torigin)" >&2
      fi
    done < <(missing_themes)
    (( n == 0 )) && skip "every theme in the inventory is already installed" >&2
    return 0
  }
```

with:

```bash
  # A third-party theme is never installed by `restore` itself — see the
  # 2026-09 marketplace security review: `omarchy theme install` has no way
  # to pin a commit, so an automatic reinstall here silently trusts whatever
  # is at that origin TODAY, not what was there when the theme was first
  # installed. `install-theme <name>` is the explicit, on-purpose version of
  # this same action.
  restore_themes() {
    local tname torigin n=0
    while IFS=$'\t' read -r tname torigin; do
      [[ -n "$tname" ]] || continue
      n=$((n + 1))
      skip "$tname — third-party theme, not auto-installed: omarchy-replicant install-theme $tname" >&2
    done < <(missing_themes)
    (( n == 0 )) && skip "every theme in the inventory is already installed" >&2
    return 0
  }
```

Replace `restore_plugins` (lines 566-592):

```bash
  restore_plugins() {
    local dry="$1" pid porigin pmethod verb n=0
    while IFS=$'\t' read -r pid porigin pmethod; do
      [[ -n "$pid" ]] || continue
      n=$((n + 1))
      [[ "$pmethod" == "clone" ]] && verb="clone" || verb="add"
      if (( dry )); then
        skip "dry-run: would run omarchy plugin $verb $porigin  ($pid)" >&2
      else
        echo "  → omarchy plugin $verb $porigin" >&2
        if [[ "$verb" == "clone" ]]; then
          omarchy plugin clone "$porigin" >/dev/null 2>&1 \
            && ok "$pid re-cloned from $porigin (any edits you made are not in this)" >&2 \
            || warn "$pid — omarchy plugin clone failed" >&2
        else
          omarchy plugin add "$porigin" --enable --yes >/dev/null 2>&1 \
            && ok "$pid installed" >&2 || warn "$pid — omarchy plugin add failed" >&2
        fi
      fi
    done < <(missing_plugins)
    (( n == 0 )) && skip "every plugin in the inventory is already installed" >&2
    return 0
  }
```

with:

```bash
  # Same reasoning as restore_themes: a third-party plugin is code Quickshell
  # will run once enabled, so reinstalling it automatically on every restore
  # means silently trusting whatever the origin holds today. install-plugin
  # <id> is the explicit version.
  restore_plugins() {
    local pid porigin pmethod verb n=0
    while IFS=$'\t' read -r pid porigin pmethod; do
      [[ -n "$pid" ]] || continue
      n=$((n + 1))
      [[ "$pmethod" == "clone" ]] && verb="clone" || verb="add"
      skip "$pid — third-party plugin, not auto-installed: omarchy-replicant install-plugin $pid" >&2
    done < <(missing_plugins)
    (( n == 0 )) && skip "every plugin in the inventory is already installed" >&2
    return 0
  }
```

And update the two call sites (lines 609/613):

```bash
    if [[ "$cat" == "appearance" ]]; then
      restore_themes "$DRY"
      restore_theme "$DRY"
    fi
    if [[ "$cat" == "plugins" ]]; then
      restore_plugins "$DRY"
    fi
```

becomes:

```bash
    if [[ "$cat" == "appearance" ]]; then
      restore_themes
      restore_theme "$DRY"
    fi
    if [[ "$cat" == "plugins" ]]; then
      restore_plugins
    fi
```

(`restore_theme`, singular — applying an *already-installed* theme by name
via `omarchy-theme-set` — is untouched: that is a local action with no
third-party fetch, and keeps its dry-run distinction.)

- [ ] **Step 4: Run to verify they pass**

Run: `./tests/test-cli.sh 2>&1 | tail -20` and `./tests/test-journey.sh 2>&1 | tail -20`
Expected: PASS on both.

Also run the full suite once here, since this task touches a shared code
path exercised by several files: `./tests/run-all.sh 2>&1 | tail -40` —
expect no new failures (the shellcheck/qmllint/QML-trap sections are
untouched by this task, but a bash syntax slip in `cmd_restore` would show
up here first).

- [ ] **Step 5: Commit**

```bash
git add bin/omarchy-replicant tests/test-cli.sh tests/test-journey.sh
git commit -m "fix: restore no longer auto-installs third-party plugins/themes"
```

---

### Task 5: `doctor` tells terminal-only users about pending reinstalls

**Files:**
- Modify: `bin/omarchy-replicant` (`cmd_doctor`, inside the existing "Plugins" section ending around line 1113, and the existing "Themes" section starting at line 1128)
- Test: `tests/test-cli.sh`

**Interfaces:**
- Consumes: `missing_themes`, `missing_plugins` (already sourced into `cmd_doctor` via `source "$CORE"` at its top).
- Produces: two new `chk_warn` lines in `doctor`'s output when there are pending reinstalls, naming the exact command to run for each.

- [ ] **Step 1: Write the failing test**

Add to `tests/test-cli.sh`, in the "doctor is read-only" section (after line 273):

```bash
# Same REPLICANT_MACHINE=testhost reasoning as Task 3/4: MACHINE in
# replicant-core.sh comes from `hostnamectl --static` (or plain `hostname`),
# never `hostname -s` — pin it instead of guessing.
STATEDIR="$REPO/state/testhost"
mkdir -p "$STATEDIR"
printf '# name\torigin\nmine\thttps://example.com/omarchy-mine-theme\n' > "$STATEDIR/omarchy-themes.txt"
check_contains "doctor names a pending theme and the command to install it" \
  "install-theme mine" "$(env REPLICANT_MACHINE=testhost "$CLI" doctor 2>&1)"
rm -f "$STATEDIR/omarchy-themes.txt"
```

- [ ] **Step 2: Run to verify it fails**

Run: `./tests/test-cli.sh 2>&1 | tail -20`
Expected: FAIL — `doctor`'s output does not mention `install-theme`.

- [ ] **Step 3: Write the minimal implementation**

In `bin/omarchy-replicant`, in `cmd_doctor`'s "Themes" section, right after
the existing `chk_ok "$(plural "$n_inv" "user theme") recorded..."` line
(line 1137):

```bash
  chk_ok "$(plural "$n_inv" "user theme") recorded with an origin — reinstalled with 'omarchy theme install'"
```

add immediately below it:

```bash
  local pt n_pt
  pt=$(missing_themes 2>/dev/null || true)
  n_pt=$(printf '%s' "$pt" | grep -c . || true)
  if (( n_pt > 0 )); then
    chk_warn "$(plural "$n_pt" theme) recorded but not installed here — restore does not fetch these on its own:"
    printf '%s\n' "$pt" | awk -F'\t' '{print "      omarchy-replicant install-theme " $1}' >&2
  fi
```

In the "Plugins" section, right after the existing
`chk_ok "every installed plugin can be reinstalled from its origin"` /
`chk_warn "$(plural "$n_lo" plugin) exist only on this machine..."` branch
(after line 1074), add:

```bash
  local pp n_pp
  pp=$(missing_plugins 2>/dev/null || true)
  n_pp=$(printf '%s' "$pp" | grep -c . || true)
  if (( n_pp > 0 )); then
    chk_warn "$(plural "$n_pp" plugin) recorded but not installed here — restore does not fetch these on its own:"
    printf '%s\n' "$pp" | awk -F'\t' '{print "      omarchy-replicant install-plugin " $1}' >&2
  fi
```

- [ ] **Step 4: Run to verify it passes**

Run: `./tests/test-cli.sh 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/omarchy-replicant tests/test-cli.sh
git commit -m "feat: doctor names pending third-party reinstalls and how to install them"
```

---

### Task 6: Panel — one row, one Install button, per pending item

**Files:**
- Modify: `Panel.qml` (new `pendingReinstalls` property near `categoryCards` at line 296; new section in the Restore tab after the "Or just one area" `Repeater` at line 1312, before the `PanelSeparator` at line 1320; new `runConfirmed()` branches after line 557)

**Interfaces:**
- Consumes: `root.repoState.pending_reinstalls` (Task 2's JSON field), `root.ask()` / `root.busy` / `root.icFolder` (existing).
- Produces: a visible Restore-tab section, only when `root.pendingReinstalls.length > 0`.

- [ ] **Step 1: Add the computed property**

In `Panel.qml`, right after the `categoryCards` property closes (after line
318's closing `}`):

```qml
  // Third-party themes/plugins the inventory knows about but this machine
  // does not have. `restore` reports these, it never installs them — see
  // restore_themes/restore_plugins in the CLI. One row, one Install button,
  // so fetching someone else's current code is always a decision made here,
  // not a side effect of restoring your own settings.
  readonly property var pendingReinstalls: root.repoState.pending_reinstalls || []
```

- [ ] **Step 2: Add the `runConfirmed()` branches**

In `Panel.qml`, in `runConfirmed()`, right before the `else return` at line 561:

```bash
    else if (a === "restore-cat")  { root.busyLabel = "Restoring " + arg + "…"; dangerProc.command = [root.cli, "restore", "--apply", "--yes", "--only", arg] }
    else if (a === "untrack")      { root.doUntrack(arg); return }
```

becomes:

```bash
    else if (a === "restore-cat")  { root.busyLabel = "Restoring " + arg + "…"; dangerProc.command = [root.cli, "restore", "--apply", "--yes", "--only", arg] }
    else if (a === "install-theme")  { root.busyLabel = "Installing " + arg + "…"; dangerProc.command = [root.cli, "install-theme", arg] }
    else if (a === "install-plugin") { root.busyLabel = "Installing " + arg + "…"; dangerProc.command = [root.cli, "install-plugin", arg] }
    else if (a === "untrack")      { root.doUntrack(arg); return }
```

- [ ] **Step 3: Add the Restore-tab section**

In `Panel.qml`, right after the closing of the "Or just one area" `Repeater`
(after line 1312's `}` that closes the `delegate: Item { ... }`, still
before line 1314's `// ── the safety net ──` comment), insert:

```qml
            PanelSeparator { width: parent.width; visible: root.pendingReinstalls.length > 0 }
            PanelSectionHeader {
              width: parent.width
              text: "Third-party plugins & themes"
              foreground: root.fg; fontFamily: root.ff
              visible: root.pendingReinstalls.length > 0
            }
            Text {
              width: parent.width
              visible: root.pendingReinstalls.length > 0
              text: "Recorded in your inventory but not installed here. These come from someone else's repo, so restoring never fetches them on its own — Install brings in whatever is at that address right now."
              color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap
            }
            Repeater {
              model: root.pendingReinstalls
              delegate: Item {
                id: reinstallRow
                required property var modelData
                width: content.width
                implicitHeight: Style.space(30)
                Row {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(18)
                    text: root.icFolder
                    color: root.dim; font.family: root.ff; font.pixelSize: Style.font.body
                  }
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - Style.space(18) - reinstallBtn.width - parent.spacing * 2
                    text: reinstallRow.modelData.id + "   " + reinstallRow.modelData.origin
                    color: root.fg; font.family: root.ff; font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                  Button {
                    id: reinstallBtn
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Install"; iconText: root.icFromRepo; bordered: false
                    foreground: root.fg; fontFamily: root.ff
                    enabled: !root.busy
                    tooltipText: "Fetch " + reinstallRow.modelData.origin + " and install it now"
                    onClicked: root.ask(
                      reinstallRow.modelData.kind === "theme" ? "install-theme" : "install-plugin",
                      reinstallRow.modelData.id,
                      "Install the " + reinstallRow.modelData.kind + " \"" + reinstallRow.modelData.id + "\" from " + reinstallRow.modelData.origin + "?\n\nThis fetches whatever is at that address right now — not necessarily what you reviewed when you first installed it.",
                      "Install")
                  }
                }
              }
            }
```

- [ ] **Step 4: Reload and verify with a real screenshot**

Per CLAUDE.md hard rule 4, a QML change is verified with `grim`, not just by
reading the file:

```bash
rm -rf ~/.cache/quickshell/qmlcache
omarchy restart shell   # only if LockedHint=no AND no live PAM lock session — see CLAUDE.md
```

Then, with a machine whose `state/<host>/omarchy-themes.txt` has at least
one entry not installed locally (reuse the Task 1/2 fixture data against a
real throwaway `OMARCHY_REPLICANT_HOME`, or temporarily point
`OMARCHY_REPLICANT_HOME` at a scratch repo seeded the same way), open the
panel's Restore tab and confirm:
- the new "Third-party plugins & themes" section renders with one row
- the row shows the id and origin, elided correctly at panel width
- pressing "Install" opens the confirm dialog with the expected message
- take the screenshot: `grim -g "$(hyprctl activewindow -j | jq -r '.at | join(",") + " " + (.size|join("x"))' 2>/dev/null || true)" /tmp/panel-reinstalls.png` (or `grim` full-screen if that fails) and visually confirm layout is correct, no NaN heights, no truncation.

- [ ] **Step 5: Commit**

```bash
git add Panel.qml
git commit -m "feat: panel gates third-party plugin/theme reinstalls behind an explicit button"
```

---

### Task 7: Document the decision in CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

**Interfaces:** None (documentation only).

- [ ] **Step 1: Amend hard rule 5**

Find:

```
5. **Global destructive commands ask for a single summary confirmation** (not per-file) unless
   `--yes`/`-y` is passed explicitly — this applies to `reset-all` and `restore --apply --all`.
```

Replace with:

```
5. **Global destructive commands ask for a single summary confirmation** (not per-file) unless
   `--yes`/`-y` is passed explicitly — this applies to `reset-all` and `restore --apply --all`.
   **Deliberate exception: `install-theme`/`install-plugin`.** Fetching a third party's *current*
   code is a different risk class from overwriting a file the user already put in their own
   manifest, so each one asks on its own, every time, with no `--yes` bypass from the panel side.
   Don't "fix" this into a single bulk confirmation to match the rest of this rule — see
   "Big things are inventoried, never copied" below for why.
```

- [ ] **Step 2: Extend "Big things are inventoried, never copied"**

Find the end of that section — the paragraph ending:

```
**A cloned plugin is the same hole with an origin in front of it.** ... No diff against the built-in: `clone` means edited by
construction, the built-in lives at a path this would have to hunt for, and a check that can be
wrong about whether your work is backed up is worse than one that always tells you where it stands.
```

(this is the paragraph right before "Theme names are compared **normalised**...") — insert a new
paragraph immediately after it:

```
**Reinstalling from an origin used to be automatic; it is not any more.** A 2026-09 marketplace
security review flagged `restore` fetching a third party's theme/plugin origin at whatever HEAD
it currently points to, with no record of the commit that was actually reviewed at install time —
and there is no fix available at the call site: neither `omarchy theme install` nor
`omarchy plugin add` accepts a ref, so pinning is not this plugin's decision to make. The honest
fix is not silence, it is consent: `restore_themes`/`restore_plugins` only ever report a pending
theme/plugin now (`skip "... — third-party ..., not auto-installed: omarchy-replicant install-X ..."`),
and `install-theme <name>` / `install-plugin <id>` are the explicit actions that actually fetch one,
each confirmed on its own in the panel. `doctor` names them too, for anyone who never opens the
panel. The clone/reinstall of the user's OWN private backup repo (`clone`, `pull`) is unaffected —
there is no third party in that trust chain, and pinning it would break the point of the tool
(bringing down the latest state pushed from another machine).
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: record the install-theme/install-plugin gate and why rule 5 has an exception"
```

---

### Task 8: Full verification and the marketplace response

**Files:** None (verification only).

- [ ] **Step 1: Run the full suite**

```bash
./tests/run-all.sh
```

Expected: `Everything passed` — all four suites, `bash -n`, shellcheck,
qmllint, the QML-trap greps, and `omarchy-plugin-validate` all clean. This
is the point where a stray `set -e` interaction, a `pipefail` trap, or a
leftover `restore_themes "$DRY"` call site (Task 4, Step 3) would surface —
check the output line-by-line rather than only the final summary line, per
this project's own "shellcheck is not optional" lesson.

- [ ] **Step 2: Confirm the CLI surface by hand**

```bash
./bin/omarchy-replicant --help | grep -A2 install-theme
./bin/omarchy-replicant install-theme --help
./bin/omarchy-replicant install-plugin --help
```

Expected: both show up under "Putting things back", and both `--help`
invocations print the `HELP` array text from Task 3 without running anything
(per the project's own "`--help` is a question, never an instruction" rule —
worth a manual spot check since that exact class of bug has bitten this
project before).

- [ ] **Step 3: Prepare the marketplace reply**

With the fix landed, the reply to the marketplace review issue can now cite
working code instead of a plan: name the commits from Tasks 1-6, and update
the earlier draft comment to say the gap is closed (`install-theme` /
`install-plugin`, `doctor` output, panel section) rather than proposed. Do
not post it without the user's review — GitHub issue comments and closing
#4675 are public, hard-to-reverse actions, out of scope for this plan to
perform automatically.

---

## Self-Review

**Spec coverage:**
- `:469`/`cmd_pull` (own private repo) — explicitly out of scope, unchanged. ✓ (documented in Spec section, no task touches `cmd_clone`/`cmd_pull`)
- `:530`/`:585` (third-party reinstall) — Tasks 1-4 remove the automatic install and add the explicit path. ✓
- Panel exposure — Task 6. ✓
- Terminal-only (no panel) users — Task 5 (`doctor`). ✓
- Rule 5 exception documented so it survives future edits — Task 7. ✓
- Full-suite regression check — Task 8. ✓

**Placeholder scan:** every step above shows the literal before/after code
or the literal new function body; no "add error handling" or "similar to
Task N" placeholders remain.

**Type/name consistency check:**
- `core_install_theme` / `core_install_plugin` (Task 1) are the exact names
  `cmd_install_theme` / `cmd_install_plugin` (Task 3) call.
- `build_pending_reinstalls_json` (Task 2) is the exact name wired into
  `status --json`, and its field names (`kind`, `id`, `origin`, `method`)
  match what Task 6's QML reads (`modelData.kind`, `.id`, `.origin`) — Task 6
  does not use `.method`, which is fine, it is carried for `doctor`/future
  use, not required by the panel.
- `install-theme` / `install-plugin` are the exact dispatcher keywords (Task
  3) that Task 6's `dangerProc.command` and Task 4's `doctor`/`skip` message
  text both reference verbatim.
- `restore_themes` / `restore_plugins` lose their `dry` parameter in Task 4;
  the two call sites in the same task are updated together, so no caller is
  left passing a now-unused argument.
