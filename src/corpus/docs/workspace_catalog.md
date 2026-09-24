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
| `inspect` | `{workspace_id}` | `bee.workspaces.read` on `workspace_id` | `{workspace, live, applications, extensions}` |
| `search_within` | `{workspace_id, text, limit?}` | `bee.workspaces.read` on `workspace_id` | `{workspace_id, results}` |

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

**Inspect and search within.** `inspect` (`{workspace_id}`, read authority on
that workspace) returns the row, `live`, the applications its checkpoint keeps
open (`{view_id, instance_id, definition_id, restart_policy}`) and one entry
per workspace extension. `search_within` (`{workspace_id, text, limit?}`,
1-50, default 10) asks every extension for its hits and returns
`{workspace_id, results}`.

**Extensions.** Components attach per-workspace data and search through
bindings of `bee.workspace.catalog:extension`, never through catalog columns.
Its methods are `describe` (`{workspace_id}` to `{title, items, total}`, at
most 50 items of `{label, detail}`) and `search` (`{workspace_id, text, limit?}`
to `{title, hits}`), both answering with the reply envelope and only for
callers holding `bee.workspaces.read` on the workspace. The catalog finds the
bindings with `contract.find_implementations` (at most 16, in identity
order), calls each under its execution scope after it has authorized the
caller, checks every answer against those bounds and reports a failing
binding as that entry's `error` while the others stay intact. The host binds
the resources component's `describe` and `search`
(`bee:resources_workspace_extension`), so a workspace shows its resource
associations. Semantic search such as embeddings is a future binding of the
same contract.

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
the root volumes, the host-name lookup and the extension calls. The backend
refuses callers outside that scope.

## Live hosts

A workspace costs rows until something uses it. The node host manager
(`bee.launch:host_manager`, run by the service `bee:workspace_hosts` with a cap
of 64 live hosts and a 15-minute idle period) starts a workspace host when a
lease first asks for its workspace and stops it when no lease has held it for
the idle period. Classic folder mode is unchanged: its launch composition
starts and owns its one workspace host, and the manager reports that host as
served (`managed = false`) instead of starting a second one.

A lease is a process-registry name `bee.workspace.lease/<id>` its holder
registers under the host-named policy `bee:workspace_host_lease_policy`.
`bee.application:host_leases.acquire(workspace_id, timeout)` registers the name,
sends `bee.workspace.hosts.acquire` to the registered manager
`bee.workspace.hosts` and waits for `bee.workspace.hosts.result`
(`{host, managed}` or `error_code` `busy`, `unavailable`,
`permission_denied` or `request_conflict`). The manager answers only the
process that holds the name the request carries. A lease ends on
`release(lease)` or when its holder exits; an acquire that times out releases
its lease rather than retrying.

- The first lease starts the host with the explicit selection
  `{workspace_id}`; the host restores the workspace from its checkpoint.
  Leases taken while it starts wait for its readiness.
- A host no lease holds for the idle period receives the owner's `shutdown`
  request. It stops only through that path, which checkpoints the
  workspace's applications; a refused shutdown leaves it serving, and it is
  neither stopped when idle nor evicted again until a later lease on it ends.
- At the cap a new workspace takes the place of the least recently used host
  that no lease holds, after that host has stopped. When every live host is
  leased the request is refused with `busy`; a leased host is never evicted.
- Applications hold no lease. An application running in an unleased
  workspace stops with its host and restarts from its checkpoint when its
  restart policy is `automatic`.

## Workspaces viewer

`bee.workspaces:app` (Tools → Workspaces) is the bundled viewer on the shared
application frame. It holds one catalog page (50 rows) and the cursors back to
earlier pages, never the whole catalog; ↑↓ past either end of a page and
PgUp/PgDn load the neighbouring page. The Active and Archived tabs list each
state. `/` edits the search: text is a label prefix, text starting with `/`
a folder prefix under the node's workspace root (`bee:workspace_root`), and
Enter runs it from its first page.

The selected workspace's detail shows its folder, last use, creation and
identity, whether a host serves it, the applications its checkpoint keeps
open, up to ten of its threads (`bee.threads.service:list_workspace`) and one
section per workspace extension (resources and agent sessions in the default
composition), each with its count or the reason it could not be read. From
120x36 the detail sits beside a 40-cell list (48 from 160x48); below that Enter
opens it as its own page and Esc returns. A (Archive) asks first and archives
an active workspace; on the Archived tab it restores. S (Serve) holds a host
lease on the selected workspace while the viewer stays open, so the node host
manager starts its host; S again, or closing the viewer, releases it.

Its admission binding grants `bee:workspace_catalog_read_policy`,
`bee:workspace_catalog_manage_policy`, `bee:thread_workspace_list_policy`,
`bee:workspace_host_lease_policy` and `bee.workspaces:client_policy`, which may
call only the catalog operations it uses and `list_workspace`.
