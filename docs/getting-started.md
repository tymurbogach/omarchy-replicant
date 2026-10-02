# Get started

Install Replicant first:

```sh
omarchy plugin add https://github.com/tymurbogach/replicant --enable
```

Open Replicant from the bar. The first screen provides **Create private repo**
and **Clone existing**. You do not need the terminal for normal setup.

Run `replicant create --push` on the first machine. The command creates
or uses a private GitHub repository, initializes the local copy, and pushes the
first commit.

Run `replicant clone <url>` on each other machine. The remote must hold
a complete Replicant repository. If it is empty, return to the first machine
and use Create.

Run `replicant key init` before you save secrets. Run
`replicant save --all --auto` to save configuration. Review a restore with
`replicant restore --dry-run` before you apply it.
