# First-time setup

About five minutes, once. After that, saving is one click.

## What you are about to create

Two separate things, and it matters that they stay separate:

| | This plugin | Your data |
| --- | --- | --- |
| Repo | `omarchy-replicant` (public, shared with everyone) | `<your-hostname>-replicant` (**private**, only yours) |
| Contains | QML and shell scripts | your dotfiles, your SSH key, your tokens |

The plugin creates the second one for you and refuses to make it public, because it will hold real
credentials.

## 1. Install

```bash
omarchy plugin add https://github.com/tymurbogach/omarchy-replicant --enable --yes
```

A **+** appears in the bar. Click it — it will say there is no repo yet.

## 2. Create your repo

Press **Create private repo**. A terminal opens and walks you through two things:

1. **GitHub login** — this is `gh auth login`. If you already use the GitHub CLI it skips straight
   past.
2. **The repo** — created as `<your-hostname>-replicant`, private, with your configs, secrets and
   package inventory already in it, and pushed.

Open the panel again and it shows the repo name and every tracked file.

> If a repo with that name already exists, the plugin links to it instead of creating one, and
> warns you if it is public. Fix that before pushing secrets:
> `gh repo edit <you>/<name> --visibility private`

## 3. Day to day

- **Changed something?** Panel → **Save to GitHub**. Or, in **Configs**, open the area and save
  just the one file you touched.
- **Want to change a setting?** Panel → **Settings**. Open a group, change the value; it is
  written to the real config, applied, and committed in one step. Timers are in minutes — the
  panel converts, the CLI still speaks seconds.
- **Changed your mind?** The two small buttons at the end of every setting row put it back: ↺ to
  Omarchy's default, ⭳ to what your repo has. Neither touches the rest of the file.
- **Another machine saved something?** The bar icon turns into a download cloud — panel → **Pull**.
- **What did I change in this file?** **Configs** → the file's compare button. The diff opens in
  the panel.

The bar icon tells you the state at a glance: the GitHub mark when everything is saved, a floppy
disk when this machine has unsaved changes, a cloud with an up arrow when there is something to
push, a cloud with a down arrow when another machine saved something, a warning when the two have
diverged, and a plus before you have set anything up.

The panel takes the keyboard too: `1`–`4` for the tabs, `/` to filter, `r` to refresh, `s` to
save, `c` to collapse every open area, `Esc` to back out. To open it from a keybinding, bind
`omarchy shell replicant toggle`.

## 3b. Two machines, one repo

This is the case profiles exist for. Some files describe the *machine*, not you —
`hypr/monitors.lua` lists the screens physically plugged into this box, and copying the laptop's
version onto the desktop is actively wrong.

Every row in **Configs** has a scope button. It cycles three answers:

| Scope | What it means |
| --- | --- |
| **Shared** | one copy in `config/`, every machine saves and restores it |
| **`<profile>`** | a copy under `profiles/<profile>/config/` — the desktop and the laptop each keep their own, and neither overwrites the other |
| **Off** | not saved from here, not restored onto here; whatever the repo holds is left alone |

`hypr/monitors.lua` starts profile-scoped, which is better than off: both machines get a backup of
their own screen layout, they just don't get each other's. The list lives in `.replicant-sync`
**inside the repo**, so the decision travels — make it once, both machines honour it.

Your machine picks its profile from its own chassis (a lid means `laptop`). Override it once:

```bash
omarchy-replicant profile            # show this machine's profile and all the others
omarchy-replicant profile desktop    # assign it explicitly
```

Everything else is already per-machine where it needs to be: the package/service/plugin inventory
is written to `state/<hostname>/`, so the desktop and the laptop add to the repo instead of
overwriting each other. Overview lists every machine, its profile, and when it last saved.

> Upgrading from 0.5? Your old `.replicant-exclude` is migrated to `.replicant-sync` on the next
> save, and every file you had switched off stays off — nothing is reinterpreted. If you switched
> `monitors.lua` off, consider moving it to *profile* instead: you get a backup of it again.

## 3b-2. Backing up files the plugin doesn't ship with

The tracked list has two halves. The plugin ships the paths any Omarchy machine plausibly has; your
own additions live in `.replicant-track` **inside your repo**, so they travel to your second machine
like every other decision here.

Open **Configs** and scroll to the bottom: **Add more files** lists what is on this machine and not
tracked yet, each with the reason it is worth a look, and a **Track** button. From a terminal:

```bash
omarchy-replicant suggest                        # the same list
omarchy-replicant track ~/.local/bin/my-script   # a file
omarchy-replicant track ~/.config/nvim/          # a whole directory
omarchy-replicant track ~/.config/gh/hosts.yml --secret
omarchy-replicant untrack bin/my-script          # drop it, and its copy in the repo
```

`suggest` will not propose a symlink, a mise shim, an application's own state, a file another plugin
installed, or something identical to Omarchy's default. When a file holds a credential it says so
and suggests `--secret`, which stores it at mode 600 and never renders its contents.

**Untrack is for your own entries only.** A file the plugin ships with is switched **Off** instead
(the scope button) — that keeps the row and the copy in your repo, where untracking would remove both.

> Upgrading from 0.6? Anything the old version hardcoded that this machine or your repo actually has
> is moved into your `.replicant-track` on the next save, so nothing stops being backed up. You will
> see a line saying how many entries moved.

## 3b-3. Themes

Your themes are not copied — they are reinstalled. Replicant records each user theme's name and git
origin in the inventory, and on a restore it runs `omarchy theme install` for the ones this machine
does not have **before** applying your theme. That order is the whole point: applying a theme that
is not installed yet fails, and the most visible thing about your setup comes back as nothing.

A theme you wrote by hand has no origin, so nothing can reinstall it. `omarchy-replicant doctor`
names those, and the answer is to track its directory:
`omarchy-replicant track ~/.config/omarchy/themes/<name>`.

## 3c. Lid behaviour, on a laptop

**Settings → Lid & sleep** sets what closing the lid does — on battery, on AC, and when docked to
an external monitor (`ignore` there is clamshell mode). These live in
`/etc/systemd/logind.conf.d/99-lid.conf`, which is root-owned, so applying a change asks for root
through a polkit prompt or passwordless `sudo`. If neither is available, nothing is changed and
you get the exact command to run — it never fails silently, and it never writes behind your back.

The file is tracked and profile-scoped, so your laptop's lid behaviour is backed up without ever
landing on a desktop that has no lid.

## 4. Your second machine

```bash
omarchy plugin add https://github.com/tymurbogach/omarchy-replicant --enable --yes
P=~/.config/omarchy/plugins/io.github.tymurbogach.omarchy-replicant
$P/bin/omarchy-replicant clone https://github.com/<you>/<hostname>-replicant
```

Then open the panel → **Restore** → **Preview**. It prints, area by area, exactly what would
change, and touches nothing. When it looks right, **Restore everything** — or restore one area at
a time from the list underneath.

Restoring is not just copying. Each area is put back the way Omarchy expects it: the theme is
re-applied with `omarchy theme set` (which rewrites every terminal, editor and GTK colour, not
just a file), Hyprland is reloaded and then checked with `hyprctl configerrors`, terminals are
restarted, themes and plugins recorded in the inventory are reinstalled with
`omarchy theme install` and `omarchy plugin add`.
Anything outside `$HOME` is never written behind your back — you get the exact `sudo` command.

Everything it overwrites is kept as `<file>.bak.<epoch>` first.

## 5. Using it from a terminal (optional)

The panel never needs the command line, so the plugin does not put itself on your `PATH`. If you
want it there:

```bash
~/.config/omarchy/plugins/io.github.tymurbogach.omarchy-replicant/bin/omarchy-replicant link
omarchy-replicant --help
```

`unlink` takes it back off.

## If it goes wrong

- **Undo a restore** — every overwritten file is next to the original as `.bak.<epoch>`.
- **Back to Omarchy's defaults** — panel → **Restore** → *Reset to factory*. Your repo is not
  touched, so you can restore from it afterwards.
- **Start over** — `omarchy-replicant purge --apply --repo` removes everything on this machine
  (your GitHub repo is untouched), then create or clone again.
- **The repo got exposed** — rotate the SSH key in `secrets/ssh/`, revoke every token in
  `secrets/env/`, then read `git log -p -- secrets/` to see exactly what was in there.
