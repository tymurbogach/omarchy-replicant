# Replicant format

Replicant uses one repository format. A ready repository contains these
required paths:

```text
.replicant/schema.json
.replicant/entries.json
.replicant/machines/<machine>.json
.replicant/recipient.txt
vault/blobs/
vault/index.age
config/
profiles/<profile>/config/
state/<machine>/
```

`schema.json` contains exactly `{"format":"replicant"}`. The entries file
maps a safe ID to its absolute live path, kind, scope, and source. A kind is
`config` or `dir`. A scope is `shared`, `profile`, or `off`. A source is
`user` or `override`. IDs and live paths never contain `..`, `//`, or the
data directories themselves.

Machine records hold `{machineId, profile, clientVersion}`, one file per
machine. The recipient file holds the age public key for secrets. The vault
index is encrypted and maps each secret ID to its live path, scope, source,
and opaque blob ID. Blob IDs are random and reveal no path or name.

Secret content exists only as encrypted files in `vault/`. The panel never
renders secret content, and diffs report only whether a secret differs.
Secrets restore at mode 600. Secrets cannot use the `profile` scope: vault
blobs are global, so no per-profile copy exists to honour it.

`config/` holds shared copies. `profiles/<profile>/config/` holds one copy
per profile, so two machines never overwrite each other. `state/<machine>/`
holds the per-machine inventory (packages, plugins, themes). The repo also
carries `templates/`, the `.githooks/pre-commit` secret scanner,
`.gitignore`, and `.replicant-version` (the highest version that wrote it;
older clients copy in but never prune).

A scope of `off` publishes the policy once. Later saves and restores skip
the file, while Git keeps the last saved copy.

`create` initializes this layout and commits it through one transaction.
`clone` validates the staged copy before it activates it. A missing, empty,
corrupt, or different format is invalid for clone. Replicant does not read,
change, or delete invalid data.

Every repository mutation runs through the transaction journal in
`transactions/`: worktree saves commit a candidate, fast-forward only from
the recorded base, and push after activation. Shape writes (scope, policy,
track, keys, create) commit selected paths directly. A failed push keeps the
local commit with its journal for `tx resume`. Machine-local files
(`incoming`, `cache/state.json`, `key-rotation.json`) never enter the repo.
