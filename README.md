<h1 align="center">Omarchy Replicant</h1>

<p align="center">
  <b>Manage, save and replicate your Omarchy setup across your machines.</b><br>
  Built for one private repo that a desktop <i>and</i> a laptop share.
</p>

<p align="center">
  <img src="docs/images/overview.png" alt="Overview" width="270">
  <img src="docs/images/configs.png"  alt="Configs"  width="270">
  <img src="docs/images/settings.png" alt="Settings" width="270">
</p>

## Install

```bash
omarchy plugin add https://github.com/tymurbogach/omarchy-replicant --enable --yes
```

Click the icon in your bar, then **Create private repo**. The plugin creates a private GitHub repo,
copies your configs and secrets into it, and pushes. [First-time setup](docs/getting-started.md)
walks through it.

## Usage

### Why not just copy dotfiles

A copied file is only half of a restore. Omarchy keeps your setup in more than files, and each part
has one correct way back.

| | Copying dotfiles | Replicant |
| --- | --- | --- |
| **Theme** | Copies `theme.name`, or 556 MB of wallpapers | Records each theme's git origin, applies the theme again, and installs a missing theme only when you ask |
| **Hyprland** | Copies the Lua | Copies it, runs `hyprctl reload`, **and** checks `configerrors` |
| **Terminals** | Wait for a reboot | Runs `omarchy restart terminal` |
| **Plugins** | Commits someone else's source | Records each origin, even for a plugin you wrote, and installs it on request |
| **Shortcuts** | Saves every binding on the machine | Tracks only *your* overrides, because Omarchy's defaults come with the distribution |
| **Reset** | `rm`, then copy again | Runs `omarchy refresh config <file>` |

The panel names the method under every area before you press anything.

### Desktop *and* laptop, one repo

Some files describe **the machine**, not you. Every file has a scope, and you set it once. The
decision lives in the repo, so both machines follow it.

| Scope | What happens |
| --- | --- |
| **Shared** | One copy. Every machine saves it and restores it. |
| **`<profile>`** | One copy for each profile. The desktop and the laptop each keep their own, and neither overwrites the other. |
| **Off** | Never saved from here, and never restored onto here. |

`hypr/monitors.lua` starts profile-scoped: each machine keeps a backup of its own screen layout.
The package and plugin inventory is recorded for each hostname, so two machines add to the repo
instead of overwriting each other.

```bash
omarchy-replicant profile              # which profile this machine is in
omarchy-replicant profile desktop      # put it in another one
omarchy-replicant scope hypr/input.lua profile
```

### Your list, not somebody else's

The plugin ships only the paths that any Omarchy machine plausibly has. **Your** own files go into a
list in your own repo, so they travel to your second machine and stay private.

Panel, **Configs**, **Add more files** proposes what is not tracked yet. Each row gives a reason and
a **Track** button. It never proposes a symlink, a mise shim, a browser's own state, a file that
another plugin installed, or a file identical to Omarchy's default. It marks a file that holds a
credential, so that you track it as a secret. Nothing is added until you press the button.

```bash
omarchy-replicant suggest                                # the same list, in a terminal
omarchy-replicant track ~/.local/bin/my-script
omarchy-replicant track ~/.config/nvim/                  # a whole directory
omarchy-replicant track ~/.config/gh/hosts.yml --secret  # stored at mode 600, never shown
```

### Big things are installed, not copied

The eight custom themes on the first machine were **556 MB**, and 400 MB of that was their own `.git`
directories. So what travels is the URL.

| | Recorded | Put back with |
| --- | --- | --- |
| Themes | Name and git origin | `omarchy theme set`. A missing theme: `install-theme <name>` |
| Plugins | Id, version, origin and method | Settings are copied back. The plugin: `install-plugin <id>` |
| Packages | For each hostname, official and AUR | Your package manager |

**A restore does not fetch a theme or a plugin.** It names each missing one with its origin. You
install it with `omarchy-replicant install-theme <name>`, `omarchy-replicant install-plugin <id>`,
or the **Install** button in the panel. An origin holds whatever its owner pushed today, and no
Omarchy install command takes a commit to pin, so fetching somebody else's code stays your decision.

Before a plugin installs, Replicant says what the Omarchy marketplace checked, and whether the origin
has moved since. Installing a theme also makes it the active theme.

### What else it does

- **46 paths out of the box**: 43 configs and 3 secrets, plus whatever you add, in eleven areas.
  You open the area you came for, so nothing scrolls forever.
- **What your setup loads comes with it.** Every module that `hyprland.lua` requires is saved with
  it, and so is every plugin's settings file. That includes a plugin that only your other machine has.
- **Directories, not only files.** `~/.config/nvim/` is one row with a file count. A change anywhere
  inside it shows up. A `.git` directory inside a tracked tree is never copied.
- **Change detection that tells the truth.** Every file is compared by content with its copy in
  your repo. Edit a file and the badge shows it. Put it back and the badge clears by itself.
- **The badges**, in the panel's own words: **●** unsaved, **↓** to restore, **↑** to push,
  **◆** saved, **○** default, **⊘** off, **·** not here.
- **It knows which way a change points.** After a `pull`, a file that another machine changed is
  marked **↓ to restore**, not ● unsaved. So the obvious button never commits over another
  machine's work.
- **It says whether a save reached GitHub.** If another machine pushed first, the save says so and
  tells you to pull.
- **24 settings from the panel**, in units that people use: the lock screen is *10 min*, not *600*.
- **Lid and sleep** on laptops: what closing the lid does on battery, on AC, and when docked.
- **Two ways back for every value**: one button to Omarchy's default, one to what your repo has.
- **Secrets stay secret.** SSH keys and `.env` files are stored at mode 600. The panel shows a kind,
  a mode and a count of variables. No value is ever drawn on screen, and the diff refuses to show one.
- **An undo for the undo.** Every write keeps the version it replaced as `.bak.<epoch>`. The
  Restore tab lists them and puts one back with a button. Undo is a swap, so it is itself reversible.
- **No terminal pop-ups.** Editing opens your editor, a diff renders in the panel, and a destructive
  action confirms in the panel.

### Second machine

```bash
omarchy plugin add https://github.com/tymurbogach/omarchy-replicant --enable --yes
P=~/.config/omarchy/plugins/io.github.tymurbogach.omarchy-replicant
$P/bin/omarchy-replicant clone https://github.com/<you>/<hostname>-replicant
```

Panel, **Restore**, *Preview* shows what would change, and touches nothing.

## Configure

- **Settings**: panel, **Settings**. A change is written to the real config file, applied, and
  committed. The CLI does the same with `omarchy-replicant set <id> <value>`, in the stored unit.
- **Scopes and profiles**: the scope button on every row of **Configs**, or `scope` and `profile`.
- **Your own files**: **Add more files** in the panel, or `track` and `untrack`.
- **A key for the panel**: bind `omarchy shell replicant toggle` in `~/.config/hypr/bindings.lua`.
  `omarchy shell replicant tab settings` opens the panel on one tab.
- **The command line**: the panel does not need it. To put `omarchy-replicant` on your `PATH`, run
  `$P/bin/omarchy-replicant link`. `unlink` takes it off again.

## Safety

Every command that writes to your machine is a dry run by default. Every file that it overwrites is
kept as `<file>.bak.<epoch>`. Nothing outside `$HOME` is written without a word: you get the exact
`sudo` command. Your data repo is **private and yours**. This repo holds only the plugin's code.

## Remove

`purge` lives inside the plugin, so run it **before** you remove the plugin:

```bash
P=~/.config/omarchy/plugins/io.github.tymurbogach.omarchy-replicant
$P/bin/omarchy-replicant purge                 # show what is on disk, and change nothing
$P/bin/omarchy-replicant purge --apply --repo  # remove it, the local clone included
omarchy plugin remove io.github.tymurbogach.omarchy-replicant
```

Your GitHub repo is not touched either way.

## Requirements

Omarchy 4 (Quattro), and two tools beyond a stock install. `omarchy-replicant doctor` checks both,
and it names the command that installs a missing one.

| Tool | Why | Install |
| --- | --- | --- |
| `github-cli` (`gh`) | Logs you in and creates the private repo | `omarchy pkg add github-cli` |
| `jq` | Reads and writes the JSON configs | `omarchy pkg add jq` |

`git` is on every Omarchy machine. The plugin pulls in nothing else, and it writes nothing outside
its own folder and `~/.local/share/omarchy-replicant/`.

## Docs

- [First-time setup](docs/getting-started.md)
- [How Replicant works](docs/SPEC.md)
- [Working on Replicant](CONTRIBUTING.md): the tests, and the traps this plugin has hit

## License

MIT. See [LICENSE](LICENSE).
