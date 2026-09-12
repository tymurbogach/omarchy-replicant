# First-time setup

This takes about five minutes, once. After that, saving is one click.

## What you are about to create

There are two separate things, and they must stay separate:

| | This plugin | Your data |
| --- | --- | --- |
| Repo | `omarchy-replicant` (public, shared with everyone) | `<your-hostname>-replicant` (**private**, only yours) |
| Contains | QML and shell scripts | Your dotfiles, your SSH key, your tokens |

The plugin creates the second repo for you. It refuses to make that repo public, because it holds
real credentials.

## 1. Install

```bash
omarchy plugin add https://github.com/tymurbogach/omarchy-replicant --enable --yes
```

A **+** appears in the bar. Click it: the panel says that there is no repo yet.

## 2. Create your repo

Press **Create private repo**. A terminal opens and walks you through two steps:

1. **GitHub login.** This is `gh auth login`. If you already use the GitHub CLI, it skips this step.
2. **The repo.** The plugin creates `<your-hostname>-replicant` as a private repo, puts your
   configs, secrets and package inventory into it, and pushes.

Open the panel again. It shows the repo name and every tracked file.

> If a repo with that name already exists, the plugin links to it instead. If that repo is public,
> the plugin warns you. Make it private before you push secrets:
> `gh repo edit <you>/<name> --visibility private`

## 3. Day to day

- **You changed something.** Press **Save to GitHub** in the panel. Or open the area in **Configs**
  and save only the file that you changed.
- **You want to change a setting.** Open **Settings**, open a group, and change the value. The
  plugin writes it to the real config, applies it, and commits it. Timers show in minutes. The CLI
  still uses seconds.
- **You changed your mind.** Every setting row ends in two small buttons. ↺ puts the value back to
  Omarchy's default, and ⭳ puts back what your repo has. Neither touches the rest of the file.
- **Another machine saved something.** The bar icon turns into a download cloud. Press **Pull**.
  Pull says which of your files came down, and marks each one **↓ to restore**, not ● unsaved.
  Then use **Restore**, or the ⭳ button on that row.
- **You want to see what changed in a file.** Press the compare button on the file in **Configs**.
  The diff opens in the panel.

The bar icon shows the state at a glance:

- A hexagon: everything is saved.
- A floppy disk: this machine has unsaved changes. The plugin counts them from the files, so a file
  that you edited and never saved shows here too.
- A cloud with an up arrow: commits wait to be pushed.
- A cloud with a down arrow: another machine saved something.
- A warning sign: the two machines have diverged.
- A plus: nothing is set up yet.

The panel also takes the keyboard. Keys `1` to `4` open the tabs, `/` filters, `a` jumps to *Add
more files*, `r` refreshes, `s` saves, `p` pulls, `c` collapses every open area, and `Esc` backs
out. To open the panel from a key, bind `omarchy shell replicant toggle`.

## 4. Two machines, one repo

Profiles exist for this case. Some files describe the *machine*, not you. `hypr/monitors.lua` lists
the screens plugged into this box, and the laptop's version is wrong on the desktop.

Every row in **Configs** has a scope button. It cycles through three answers:

| Scope | What it means |
| --- | --- |
| **Shared** | One copy in `config/`. Every machine saves it and restores it. |
| **`<profile>`** | A copy under `profiles/<profile>/config/`. The desktop and the laptop each keep their own, and neither overwrites the other. |
| **Off** | Not saved from here, and not restored onto here. The copy in the repo is left alone. |

`hypr/monitors.lua` starts profile-scoped. Each machine gets a backup of its own screen layout, and
neither gets the other's. The list lives in `.replicant-sync` **inside the repo**, so you decide once
and both machines follow it.

Your machine picks its profile from its chassis: a lid means `laptop`. To set it yourself:

```bash
omarchy-replicant profile            # show this machine's profile and all the others
omarchy-replicant profile desktop    # assign it
```

The package, service and plugin inventory goes to `state/<hostname>/`. So the desktop and the
laptop add to the repo instead of overwriting each other. **Overview** lists every machine, its
profile, and when it last saved.

### Which way does a change point

"This file differs from the copy in the repo" has two opposite answers: *you* changed it, or the
*other machine* did. Only one of those answers means Save. Content cannot tell them apart, so the
plugin writes the direction down when `pull` brings the commits in.

- **Save to GitHub holds those files back.** It saves everything else as usual, and it names the
  files that it did not touch. This machine's copy is the old one.
- **You can still overrule it** by naming the file: `omarchy-replicant save-file <id>` saves this
  machine's version, and the mark clears. The per-file Save button in the panel stays disabled on
  those rows on purpose.

Restore the file and the mark clears by itself, because the mark shows only while the two copies
differ.

If another machine pushed first, **Save to GitHub** commits on this machine and says that the push
failed. Press **Pull**, then save again.

> Upgrading from 0.5? The old `.replicant-exclude` becomes `.replicant-sync` on the next save, and
> every file that you switched off stays off. If you switched off `monitors.lua`, consider the
> profile scope instead: you get a backup of it again.

## 5. Files the plugin does not ship with

The tracked list has two halves. The plugin ships the paths that any Omarchy machine plausibly has.
Your own additions live in `.replicant-track` **inside your repo**, so they travel to your second
machine like every other decision.

At the bottom of **Configs**, **Add more files** lists what is on this machine and not tracked yet.
Each row gives a reason and a **Track** button. From a terminal:

```bash
omarchy-replicant suggest                        # the same list
omarchy-replicant track ~/.local/bin/my-script   # a file
omarchy-replicant track ~/.config/nvim/          # a whole directory
omarchy-replicant track ~/.config/gh/hosts.yml --secret
omarchy-replicant untrack bin/my-script          # drop it, and its copy in the repo
```

`suggest` never proposes a symlink, a mise shim, an application's own state, a file that another
plugin installed, or a file identical to Omarchy's default. When a file holds a credential, it says
so and suggests `--secret`. That stores the file at mode 600 and never shows its contents.

**Untrack is for your own entries only.** To stop syncing a file that the plugin ships with, switch
it **Off** with the scope button. That keeps the row and the copy in your repo. Untrack would remove
both.

> **Upgrade both machines.** A machine on 0.6 deletes from the repo everything that its own version
> does not know about, your additions included. From 0.7.0, an older client refuses to prune.
> `omarchy-replicant doctor` tells you if this machine is behind.

## 6. Themes

Your themes are installed from their origin, not copied. Replicant records each user theme's name
and git origin. A restore does not fetch them. It names the ones that this machine does not have,
and you install one with `omarchy-replicant install-theme <name>` or the **Install** button.

A theme comes from somebody else's git repo, and that repo holds whatever is in it today. So fetching
it is always your decision. Installing a theme also makes it the active theme.

A theme that you wrote by hand has no origin, so nothing can install it. `omarchy-replicant doctor`
names it. Track its directory instead: `omarchy-replicant track ~/.config/omarchy/themes/<name>`.

## 7. The lid, on a laptop

**Settings**, **Lid & sleep** sets what closing the lid does: on battery, on AC, and when docked to
an external monitor (`ignore` there is clamshell mode). These values live in
`/etc/systemd/logind.conf.d/99-lid.conf`, which root owns.

To apply a change, the plugin asks for root through a polkit prompt or passwordless `sudo`. If
neither is available, nothing changes, and you get the exact command to run. It never fails without
a word, and it never writes behind your back.

The file is tracked and profile-scoped. So the laptop's lid settings are backed up, and they never
land on a desktop that has no lid.

## 8. Your second machine

```bash
omarchy plugin add https://github.com/tymurbogach/omarchy-replicant --enable --yes
P=~/.config/omarchy/plugins/io.github.tymurbogach.omarchy-replicant
$P/bin/omarchy-replicant clone https://github.com/<you>/<hostname>-replicant
```

Then open the panel, **Restore**, **Preview**. It prints what would change in each area, and it
touches nothing. When it looks right, press **Restore everything**, or restore one area at a time.

Restoring is not only copying. Each area goes back the way Omarchy expects:

- The theme is applied again with `omarchy theme set`, which rewrites every terminal, editor and GTK
  colour.
- Hyprland is reloaded, then checked with `hyprctl configerrors`.
- Terminals are restarted.
- Themes and plugins in the inventory are named with their origin, not fetched. Run `install-theme`
  or `install-plugin`, or press **Install** on the row.

Nothing outside `$HOME` is written behind your back: you get the exact `sudo` command. Every file
that a restore overwrites is kept as `<file>.bak.<epoch>` first.

## 9. The command line (optional)

The panel never needs the command line, so the plugin does not put itself on your `PATH`. To add it:

```bash
~/.config/omarchy/plugins/io.github.tymurbogach.omarchy-replicant/bin/omarchy-replicant link
omarchy-replicant --help
```

`unlink` takes it off again.

One difference is deliberate. The panel's **Save to GitHub** runs `savegame --auto`: it copies
everything in, commits it under a subject written from the changed files, and pushes. Plain
`savegame` in a terminal commits the inventory and then stops. It lists what changed, so that you
can write one commit for each change, with the reason. Use `-m "why"` for one commit with a reason,
and `--auto` to save it all. `push` sends the commits that you already have, and touches nothing else.

## 10. If a restore was wrong

Everything that this plugin writes to your machine keeps the version it replaced, as
`<file>.bak.<epoch>`. Panel, **Restore**, *If a restore went wrong* lists them: which file, how long
ago, and whether the backup still differs from your file.

**Undo** puts one back, and keeps the version it replaces as the new backup. It is a swap, so an
undo can itself be undone, and the pile does not grow. A backup identical to your file has its
button disabled, and says why.

```bash
omarchy-replicant backups                    # every backup, newest first
omarchy-replicant undo hypr/input.lua        # a dry run
omarchy-replicant undo hypr/input.lua --apply
omarchy-replicant backups --prune --apply    # remove them all; your repo is not touched
```

None of this touches your GitHub repo. To get back what is saved on GitHub, use **Restore**.

## If it goes wrong

- **Undo a restore.** Every overwritten file sits next to the original as `.bak.<epoch>`.
- **Go back to Omarchy's defaults.** Panel, **Restore**, *Reset to factory*. Your repo is not
  touched, so you can restore from it afterwards.
- **Start over.** `omarchy-replicant purge --apply --repo` removes everything on this machine. Your
  GitHub repo is not touched. Then create or clone again.
- **The repo was exposed.** Rotate the SSH key in `secrets/ssh/`, revoke every token in
  `secrets/env/`, and read `git log -p -- secrets/` to see what was in there.
