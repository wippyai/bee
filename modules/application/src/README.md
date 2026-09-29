# bee.application

The public application SDK. It provides bounded launch arguments, application
client and interaction values, caller and status helpers, semantic appearance
and naming values, and the wire decoder used by an application's authenticated
thread facade. These libraries carry values only: they do not admit an
application, select a workspace, open a store, or grant access to a thread.

| Entry | Responsibility |
|---|---|
| `client`, `arguments`, `interaction` | Application launch and broker-facing values used by standalone application processes |
| `caller`, `text`, `status_reader`, `status_surface` | Typed owner replies and bounded presentation values |
| `appearance`, `names` | Shared semantic presentation values for applications and desktop consumers |
| `frame` | The application frame every Bee application draws with: size classes and layout, header, tabs, action bar, status and key-hint footer, list window, table, tree view, key-value inspector and log viewer (full width, or confined to a pane's `area`), panels, form fields, wizard steps, empty state, virtualized log viewer with search highlight, status badge, toast, modal and command palette (`fuzzy` filter) |
| `viz` | The visualization kit on the frame: sparklines, line and area charts, bars, columns, stacked bars, histograms, heatmaps, status grids, gauges, progress, stat tiles, inline table bars, timelines, small graphs, scatter plots, candlestick and range charts, a braille radial gauge, a spinner, 100% stacked bars, progress with ETA and bounded live series with a redraw cadence |
| `forms` | The input kit on the frame: a text field (cursor, word and line motions, select-all, paste, placeholder, `max_length`, masked mode), a bounded number field, a scrolling multi-line text area, a select/dropdown, a checkbox, a radio group and a toggle, plus a form container that owns focus order (Tab/Shift-Tab/click), per-field validation, dirty tracking and a disabled state |
| `diagram` | Layout diagrams on the frame: `mesh` (nodes at chosen or ringed positions, braille-routed edges, node hits), `treemap` (squarified tiles of sized items) and `flame` (icicle chart of a value tree); pure painters with hit targets, in the same node and bar vocabulary as `viz` |
| `thread_protocol` | Exact bounded requests and replies for the authenticated application-to-broker thread facade |
| `folder_picker` | A folder picker over the roots the host admits through the workspace catalog's `roots` and `folders` operations: the pure paging and navigation model and its table on the frame |
| `agent_protocol` | The typed request that starts a managed agent, shared by `agents`, the gateway's `thread_launch` and the harness that admits it |
| `agents` | Managed agents for applications and agents: `launch` or `run` one on an existing or a new thread with a chosen working directory and placement, read its `status`, `wait` for it through its thread and `cancel` it, all as the caller's own actor through `bee.harness.launch:agent_call`; `run` returns a durable receipt promptly; `cancel` supports idempotent cancel intents and terminal carrier wait; the host grants `bee.harness.launch` on each definition a caller may start |
| `sessions`, `sessions_protocol` | The typed `sessions` client: `call`, `open`, `send`, `await`, `join`, `cancel`, `close`, `get`, `work`, `list` and `catalog` over the `bee.sessions` owner contracts, with Session, Work and Operation handles; `sessions_protocol` holds the closed reply types and their decoders |
| `host_leases` | Leases on node-managed workspace hosts: the holder registers a lease name, asks the node host manager for a workspace's host and releases it; the manager answers only the holder of that name, and the host policy `bee.security.desktop:workspace_host_lease_policy` decides who may name leases |

Proven reference screens for each application class (deploy board, CI board,
inbox, log viewer, topology, workflow, live metrics, deploy wizard with forms,
and the palette, modal and toast overlays) live in `docs/reference/apps/`. They
use only this public API, are not registered entries and never ship as an
application; `make reference-apps-check` lints and draws them against these
libraries, and the agent corpus serves them under the `reference_apps` topic.

Applications still run as standalone processes. The host admits their exact
definition and policies; the broker supplies execution identity and durable
thread bindings. Registry metadata and SDK imports do not authorize an
application or a thread operation.

## Sessions client

`sessions` (`bee.application:sessions`) calls the `bee.sessions:contract` and
`bee.sessions:catalog` owner contracts through their default bindings, as the
calling process's own actor. It grants nothing; the host admits the caller and
the owner authorizes every operation. Each function returns `value, Fault?`;
a Fault is `{code, message, retry, operation_key?, operation?, current_revision?,
evidence?, retry_after_ms?}` and `retry` is `never`, `same_key`, `refresh` or
`reconcile`. Owner replies are decoded against the closed owner schemas and any
deviation is a Fault, never a partial value.

```lua
local c = sessions.call{definition = "research:quick", input = "Summarize the repository", timeout_ms = 30000}
-- c.work is the Work handle; c.observation.tag is ready, pending, blocked or uncertain.
local s = sessions.open{definition = "research:worker"}
local w = s:send{input = "Check the baseline"}
local a = w:await{timeout_ms = 30000}
local closing = s:close{mode = "drain"}
```

- `call{definition, input, output?, profile?, workdir?, timeout_ms?}` opens a session with its first work in one owner operation and awaits it once. It returns `{work, observation}` on every observation branch. An unsuccessful settlement is a `ready` observation whose `result.outcome` is not `succeeded`.
- `open{definition, profile?, workdir?}` returns a Session. `send{session?, input, output?}` (or `session:send`) returns a Work whose `receipt` proves intake only. Work is queued; nothing runs inside the call.
- `cancel` and `close{mode?}` return an Operation whose `await` reports `stopped`/`already_terminal` or `closed`, or an uncertain evidence branch.
- `await{subject}`, `work:await` and `operation:await` observe one work or operation; `timeout_ms` is at most 60000 and bounds observation, never execution. `session:await(work)` also checks that the work belongs to the session.
- `join{works, policy?, quorum?, losers?, timeout_ms?}` takes 1 to 64 distinct works, returns one `JoinAwait` with every child's observation in input order, and validates `quorum` against the set.
- `get(session_ref)` and `work(work_ref)` rehydrate a Session or Work from a ref; `work:state()` reads the `WorkState`, which carries `sender`, the owner-set authenticated sender of the work (a SessionRef when the caller is a session, else the principal). Callers never supply a sender. Refs (`bs:`, `bw:`, `bo:`, `bj:` qualified strings) are the only addresses; `:ref()` returns one.
- Handles capture the session incarnation and send it as `expected_incarnation`; a session reset makes them fail with `STALE` rather than act on the new incarnation.
- `list{filter?, after?}` filters by `lifecycle`, `activity` (`idle`, `working`, `blocked`, `stalled`) and `mode`; session snapshots carry both. `catalog{kind?, include_unavailable?, after?}` returns the owner's candidates.

Requests are validated before dispatch (`INVALID`): bounded text and refs, JSON inputs of at most 64 KiB and depth 16.

### Operation keys

Every mutation carries an operation key. The client derives it from the caller's
durable context, the operation, the target and an optional label, so a replayed
handler reproduces the same keys and receives the original receipts.

- Inside an application handler the context is the durable event the `bee.application:context` contract reports through `get_event`. `sessions.scope(persisted_id)` returns a client bound to an identifier the caller persisted, with the same functions as methods (`owner:open{...}`).
- Repeating a call with the same arguments reuses its key. A second, different call of the same operation on the same target in one context needs a distinct `key` label on each; without one it fails `KEY_REQUIRED` before dispatch. Call order never supplies identity.
- With no durable context a mutation fails `CONTEXT_REQUIRED`. An explicit `operation_key` (the caller's own journaled key, exclusive with `key`) is accepted anywhere.
- A lost or malformed mutation reply is `UNKNOWN_OUTCOME` with `retry = "same_key"` and the key echoed; replaying the call reproduces the key. The client never invents a new key for a retry.
