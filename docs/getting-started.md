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

This is the case the per-file switch exists for. Some files describe the *machine*, not you —
`hypr/monitors.lua` lists the screens physically plugged into this box, and copying the laptop's
version onto the desktop is actively wrong.

Every row in **Configs** has a switch. Off means: not saved from here, not restored onto here, and
whatever the repo already holds is left exactly as it is. `hypr/monitors.lua` starts off for
exactly this reason. The list lives in `.replicant-exclude` **inside the repo**, so the decision
travels — make it once, both machines honour it.

Everything else is already per-machine where it needs to be: the package/service/plugin inventory
is written to `state/<hostname>/`, so the desktop and the laptop add to the repo instead of
overwriting each other. Overview lists every machine that has saved into the repo and when.

If anything looks off, **Overview → Health check** answers the questions you would otherwise go
and check by hand: am I logged in, is my repo actually private, is the secret-scanning hook on,
are the permissions right.

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
restarted, and plugins recorded in the inventory are reinstalled with `omarchy plugin add`.
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
