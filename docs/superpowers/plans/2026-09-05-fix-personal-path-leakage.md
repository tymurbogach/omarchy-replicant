# Fix Personal-Path Leakage In Shipped Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove three places where `bin/replicant-core.sh` — public plugin
source, installed on every user's machine — falls back to reading
`$HOME/omarchy_thinkpad/...` or hardcodes one person's Samba credential
filenames, and replace them with the plugin's own generic, already-existing
mechanisms (`$PLUGIN_DIR`-seeded files, `TRACKED_SECRETS`).

**Architecture:** No new subsystem. Each of the three spots already has a
sibling that does this correctly (`scan-secrets.sh` seeding, the generic
`TRACKED_SECRETS` copy loop) — the fix in each case is deleting the
personal-path branch and, where the correct behavior doesn't exist yet,
generalizing the one piece of UX (the "needs sudo, here's the exact command"
hint) that was previously only wired up for Samba.

**Tech Stack:** bash (`bin/replicant-core.sh`), the existing test harness
(`tests/test-cli.sh`, `tests/run-all.sh`), no new dependencies.

**Spec:** This plan's spec is this conversation's investigation, summarized
below (no separate spec doc — the finding and the fix were worked out
together while answering "does replicant handle plugins installed from
non-official GitHub repos", which the investigation confirmed already works
via `resolve_plugin_origin()`'s plain `git remote get-url origin` — no task
needed for that, it is not part of this plan).

### What's broken, and where

`bin/replicant-core.sh` inside `core_backup()` has three spots that violate
CLAUDE.md's own rule ("The shipped list is universal; the personal list is
the user's" / hard rule 8's spirit): code that ships to every
`omarchy plugin add`-installer but only does anything useful on this one
machine.

1. **`bin/replicant-core.sh:1320-1323`** — seeding `$REPO_DIR/bin/scan-secrets.sh`
   falls back to `cp -a "$HOME/omarchy_thinkpad/bin/scan-secrets.sh" ...` when
   `$PLUGIN_DIR/bin/scan-secrets.sh` is missing. `$PLUGIN_DIR/bin/scan-secrets.sh`
   always exists (it ships with the plugin), so this branch is dead on every
   install, including this machine's. Pure debt: delete it.

2. **`bin/replicant-core.sh:1325-1329`** — seeding `$REPO_DIR/bin/pacman-delta-ignore`
   has *only* the personal fallback (`$HOME/omarchy_thinkpad/bin/pacman-delta-ignore`),
   with no equivalent of the `scan-secrets.sh` branch that seeds from
   `$PLUGIN_DIR` first. `$PLUGIN_DIR/bin/pacman-delta-ignore` ships in this
   repo already (generic Arch/Omarchy package names, nothing personal in it)
   but nothing ever copies *that* copy into a user's repo. On any machine
   without `~/omarchy_thinkpad` — i.e. everyone except this one — the repo's
   `bin/pacman-delta-ignore` is simply never created by this step. (The
   pacman-delta *calculation* at line ~1536 already has its own fallback
   straight to `$PLUGIN_DIR`, so the delta itself isn't wrong — it's only the
   copy-into-the-user's-own-repo step, the one that lets them edit it, that's
   missing.) Fix: source from `$PLUGIN_DIR` instead of the personal path. Keep
   the "only if missing" semantics (unlike `scan-secrets.sh`, this file lives
   in the user's own repo for them to edit — e.g. to ignore a package their
   own setup script installs — so it must not be overwritten on every version
   bump the way `scan-secrets.sh` deliberately is).

3. **`bin/replicant-core.sh:1498-1506`** — `core_backup()` hardcodes
   `/etc/samba/credentials-pi` and `/etc/samba/credentials-nas` (this
   machine's NAS and Raspberry Pi) and copies them into
   `$SECRETS_DIR/samba/`, entirely outside `TRACKED_SECRETS` — so it ignores
   `is_excluded` (a user can't turn it off via scope), ignores the user's own
   `.replicant-track`, and ships two of this one person's hostnames in public
   plugin source. The generic `TRACKED_SECRETS` loop just above it (lines
   1484-1494) already does the same job — copy a secret in at mode 600, name
   what's missing — for every *other* secret. The only thing the hardcoded
   block does that the generic loop doesn't is handle "exists but I can't
   read it, here's the sudo command to stage it", which matters here because
   Samba credential files are root-owned. Fix: fold that one behavior into
   the generic loop (`-f` → `-r`, plus an `elif -e` branch with the same
   message), then delete the hardcoded block outright. A user with a NAS
   mount tracks their own credentials file with
   `track --secret /etc/samba/credentials-pi samba/credentials-pi`, the same
   way any other personal secret is tracked.

## Global Constraints

- **The shipped list is universal; the personal list is the user's**
  (CLAUDE.md). Nothing in `bin/replicant-core.sh` may name a path, hostname,
  or filename specific to one person's setup.
- **Any operation that writes to the real system is dry-run by default and
  backs up as `.bak.<epoch>`** (CLAUDE.md hard rule 2) — not touched by this
  plan, but Task 2's edit sits inside `core_backup()`, which is the copy-*in*
  direction (machine → repo), not a write to the real system, so this rule
  does not gate it.
- **The entire project is in English** — code, comments, commit messages
  (CLAUDE.md language rule).
- **`./tests/run-all.sh` is the one command to run before pushing** — every
  task below must leave it green.
- Only create new commits; never amend. Never use `--no-verify`.

---

### Task 1: Fix the two personal-path fallbacks in repo-seeding

**Files:**
- Modify: `bin/replicant-core.sh:1313-1329` (inside `core_backup()`)
- Modify: `tests/run-all.sh` (new guard section)
- Test: `tests/test-cli.sh` (new section)

**Interfaces:**
- Consumes: `$PLUGIN_DIR` (already defined at the top of `replicant-core.sh`,
  resolves to the plugin's own install directory — in the test harness this
  is the checkout itself, since `CLI="$HERE/../bin/omarchy-replicant"`).
- Produces: nothing new — `$REPO_DIR/bin/pacman-delta-ignore` now actually
  gets created on a fresh repo, for every installer, not just this machine.

- [ ] **Step 1: Write the failing test**

  Add to the end of `tests/test-cli.sh`, before the final `summary` line:

  ```bash
  section "repo-seeded files come from the plugin, never a personal path"
  # A fresh repo (the "concurrent writes" section above already re-created
  # $REPO and ran `backup` against it, so bin/pacman-delta-ignore should
  # already have been seeded by now).
  check_true "pacman-delta-ignore was seeded into the repo" \
    test -f "$REPO/bin/pacman-delta-ignore"
  check_true "…and it is byte-identical to the plugin's own copy" \
    cmp -s "$HERE/../bin/pacman-delta-ignore" "$REPO/bin/pacman-delta-ignore"
  check "no reference to a personal sibling repo anywhere in the source" "0" \
    "$(grep -rl 'omarchy_thinkpad' "$HERE/../bin" 2>/dev/null | grep -c . || true)"
  ```

- [ ] **Step 2: Run it to verify it fails**

  Run: `bash tests/test-cli.sh 2>&1 | tail -20`
  Expected: FAIL on "pacman-delta-ignore was seeded into the repo" (the file
  is never created in the test's fake `$HOME`, which has no
  `omarchy_thinkpad`) and on the `grep -rl 'omarchy_thinkpad'` check (still
  present in the source at this point).

- [ ] **Step 3: Implement the fix**

  In `bin/replicant-core.sh`, replace lines 1313-1329:

  ```bash
    if [[ -f "$PLUGIN_DIR/bin/scan-secrets.sh" ]]; then
      if ! cmp -s "$PLUGIN_DIR/bin/scan-secrets.sh" "$REPO_DIR/bin/scan-secrets.sh" 2>/dev/null; then
        mkdir -p "$REPO_DIR/bin"
        [[ -f "$REPO_DIR/bin/scan-secrets.sh" ]] &&
          echo "  · updating the repo's secret scanner to this version's" >&2
        cp -a "$PLUGIN_DIR/bin/scan-secrets.sh" "$REPO_DIR/bin/scan-secrets.sh"
      fi
    elif [[ ! -f "$REPO_DIR/bin/scan-secrets.sh" && -f "$HOME/omarchy_thinkpad/bin/scan-secrets.sh" ]]; then
      mkdir -p "$REPO_DIR/bin"
      cp -a "$HOME/omarchy_thinkpad/bin/scan-secrets.sh" "$REPO_DIR/bin/scan-secrets.sh"
    fi
    chmod +x "$REPO_DIR/bin/scan-secrets.sh" 2>/dev/null || true
    # pacman-delta-ignore
    if [[ ! -f "$REPO_DIR/bin/pacman-delta-ignore" && -f "$HOME/omarchy_thinkpad/bin/pacman-delta-ignore" ]]; then
      mkdir -p "$REPO_DIR/bin"
      cp -a "$HOME/omarchy_thinkpad/bin/pacman-delta-ignore" "$REPO_DIR/bin/pacman-delta-ignore"
    fi
  ```

  with:

  ```bash
    if [[ -f "$PLUGIN_DIR/bin/scan-secrets.sh" ]]; then
      if ! cmp -s "$PLUGIN_DIR/bin/scan-secrets.sh" "$REPO_DIR/bin/scan-secrets.sh" 2>/dev/null; then
        mkdir -p "$REPO_DIR/bin"
        [[ -f "$REPO_DIR/bin/scan-secrets.sh" ]] &&
          echo "  · updating the repo's secret scanner to this version's" >&2
        cp -a "$PLUGIN_DIR/bin/scan-secrets.sh" "$REPO_DIR/bin/scan-secrets.sh"
      fi
    fi
    chmod +x "$REPO_DIR/bin/scan-secrets.sh" 2>/dev/null || true
    # pacman-delta-ignore — seeded once from the plugin's own shipped copy.
    # Unlike scan-secrets.sh above, this file lives in the USER'S repo for them
    # to edit (e.g. to ignore a package their own setup script installs, which
    # the plugin has no way to know about), so it is seeded only if missing,
    # never kept in step with a newer shipped version.
    if [[ ! -f "$REPO_DIR/bin/pacman-delta-ignore" && -f "$PLUGIN_DIR/bin/pacman-delta-ignore" ]]; then
      mkdir -p "$REPO_DIR/bin"
      cp -a "$PLUGIN_DIR/bin/pacman-delta-ignore" "$REPO_DIR/bin/pacman-delta-ignore"
    fi
  ```

- [ ] **Step 4: Add the regression guard to `tests/run-all.sh`**

  Insert this new section right after the "this repo, by its own secret
  scanner" banner (after the block ending at the `fi` that closes it, before
  `banner "manifest"`):

  ```bash
  banner "no personal paths in shipped code"
  if grep -rn 'omarchy_thinkpad' "$ROOT"/bin/*.sh "$ROOT"/bin/omarchy-replicant 2>/dev/null; then
    printf '  \033[31m✗\033[0m a personal path leaked into shipped code — see CLAUDE.md, "the shipped list is universal; the personal list is the user'"'"'s"\n'
    failed=$((failed+1))
  else
    printf '  \033[32m✓\033[0m none found\n'
  fi
  ```

- [ ] **Step 5: Run the test to verify it passes**

  Run: `bash tests/test-cli.sh 2>&1 | tail -20`
  Expected: all three new checks PASS.

  Run: `bash tests/run-all.sh 2>&1 | grep -A2 'no personal paths'`
  Expected: `✓ none found`.

- [ ] **Step 6: Commit**

  ```bash
  git add bin/replicant-core.sh tests/test-cli.sh tests/run-all.sh
  git commit -m "fix: stop seeding repo files from a personal sibling repo

  bin/pacman-delta-ignore and bin/scan-secrets.sh both had a fallback that
  read from \$HOME/omarchy_thinkpad — this machine's private, unrelated repo.
  scan-secrets.sh's fallback was already dead code (the primary PLUGIN_DIR
  branch always fires); pacman-delta-ignore had no PLUGIN_DIR branch at all,
  so on every machine except this one the file was simply never seeded into
  the user's repo."
  ```

---

### Task 2: Generalize the unreadable-secret hint, delete the hardcoded Samba block

**Files:**
- Modify: `bin/replicant-core.sh:1481-1506` (inside `core_backup()`)
- Test: `tests/test-cli.sh` (new section)

**Interfaces:**
- Consumes: `TRACKED_SECRETS` (array of `src:rel` entries, already built by
  `rebuild_tracked()`), `is_excluded(rel)` (existing function,
  `bin/replicant-core.sh:523`), `SECRETS_DIR` (existing variable).
- Produces: nothing new — the existing "needs sudo: ..." message now applies
  to any tracked secret this user can't read, not just Samba's two files.

- [ ] **Step 1: Write the failing test**

  Add to the end of `tests/test-cli.sh`, before the final `summary` line
  (after Task 1's new section, or wherever it landed):

  ```bash
  section "an unreadable tracked secret gets a sudo hint, not a crash"
  printf 'shh\n' > "$HOME/.config/mine.secret"
  run track "$HOME/.config/mine.secret" personal/mine.secret --secret >/dev/null 2>&1
  chmod 000 "$HOME/.config/mine.secret"
  out=$(run backup 2>&1)
  chmod 600 "$HOME/.config/mine.secret"   # restore so later sections / cleanup can touch it
  check_contains "the hint names the exact staging command" \
    "needs sudo: sudo install -m600" "$out"
  check_false "the unreadable file was NOT silently copied in" \
    test -s "$REPO/secrets/personal/mine.secret"
  check_false "the hardcoded Samba block is gone" \
    test -d "$REPO/secrets/samba"
  ```

- [ ] **Step 2: Run it to verify it fails**

  Run: `bash tests/test-cli.sh 2>&1 | tail -20`
  Expected: FAIL on "the hint names the exact staging command" (today's
  generic loop tests `-f`, not `-r`, so it attempts `install -m 600` on the
  unreadable file, which errors with a raw "Permission denied" instead of the
  friendly hint) and FAIL on "the hardcoded Samba block is gone" (today
  `core_backup()` always does `install -d -m 700 "$SECRETS_DIR/samba"`
  unconditionally, so the directory exists regardless of what's tracked).

- [ ] **Step 3: Implement the fix**

  In `bin/replicant-core.sh`, replace lines 1481-1506:

  ```bash
    echo "→ Copying secrets (private repo, 600)" >&2
    install -d -m 700 "$SECRETS_DIR" 2>/dev/null || true
    scopied=0
    for entry in "${TRACKED_SECRETS[@]}"; do
      src=${entry%%:*}
      rel="${entry##*:}"
      dst="$SECRETS_DIR/$rel"
      is_excluded "$rel" && continue
      if [[ -f $src ]]; then
        install -d -m 700 "$(dirname "$dst")" 2>/dev/null || mkdir -p "$(dirname "$dst")"
        install -m 600 "$src" "$dst"
        ((scopied++)) || true
      else
        echo "  · missing: ${src/#$HOME/\~}" >&2
      fi
    done
    # CIFS credentials (root:600, best-effort)
    install -d -m 700 "$SECRETS_DIR/samba" 2>/dev/null || true
    for src in /etc/samba/credentials-pi /etc/samba/credentials-nas; do
      dst="$SECRETS_DIR/samba/$(basename "$src")"
      if [[ -r $src ]]; then install -d -m 700 "$(dirname "$dst")" 2>/dev/null || true
        install -m 600 "$src" "$dst" 2>/dev/null || true
        ((scopied++)) || true
      elif [[ -e $src && ! -f $dst ]]; then
        echo "  · $src needs sudo: sudo install -m600 -o $USER -g $USER $src $dst" >&2
      fi
    done
    echo "  $(plural "$scopied" secret) copied" >&2
  ```

  with:

  ```bash
    echo "→ Copying secrets (private repo, 600)" >&2
    install -d -m 700 "$SECRETS_DIR" 2>/dev/null || true
    scopied=0
    for entry in "${TRACKED_SECRETS[@]}"; do
      src=${entry%%:*}
      rel="${entry##*:}"
      dst="$SECRETS_DIR/$rel"
      is_excluded "$rel" && continue
      if [[ -r $src ]]; then
        install -d -m 700 "$(dirname "$dst")" 2>/dev/null || mkdir -p "$(dirname "$dst")"
        install -m 600 "$src" "$dst"
        ((scopied++)) || true
      elif [[ -e $src ]]; then
        # Exists but this user can't read it — root-owned, typically (a CIFS
        # credentials file is the common case). Never fail loudly: name the
        # exact command that stages it, same shape as root_apply() on the
        # write side (see CLAUDE.md, "Root-owned files: ask, or say you could
        # not").
        echo "  · $src needs sudo: sudo install -m600 -o $USER -g $USER $src $dst" >&2
      else
        echo "  · missing: ${src/#$HOME/\~}" >&2
      fi
    done
    echo "  $(plural "$scopied" secret) copied" >&2
  ```

- [ ] **Step 4: Run the test to verify it passes**

  Run: `bash tests/test-cli.sh 2>&1 | tail -20`
  Expected: all three checks in this section PASS.

- [ ] **Step 5: Run the full suite**

  Run: `bash tests/run-all.sh 2>&1 | tail -30`
  Expected: `Everything passed.`

- [ ] **Step 6: Commit**

  ```bash
  git add bin/replicant-core.sh tests/test-cli.sh
  git commit -m "fix: stop hardcoding one machine's Samba credentials in core_backup

  The CIFS-credentials block copied two hostnames specific to this machine
  (/etc/samba/credentials-pi, credentials-nas) outside TRACKED_SECRETS, so it
  ignored scope/off, ignored the user's own .replicant-track, and shipped
  personal filenames in public plugin source. Its only behavior the generic
  TRACKED_SECRETS loop didn't already have — 'exists but unreadable, here is
  the sudo command to stage it' — is now folded into that loop, so it applies
  to any personal secret a user tracks, not just Samba's two files."
  ```

---

### Task 3: Document the pattern and migrate this machine's own repo

This task has no automated test — it is documentation plus a one-time
operational step against `cyberdyne-replicant`, this machine's own private
data repo (never the public `omarchy-replicant` repo these code changes live
in).

**Files:**
- Modify: `README.md` (near line 78, the existing `track ... --secret` example)

- [ ] **Step 1: Add the CIFS/Samba example to the README**

  In `README.md`, immediately after the existing line:

  ```
  omarchy-replicant track ~/.config/gh/hosts.yml --secret  # stored 600, never rendered
  ```

  add:

  ```
  omarchy-replicant track /etc/samba/credentials-pi samba/credentials-pi --secret
  # a NAS mount's credentials file is exactly this kind of personal secret —
  # not every Omarchy user has one, so it's never in the shipped list
  ```

- [ ] **Step 2: Migrate this machine's own private repo**

  Run these against the real, private `cyberdyne-replicant` repo (NOT a test
  fixture) so the two files that were being copied in by the now-deleted
  hardcoded block keep being backed up, under the generic mechanism instead:

  ```bash
  omarchy-replicant track /etc/samba/credentials-pi  samba/credentials-pi  --secret
  omarchy-replicant track /etc/samba/credentials-nas samba/credentials-nas --secret
  omarchy-replicant backup
  ```

  Confirm nothing under `secrets/samba/` changed content-wise (only
  `.replicant-track` gained two lines):

  ```bash
  git -C ~/.local/share/omarchy-replicant/repo status --porcelain
  ```

  Expected: only `.replicant-track` (and possibly `state/*` inventory
  refresh) show as changed — no diff under `secrets/samba/`.

- [ ] **Step 3: Commit the README change**

  ```bash
  git add README.md
  git commit -m "docs: document a CIFS/Samba credentials file as a personal secret example"
  ```

## Self-Review

- **Spec coverage:** all three findings from the investigation (dead
  scan-secrets.sh fallback, pacman-delta-ignore missing its PLUGIN_DIR seed,
  hardcoded Samba block) each have a task. The fourth item from the
  investigation — GitHub-plugin origin tracking — was confirmed already
  correct (`resolve_plugin_origin()` is plain `git remote get-url origin`,
  with no "official" special-casing, and `discover_plugin_entries` already
  has a test proving replicant excludes itself: `tests/test-core.sh:70`) and
  deliberately has no task.
- **Placeholder scan:** every step shows the exact before/after code or the
  exact command to run; no "add appropriate handling" language.
- **Type/name consistency:** `TRACKED_SECRETS`, `is_excluded`, `SECRETS_DIR`,
  `PLUGIN_DIR`, `REPO_DIR` are all read from the existing codebase (verified
  via `grep`/`Read` during investigation), not invented for this plan.
