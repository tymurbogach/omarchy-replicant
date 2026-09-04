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
| **Theme** | copies `theme.name` | replays `omarchy theme set` — rewrites every terminal, editor and GTK colour |
| **Hyprland** | copies the Lua | copies, then `hyprctl reload` **and** checks `configerrors` |
| **Terminals** | wait for a reboot | `omarchy restart terminal` |
| **Plugins** | commits someone else's source | records each id + git origin, reinstalls with `omarchy plugin add` |
| **Shortcuts** | snapshots all 227 bindings | tracks only *your* overrides — defaults ship with the distro |
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

## What else it does

- **43 tracked files**, grouped into eleven areas. Nothing scrolls forever; you open the one you came for.
- **Change detection that tells the truth.** Every file is compared by content against the copy in your repo, so editing one says so immediately — and putting it back clears the warning by itself. Badges: ● changed here · ↑ saved here, not pushed · ◆ saved on GitHub · ○ untouched default · ⊘ not synced.
- **24 settings from the panel**, in units people use — the lock screen is *10 min*, not *600*.
- **Lid & sleep** on laptops: what closing the lid does on battery, on AC, and when docked.
- **Two ways back for every value** — one button to Omarchy's default, one to what your repo has.
- **Secrets stay secret.** SSH keys and `.env` files are stored at mode 600; the panel shows a kind, a mode and a variable *count*. No value is ever drawn on screen, and the diff refuses to render one.
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
