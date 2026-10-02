# Shipped migration histories

These fixtures contain the original SQL bytes, without catalog data. The tests
apply both shipped variants and compare schema and owner data after the appended
repair migrations; each original ledger digest remains unchanged.

The audit covers all 104 declared migration identities across the 999 first-parent
commits of main through the installed baseline `893d1216`, following source moves
by migration-1 identity. These are all SQL changes found under an existing ID/name:

| Store / migration | Original text introduced | Text edited | Repair |
|---|---|---|---|
| Workspace 6 | `9d9cb9b9` | `4b40d661` | Workspace 14 |
| Workspace 8 | `3f1fe4a8` | `4b40d661` | Workspace 14 |
| Workspace 9 | `009e2aa4` | `e3e411c9` | Workspace 13 |
| Threads 16 | `b791c77b` | `d889183d` | Threads 29 |
| Governance 14 | `2f5dac62` | `7608c88b` | Governance 16 |
| Gateway 16 | `20786324` | `9aa63169` | Gateway 17 |
| Sync 4 | `2f6a92d4` | `c6e213e9` | Exact historical checksum; whitespace only |
| Sync 8 | `20786324` | `9aa63169` | Sync 9 |

For example, `git log -S "WHEN 'bee.inbox:app' THEN 'bee.approvals.inbox.app:app'"
893d1216 -- src/storage/store.lua` identifies `e3e411c9`'s edit to migration 9.
Its other match, `a645f321`, appends migration 12 without changing migration 9.
