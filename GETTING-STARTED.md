# First-time setup

Ten minutes, once. After this, saving is one click in the panel.

## 0. What you are about to create

Two separate things, and it matters that they stay separate:

| | This plugin | Your data |
| --- | --- | --- |
| Repo | `omarchy-replicant` (public, shared with everyone) | `<your-hostname>-replicant` (**private**, only yours) |
| Contains | QML + shell scripts | your dotfiles, your SSH key, your tokens |

The plugin creates the second one for you and refuses to make it public, because it will hold
real credentials.

## 1. Install the plugin

```bash
omarchy plugin add https://github.com/tymurbogach/omarchy-replicant --enable --yes
```

An **R** appears in the bar. Click it — it will say there is no repo yet.

## 2. Log in to GitHub

```bash
omarchy-replicant login
```

This is just `gh auth login`; if you already use the GitHub CLI, it will say so and do nothing.

## 3. Create your private repo

```bash
omarchy-replicant create --push
```

It creates `<your-hostname>-replicant` as **private**, copies your configs and secrets into it,
commits, and pushes. Open the panel again: it now shows the repo name and every tracked file.

> If a repo with that name already exists, the plugin links to it instead of creating one, and
> warns you if it is public. Fix that before pushing secrets:
> `gh repo edit <you>/<name> --visibility private`

## 4. Day to day

- Changed something? Open the panel → **Save to GitHub**. Or, in **Files**, save just the one
  file you touched.
- Want to change a common setting? Open the panel → **Settings**. Change the value; it is written
  to the real config, applied, and committed in one step.
- Another machine saved something? The bar icon shows ↓ — open the panel → **Pull**.
- Wondering what you changed in a file? **Files** → the ≠ button. The diff opens in the panel.

The icon tells you the state at a glance: **R** in sync, **●** local changes, **↑** to push,
**↓** to pull. The panel takes the keyboard too: `1`–`4` for the tabs, `/` to filter files, `r`
to refresh, `s` to save, `Esc` to back out.

If anything looks wrong, **Overview → Health check** (or `omarchy-replicant doctor`) answers the
questions you would otherwise have to go and check by hand: am I logged in, is my repo actually
private, is the secret-scanning hook on, are the permissions right.

## 5. Setting up a second machine

```bash
omarchy plugin add https://github.com/tymurbogach/omarchy-replicant --enable --yes
omarchy-replicant clone https://github.com/<you>/<hostname>-replicant
omarchy-replicant restore --dry-run
```

`--dry-run` prints, group by group, exactly what would change and touches nothing. When it looks
right:

```bash
omarchy-replicant restore --apply --all
```

Everything it overwrites is backed up as `<file>.bak.<epoch>` first.

## If it goes wrong

- **Undo a restore** — every overwritten file is next to the original as `.bak.<epoch>`.
- **Back to Omarchy's defaults** — panel → **Restore** → *Reset to factory*, or
  `omarchy-replicant reset-all --apply`.
- **The repo got exposed** — rotate the SSH key in `secrets/ssh/`, revoke every token in
  `secrets/env/`, then check `git log -p -- secrets/` to see exactly what was in there.
