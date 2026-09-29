# Omarchy Replicant

Replicant saves Omarchy configuration in a private Git repository. It stores
secret values as encrypted Age files in `vault/`.

## Install

Install and enable the plugin with Omarchy:

```sh
omarchy plugin add https://github.com/tymurbogach/omarchy-replicant --enable
```

Open Replicant from the bar. On the first machine, select **Create private
repo**. The panel creates the private GitHub repository and pushes the first
commit. On another machine, select **Clone existing** and paste its URL.

The optional terminal command is inside the installed plugin:

```sh
~/.config/omarchy/plugins/io.github.tymurbogach.omarchy-replicant/bin/omarchy-replicant link
omarchy-replicant status
```

After `link`, create a private repository from a terminal with:

```sh
omarchy-replicant create --push
```

Use `clone <url>` on another machine. Clone accepts only a complete Replicant
repository. Use Create when the remote repository is empty.

Run `save --all --auto` to copy configuration, commit it, and push it. Run
`restore --dry-run` before a restore. `save-file <id>` and `bulk save`
save single entries; the panel Save button saves everything.

## Repository format

The repository has one format. Its marker is:

```json
{"format":"replicant"}
```

The marker is in `.replicant/schema.json`. `.replicant/entries.json`,
`.replicant/machines/`, and `vault/` are required. Plain secret files are not
allowed under `secrets/`.

Replicant does not modify an invalid repository. Create a new repository for
data that does not use this format.

## Remove

Disable and remove the plugin:

```sh
omarchy plugin disable io.github.tymurbogach.omarchy-replicant
omarchy plugin remove io.github.tymurbogach.omarchy-replicant --yes
```

Replicant leaves the private repository and keys in place. Remove them only
with the explicit purge action after you confirm its target.

## Configure

Use **Configs** to select tracked files and their scope. Use **Settings** for
managed Omarchy settings. Run `key init` before you add secrets.

## Requirements

Replicant requires Omarchy, Git, GitHub CLI authentication, and Age for
encrypted secrets. GitHub SSH authentication is optional when you select SSH
transport.

## License

Replicant is released under the [MIT License](LICENSE).
