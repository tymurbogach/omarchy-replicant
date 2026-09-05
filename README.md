<h1 align="center">Omarchy Replicant</h1>

<p align="center">
  <b>The right way to manage, save and replicate your Omarchy setup across your machines.</b><br>
  Built for one repo shared by a desktop <i>and</i> a laptop.
</p>

<p align="center">
  <img src="docs/images/overview.png" alt="Overview" width="270">
  <img src="docs/images/configs.png"  alt="Configs"  width="270">
  <img src="docs/images/settings.png" alt="Settings" width="270">
</p>

```bash
omarchy plugin add https://github.com/tymurbogach/omarchy-replicant --enable --yes
```

Click the icon in your bar → **Create private repo**. Done. It makes a private GitHub repo,
copies your configs and secrets in, and pushes.

---

## Why not just copy dotfiles

Because copying a file back is only half a restore. Omarchy keeps your setup in more than files,
and each part has one correct way to be put back.

| | Copying dotfiles | Replicant |
| --- | --- | --- |
| **Theme** | copies `theme.name`, or 556 MB of wallpapers | records each theme's git origin, reinstalls it, *then* applies it |
| **Hyprland** | copies the Lua | copies, then `hyprctl reload` **and** checks `configerrors` |
| **Terminals** | wait for a reboot | `omarchy restart terminal` |
| **Plugins** | commits someone else's source | works out each origin — even for one you wrote — and reinstalls it |
| **Shortcuts** | snapshots all 227 bindings | tracks only *your* overrides — Omarchy's 227 defaults ship with the distro |
| **Reset** | `rm` and re-copy | `omarchy refresh config <file>` |

The panel names the method under every area before you press anything.

## Desktop *and* laptop, one repo

The part every dotfile repo gets wrong. Some files describe **the machine**, not you.

Every file has a scope, and you set it once — the decision lives in the repo, so both machines
honour it:

| Scope | What happens |
| --- | --- |
| **Shared** | one copy, every machine saves and restores it |
| **`<profile>`** | a copy per profile — your desktop and laptop each keep their own, neither overwrites the other |
| **Off** | never saved from here, never restored onto here |

`hypr/monitors.lua` starts profile-scoped: both machines get a backup of their screen layout,
neither gets the other's. Your package and plugin inventory is recorded per hostname too, so two
machines add to the repo instead of fighting over it.

```bash
omarchy-replicant profile              # which profile this machine is in
omarchy-replicant profile desktop      # put it in another one
omarchy-replicant scope hypr/input.lua profile
```

## Your list, not somebody else's

Every dotfile tool ships one person's list of files. This one ships the paths any Omarchy machine
plausibly has and keeps **yours** in your own repo, so they travel to your second machine without
being published to everyone else's.

Panel → **Configs** → **Add more files** proposes what is not tracked yet, each row with the reason
and a **Track** button. It will not propose a symlink, a mise shim, a browser's own state, a file
another plugin installed, or anything identical to Omarchy's default — and it flags a file that
holds a credential so you track it as a secret instead of world-readable. Nothing is added until
you press the button.

```bash
omarchy-replicant suggest                                # the same list, in a terminal
omarchy-replicant track ~/.local/bin/my-script
omarchy-replicant track ~/.config/nvim/                  # a whole directory
omarchy-replicant track ~/.config/gh/hosts.yml --secret  # stored 600, never rendered
```

## Big things are reinstalled, not copied

The eight custom themes on the machine this was built on are **556 MB**, 400 of it their own `.git`.
Copying that into a backup repo would be absurd, so what travels is the URL.

| | Recorded | Restored with |
| --- | --- | --- |
| Themes | name + git origin | `omarchy theme install`, then `omarchy theme set` |
| Plugins | id + version + origin + method | `omarchy plugin add` / `omarchy plugin clone` |
| Packages | per hostname, official and AUR | your package manager |

Themes are installed **before** the theme name is applied — otherwise `omarchy theme set` fails on
a machine that does not have the theme yet, and the most visible thing about your setup comes back
as nothing. Plugins resolve even with no obvious origin: one you wrote yourself is traced back to
your own checkout.

## What else it does

- **44 paths out of the box** — 41 configs and 3 secrets — plus whatever you add, grouped into eleven areas. Nothing scrolls forever; you open the one you came for.
- **Directories, not just files.** `~/.config/nvim/` is one row with a file count; a change anywhere inside it says so, and `.git` inside a tracked tree is never copied.
- **Change detection that tells the truth.** Every file is compared by content against the copy in your repo, so editing one says so immediately — and putting it back clears the warning by itself. Badges, in the panel's own words: **●** unsaved, **↓** to restore, **↑** to push, **◆** saved, **○** default, **⊘** off, **·** not here.
- **It knows which way a change points.** Two machines on one repo means "this file and its copy differ" has two opposite answers, and only one of them is Save. After a `pull`, anything another machine changed is marked **↓ to restore** instead of ● unsaved — so the obvious button is never the one that commits over somebody else's work.
- **24 settings from the panel**, in units people use — the lock screen is *10 min*, not *600*.
- **Lid & sleep** on laptops: what closing the lid does on battery, on AC, and when docked.
- **Two ways back for every value** — one button to Omarchy's default, one to what your repo has.
- **Secrets stay secret.** SSH keys and `.env` files are stored at mode 600; the panel shows a kind, a mode and a variable *count*. No value is ever drawn on screen, and the diff refuses to render one.
- **An undo for the undo.** Every write keeps the version it replaced as `.bak.<epoch>` — and Restore now lists them, says how long ago each was made and whether it still differs from what you have, and puts one back with a button. Undo is a swap, so it is itself reversible and the backups never pile up.
- **An inventory that only moves when something moved.** A file earns its place by being what a restore consumes or what a person rebuilds a machine from. Versions that bump on their own, countdowns, and the units your distribution enables are not that, and they used to cost a commit every single save.
- **No terminal pop-ups.** Editing opens your editor, diffs render in the panel, destructive actions confirm in the panel.

## Second machine

```bash
omarchy plugin add https://github.com/tymurbogach/omarchy-replicant --enable --yes
P=~/.config/omarchy/plugins/io.github.tymurbogach.omarchy-replicant
$P/bin/omarchy-replicant clone https://github.com/<you>/<hostname>-replicant
```

Panel → **Restore** → *Preview* shows exactly what would change and touches nothing.

## Safety

Dry-run by default. Every overwritten file is kept as `<file>.bak.<epoch>`. Anything outside
`$HOME` is never written silently. Your data repo is **private and yours** — this repo is only the
plugin's code, and the two never mix.

## Removing it

`purge` lives inside the plugin, so run it **before** removing the plugin:

```bash
P=~/.config/omarchy/plugins/io.github.tymurbogach.omarchy-replicant
$P/bin/omarchy-replicant purge                 # show what is on disk — changes nothing
$P/bin/omarchy-replicant purge --apply --repo  # remove it, local clone included
omarchy plugin remove io.github.tymurbogach.omarchy-replicant
```

Your GitHub repo is untouched either way.

## Requirements

Omarchy 4 (Quattro). Two things beyond a stock install, both checked by
`omarchy-replicant doctor`, which names the exact command if either is missing:

| | Why | Install |
| --- | --- | --- |
| `github-cli` (`gh`) | logs you in and creates the private repo | `omarchy pkg add github-cli` |
| `jq` | reads and writes the JSON configs | `omarchy pkg add jq` |

`git` is already on every Omarchy machine. Nothing else is pulled in, and the plugin writes
nothing outside its own folder and `~/.local/share/omarchy-replicant/`.

## Docs

- [First-time setup](docs/getting-started.md)
- [Notes for contributors](CLAUDE.md) — the traps this plugin has actually hit

MIT licensed.
