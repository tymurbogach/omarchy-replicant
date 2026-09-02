# Omarchy Replicant — Plugin

Omarchy 4 plugin that adds `omarchy-replicant` to sync your whole workspace via GitHub, into a
**private** repo created automatically for you.

Install with:

```bash
omarchy plugin add https://github.com/tymurbogach/omarchy-replicant --enable
```

Then:

```bash
omarchy-replicant init
omarchy-replicant create --push   # defaults to "<your-hostname>-replicant", always private (it holds secrets/)
# on another machine:
omarchy-replicant clone https://github.com/<user>/<your-hostname>-replicant
omarchy-replicant restore --apply --all
```

Restore everything:

```bash
omarchy-replicant reset-all --apply          # everything -> Omarchy defaults (factory)
omarchy-replicant restore --apply --all      # everything -> what's saved on GitHub
```

Your dotfiles repo is a separate, private, per-user repo (named `<your-hostname>-replicant` by
default) — never this one, and never called `omarchy-replicant` itself, since that name is taken
by this plugin.
