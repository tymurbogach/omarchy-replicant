# Replicant format

Replicant uses one repository format. The repository contains these required
paths:

```text
.replicant/schema.json
.replicant/entries.json
.replicant/machines/<machine>.json
vault/blobs/
```

`schema.json` contains exactly `{"format":"replicant"}`. The entries file
maps a safe ID to its absolute live path, kind, scope, and source. A scope is
`shared`, `profile`, or `off`.

Secret content exists only as encrypted files in `vault/`. The vault index
maps secret IDs to opaque blob IDs. The panel never renders secret content.

`create` initializes this layout and commits it. `clone` validates the staged
copy before it activates it. A missing, empty, corrupt, or different format is
invalid for clone. Replicant does not read, change, or delete invalid data.
