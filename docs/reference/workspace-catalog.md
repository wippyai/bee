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
| `search` | `{state?, label? \| root_ref + path? \| path, after?, limit?}` | `bee.workspaces.read` on `catalog` | `{items, next_after?}` |
| `rename` | `{workspace_id, label}` | `bee.workspaces.manage` on `workspace_id` | the row |
| `archive` | `{workspace_id}` | `bee.workspaces.manage` on `workspace_id` | the row |
| `restore` | `{workspace_id}` | `bee.workspaces.manage` on `workspace_id` | the row |
| `inspect` | `{workspace_id}` | `bee.workspaces.read` on `workspace_id` | `{workspace, live, applications, extensions}` |
| `search_within` | `{workspace_id, text, limit?}` | `bee.workspaces.read` on `workspace_id` | `{workspace_id, results}` |
| `roots` | `{}` | `bee.workspaces.read` on `catalog` | `{roots}` |
| `folders` | `{root_ref, path?, after?, limit?}` | `bee.workspaces.browse` on `root_ref` | `{root_ref, path, access, workspace_id?, folders, next_after?}` |

A row is `{workspace_id, label, root_ref, subpath, state, created_at,
last_used_at}`. `live` says whether a host serves the workspace now. The
folder workspace's row has an empty label; readers name it by identity.

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
`path-old`. A `path` without `root_ref` runs that search under every root the
host admits (`bee:resource_roots`), one root after another in name order; its
cursor names the root of the page's last row. No operation reads rows it does
not return.

**Roots and folders.** `roots` lists the roots the host admits
(`bee:resource_roots`) in name order as `{root_ref, access}`, `access` being
`read` or `write`. `folders` pages the folders inside `path` (a subpath, default
the root itself) under an admitted root: names in byte order after the folder
name `after`, `limit` 1-100 (default 50), each `{name, workspace_id?}` naming the
workspace, in any state, that holds that folder. Files and hidden folders
(a leading `.`) are left out. The answer also carries the root's `access` and
the workspace that holds `path` itself. The directory is read once per page and
only the page's names are kept; a root the host does not admit is `FORBIDDEN`
and a path that is not a folder `NOT_FOUND`. These are what a folder picker needs
to offer a `create` or a launch folder. Browsing a root is its own action,
`bee.workspaces.browse`: `bee.security.storage:workspace_catalog_manage_policy` grants it with
management, and `bee.security.storage:workspace_folder_browse_policy` grants it with the
catalog read `roots` needs and nothing else, which the Agent window holds for
its folder choice. `bee.application:folder_picker` is the shared picker model
and table both the Workspaces create flow and the Agent profile form use.

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
action; host-named policies `bee.security.storage:workspace_catalog_read_policy` and
`bee.security.storage:workspace_catalog_manage_policy` grant them. Applications cannot open the
node workspace store (their storage boundary denies it), so each operation
authorizes the caller for the decoded request and then runs the private
backend `bee.workspace.catalog:backend` under the execution scope
`bee.security.storage:workspace_catalog_scope`, which holds the store, the admitted roots list,
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
registers under the host-named policy `bee.security.desktop:workspace_host_lease_policy`.
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
- A launched agent run holds a lease on its catalog workspace for the run's
  whole duration (`bee.harness.carrier:lease`), so the workspace is served
  while the agent works. An identity outside the catalog's form names no host.

### Desktops through the host manager

The manager is every managed host's owner, so it admits desktops for the lease
holders that attach to it. A holder sends `bee.workspace.hosts.attach`
(`{request_id, lease}`) and the manager answers `bee.workspace.hosts.attached`
with the host's readiness announcement, or `unavailable` while the host starts.
From then on the holder sends desktop admission requests (`bee.host.client`,
the host's own format) to the manager, which forwards them to the host only for
the workspace the holder leases and only for recipients that holder admitted;
the host's answers (`bee.host.client_result`) come back through the manager. A holder whose last lease on the host ends loses its
attachment and its recipients.

A retained desktop supervisor (`bee.launch:retained`) selected by workspace
identity uses this path: it takes a lease instead of spawning a host, attaches,
admits its displays through the manager and releases the lease when it ends; it
never stops the host, and its displays quit through their own lifecycle. A
supervisor selected by the folder's root (classic mode and `bee start`) still
spawns and owns its host.

The desktop bridge in the Hive supervisor (`src/hive_host/desktop`) composes the
folder workspace when the host selects it (`desktop.folder`, default true) and
starts a leased supervisor for any other workspace a client attaches to, at
most 32 at once; the workspace's last detach stops that supervisor and so
releases its host lease. A client attaches to one workspace at a time.
`bee.desktop:list` takes `{owner_execution?, label?, after?, limit?}` and answers
`{owner_execution, desktops, workspaces, next_after?, default_workspace?}`: the
node's display identities (default first), one page of active workspaces
`{workspace_id, label, served}` and the folder workspace when the bridge
composes one. A listing may omit `owner_execution` to learn it from the answer;
every other operation names it, and a stale one is refused. `bee.desktop:create`
allocates one node display (`{owner_execution, desktop_id}`); displays belong to
the node and attach to any workspace. `bee.desktop:current` (`{owner_execution}`)
answers the sender's current session in the attach receipt's shape.

A remote display registers its lifetime with the supervisor on its own node
before attaching to the owner. That supervisor monitors the local display
process and reports its exact exit to the owner node's supervisor. The owner
accepts the notice only from the protected supervisor host of a node its host
admitted, and revokes that recipient's attachment. This covers a display
process crash even when a remote process monitor reports only node loss.

### Switching a display's workspace

A display the bridge serves shows another workspace without its client
detaching. F9 opens the connection panel and W its workspace menu: one catalog
page at a time (`/` searches labels, PgUp/PgDn page, the shown workspace is
marked, Enter switches). The display's client process reads the pages with
`bee.workspace.catalog:list` and `:search` under host-selected grants
(`bee.security.desktop:client_workspace_catalog_call_policy`, `bee.security.storage:workspace_catalog_read_policy`)
and sends the switch to its retained supervisor, which forwards it, naming the
display, to the bridge (`bee.retained.switch`). The bridge moves the display's
controlling client: it starts or reuses the target workspace's leased
supervisor, attaches the client with control to the same display there, and
only then releases the client's grant on the workspace it leaves, stopping that
workspace's leased supervisor when no client uses it. It answers
`bee.retained.switched` back to the display. A refused, failed or timed-out
attach leaves the client on its workspace. Observers of the display stay where
they are. The native client sees its old mount end, asks `bee.desktop:current`
and presents the new session on the same terminal; a local detach (Ctrl+]),
leave (Ctrl+Q) or any other end is final. N in the workspace menu
opens the Workspaces viewer on its create flow (below); a viewer already open is
focused instead, since an open of a running single-instance application only
focuses it. `make native-workspace-switch-check` creates a second workspace with
`bee workspace create`, switches a running desktop to it and back.

### Workspace commands

`bee workspace` manages the catalog of the running node from its folder (or
`--state`); with no running owner it refuses and starts nothing.

```text
bee workspace list [--archived] [--after CURSOR]      one page of 50; NEXT names the next cursor
bee workspace roots                                   the admitted roots and their access
bee workspace create LABEL ROOT[/PATH] [--new-folder] a workspace for PATH under ROOT; --new-folder makes it
bee workspace archive WORKSPACE
bee workspace restore WORKSPACE
```

The command joins the owner as an enrolled local client and calls service
`bee.workspace` (`bee.workspace:list`, `:roots`, `:create`, `:archive`,
`:restore`) on the owner's Hive supervisor. The supervisor serves it only to
an enrolled local client of its own node and only while the host grants it
`bee.workspaces.command` on the operation (`bee.security.hive:workspace_command_policy`,
selected for the supervisor service). It runs the command on its worker
`bee.hive_host.supervisor:workspace_command`, which again requires that grant from
its caller and calls the catalog operation under the policies the host attaches
to the worker (`bee.security.storage:workspace_catalog_read_policy`,
`bee.security.storage:workspace_catalog_manage_policy`, `bee.security.hive:workspace_command_catalog_policy`);
neither the client nor the supervisor holds catalog authority. The catalog still
decodes and authorizes every request. Catalog refusals come back as Hive faults
whose message keeps the catalog code (`FORBIDDEN: root ... is not admitted`); a
catalog `BUSY` is `INVALID_STATE`, and a command past its deadline is
`UNCERTAIN` with its identity.

### Node modes

- **Folder** (`bee`, `bee start`): the folder is the node's workspace, composed
  and served by its own launch composition.
- **Daemon** (`bee daemon`): the node runs from the folder's state without
  composing the folder as a workspace; it prints `BEE_DAEMON_READY NODE SEED
  PID` and serves catalog workspaces to clients through leases. The folder's
  catalog row is created by the classic launch path when it first opens the
  folder, so a daemon started on a new node database lists no folder
  workspace; a node that ran in folder mode before keeps its row.
- **Client** (`bee client`, `bee observe`): joins a running node and never
  starts one. When the node composes a folder workspace the client attaches to
  it; otherwise it shows a workspace picker (one catalog page, `/` label
  search, PgUp/PgDn paging, Enter to open). Ctrl+] detaches and returns to the
  picker; Ctrl+Q leaves.
- **Hive member**: `bee.hive_host:workspaces` is an open Hive operation that
  pages a node's catalog (`{label?, after?, limit?}` to `{node_id, workspaces,
  next_after?}`, each row with whether a host serves it); the Hive app lists and
  searches the selected node's workspaces through it. A Hive display client
  from a node the host admits (`desktop.allowed_nodes` or
  `desktop.allowed_peers`) attaches to any of the
  node's workspaces by identity through the bridge's lease path. The Hive
  Manager's Control and Observe open the selected workspace of another node as
  a remote view in its window: a view process (`bee.hive_host.desktop:viewer`) on
  the display client host lists the owner's displays naming no execution,
  attaches through that node's bridge (control reuses a display without a
  controller and allocates one only after definite `DESKTOP_CONTROLLED`
  refusals; observe uses the default display), streams the rendered rows to the
  window and takes its input while it controls. Alt+Q leaves and detaches. This
  node's own workspaces open from the workspace menu instead, since a node never
  admits itself as a remote client. The owner node decides admission.

### Displays from a joined peer

An owner's bridge keeps static host grants (`desktop.allowed_nodes`) separate
from revocable Hive grants (`desktop.allowed_peers`). Local clients use the
`local_clients` enrollment. Native launch leaves both lists empty unless the
owner starts with `BEE_DESKTOP_ALLOWED_PEERS=NODE[,NODE...]`, naming up to 64
exact node IDs already pinned by a Hive join. It places those IDs in
`allowed_peers`, which the bridge admits only while the peer remains in the
host enrollment. The owner refuses malformed, duplicate, self, or unpinned
selections. It applies changed selections on restart; removing a peer pin
retires that peer's desktop attachments. A pin or invite by itself grants no
desktop access. The selected peer can control or observe the owner's
workspaces from Hive Manager.

## Workspaces viewer

`bee.workspaces:app` (Tools → Workspaces) is the bundled viewer on the shared
application frame. It holds one catalog page (50 rows) and the cursors back to
earlier pages, never the whole catalog; ↑↓ past either end of a page and
PgUp/PgDn load the neighbouring page. The Active and Archived tabs list each
state. `/` edits the search: text is a label prefix, text starting with `/`
a folder prefix under every root the host admits, and Enter runs it from its
first page.

The selected workspace's detail shows its folder, last use, creation and
identity, whether a host serves it, the applications its checkpoint keeps
open, up to ten of its threads (`bee.threads.service:list_workspace`) and one
section per workspace extension (resources and agent sessions in the default
composition), each with its count or the reason it could not be read. From
120x36 the detail sits beside a 40-cell list (48 from 160x48); below that Enter
opens it as its own page and Esc returns. A (Archive) asks first and archives
an active workspace; on the Archived tab it restores. N (New) opens the create
flow, and a launch with the argument `create` opens the viewer on it.

The create flow is a two-step wizard. **Folder** lists the roots the host
admits (`roots`); Enter opens one and then the folder under the selection, one
page of `folders` at a time (↑↓ past either end and PgUp/PgDn page), ⌫ goes up,
and a folder that already holds a workspace is marked. U uses the folder shown.
**Details** asks for the label, which follows the folder's name until it is
edited, and, under a root admitted for writing, an optional new folder made
inside the chosen one (`create_directory`). Enter creates; a folder that is a
workspace already needs a new folder, and the catalog's refusal stays on the
form. The new workspace is selected on the Active tab's first page when that
page holds it. S (Serve) holds a host
lease on the selected workspace while the viewer stays open, so the node host
manager starts its host; S again, or closing the viewer, releases it.

Its admission binding grants `bee.security.storage:workspace_catalog_read_policy`,
`bee.security.storage:workspace_catalog_manage_policy`, `bee.security.threads:thread_workspace_list_policy`,
`bee.security.desktop:workspace_host_lease_policy` and `bee.workspaces:client_policy`, which may
call only the catalog operations it uses (`list`, `search`, `inspect`,
`archive`, `restore`, `create`, `roots`, `folders`) and `list_workspace`.
