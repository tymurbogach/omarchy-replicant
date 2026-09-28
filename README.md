# Omarchy Replicant

Replicant saves Omarchy configuration in a private Git repository. It stores
secret values as encrypted Age files in `vault/`.

Install the plugin, then create a private repository:

```sh
omarchy-replicant create --push
```

Use `clone <url>` on another machine. Clone accepts only a complete Replicant
repository. Use Create when the remote repository is empty.

Run `save --auto` to copy configuration, commit it, and push it. Run
`restore --dry-run` before a restore.

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

Use the plugin removal command to remove plugin code. Replicant leaves the
private repository and keys in place. Remove them only with an explicit purge
command after you confirm the target.
