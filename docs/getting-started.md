# Get started

Run `omarchy-replicant create --push` on the first machine. The command creates
or uses a private GitHub repository, initializes the local copy, and pushes the
first commit.

Run `omarchy-replicant clone <url>` on each other machine. The remote must hold
a complete Replicant repository. If it is empty, return to the first machine
and use Create.

Run `omarchy-replicant key init` before you save secrets. Run
`omarchy-replicant save --auto` to save configuration. Review a restore with
`omarchy-replicant restore --dry-run` before you apply it.
