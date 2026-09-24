# Workspace catalog

One Bee node holds any number of logical workspaces as rows of the node
workspace catalog (see [storage](storage.md)). The catalog operations are the
owner operations over those rows. They are contract
`bee.workspace.catalog:contract`, bound by `bee.workspace.catalog:local` to the
functions `bee.workspace.catalog:<method>`.

Every reply is `{ok, error = {code, message}, value}`. Codes: `INVALID`
(the request fails its decoder), `UNAUTHENTICATED`, `DENIED`, `FORBIDDEN`
(a root the host has not admitted, or not for writing), `NOT_FOUND`,
`CONFLICT`, `BUSY`, `STORAGE`, `UNAVAILABLE` and `UNCERTAIN` (the outcome is
unknown; do not retry blindly).

| Method | Request | Authorized as | Value |
|---|---|---|---|
| `create` | `{label, root_ref, subpath?, create_directory?}` | `bee.workspaces.manage` on `root_ref` | the new row |
| `read` | `{workspace_id}` | `bee.workspaces.read` on `workspace_id` | `{workspace, live}` |
| `list` | `{state?, after?, limit?}` | `bee.workspaces.read` on `catalog` | `{items, next_after?}` |
| `search` | `{state?, label? \| root_ref + path?, after?, limit?}` | `bee.workspaces.read` on `catalog` | `{items, next_after?}` |
| `rename` | `{workspace_id, label}` | `bee.workspaces.manage` on `workspace_id` | the row |
| `archive` | `{workspace_id}` | `bee.workspaces.manage` on `workspace_id` | the row |
| `restore` | `{workspace_id}` | `bee.workspaces.manage` on `workspace_id` | the row |

A row is `{workspace_id, label, root_ref, subpath, state, created_at,
last_used_at}`. `live` says whether a host serves the workspace now.

**Create.** A label is one nonempty line of at most 240 bytes. `root_ref` must
be listed in the host's admitted roots (`bee:resource_roots`, the same ceiling
resource associations use); a caller never supplies a path outside it.
`subpath` is relative, without empty, `.` or `..` segments. Without
`create_directory` the folder must already exist as a directory. With it, the
root must be admitted for writing, the parent folder must exist and the last
segment must not; the folder is made inside the transaction that inserts the
row. One folder is one workspace, so a second row for the same root and
subpath is a `CONFLICT`.

**List and search.** `state` is `active` (the default) or `archived`. A page
holds `limit` rows (1-100, default 50) and `next_after` when more follow; pass
it back as `after`. Cursors are exact keyset positions, so rows added or
changed before the cursor never shift a later page. `list` and label search
walk the index `(state, lower(label), workspace_id)`; `label` matches a prefix,
case-folded over ASCII letters. Path search takes `root_ref` and an optional
`path` and walks `(state, root_ref, subpath)`: it returns the folder named by
`path` first, then every folder below `path/`, never a sibling such as
`path-old`. No operation reads rows it does not return.

**Archive and restore.** An archived workspace is never served. `archive`
refuses with `BUSY` while a host is registered for the workspace. Repeating
either change returns the row unchanged.

**Authority.** The operations run for any caller whose scope allows their
action; host-named policies `bee:workspace_catalog_read_policy` and
`bee:workspace_catalog_manage_policy` grant them. Applications cannot open the
node workspace store (their storage boundary denies it), so each operation
authorizes the caller for the decoded request and then runs the private
backend `bee.workspace.catalog:backend` under the execution scope
`bee:workspace_catalog_scope`, which holds the store, the admitted roots list,
the root volumes and the host-name lookup. The backend refuses callers outside
that scope.
