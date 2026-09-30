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
| `frame` | The application frame every Bee application draws with: size classes and layout, header, tabs, action bar, bounded status and reserved key-hint footer, declared-action Help and overflow More menu, list window, table, tree view, key-value inspector and log viewer (full width, or confined to a pane's `area`), panels, form fields, wizard steps, empty state, virtualized log viewer with search highlight, status badge, toast, modal and command palette (`fuzzy` filter) |
| `viz` | The visualization kit on the frame: sparklines, line and area charts, bars, columns, stacked bars, histograms, heatmaps, status grids, gauges, progress, stat tiles, inline table bars, timelines, small graphs, scatter plots, candlestick and range charts, a braille radial gauge, a spinner, 100% stacked bars, progress with ETA and bounded live series with a redraw cadence |
| `forms` | The input kit on the frame: a text field (cursor, word and line motions, select-all, paste, placeholder, `max_length`, masked mode), a bounded number field, a scrolling multi-line text area, a select/dropdown, a checkbox, a radio group and a toggle, plus a form container that owns focus order (Tab/Shift-Tab/click), per-field validation, dirty tracking and a disabled state |
| `diagram` | Layout diagrams on the frame: `mesh` (nodes at chosen or ringed positions, braille-routed edges, node hits), `treemap` (squarified tiles of sized items) and `flame` (icicle chart of a value tree); pure painters with hit targets, in the same node and bar vocabulary as `viz` |
| `thread_protocol` | Exact bounded requests and replies for the authenticated application-to-broker thread facade |
| `folder_picker` | A folder picker over the roots the host admits through the workspace catalog's `roots` and `folders` operations: the pure paging and navigation model and its table on the frame |
| `sessions`, `sessions_protocol` | The typed `sessions` client: `call`, `open`, `send`, `await`, `join`, `cancel`, `close`, `get`, `work`, `history`, `list` and `catalog` over the `bee.sessions` owner contracts, with Session, Work and Operation handles; `sessions_protocol` holds the closed reply types and their decoders |
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

Shared frame controls are application-owned values. Views return
`controls = frame.controls(painter)` with their rows and hits. The actor owns
a `frame.menu()` record, calls `frame.render(drawn, menu, preferences)` before
presenting, and routes terminal events through `frame.route(menu, event, text_entry)`
before its normal handlers. Nil means consumed; the second return value requests
a redraw. More dispatches an enabled choice through the actor's existing mouse
handler. Help lists declared buttons, tabs and hints, including unavailable
actions. `Button.key` names the shortcut; `primary` reserves room when buttons
overflow. Text entry preserves case and literal `?`; the Help footer stays
clickable. Neither overlay grants permissions or bypasses app confirmations.

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
local c = sessions.call{definition = "research:quick", input = "Summarize the repository", operation_key = "call/summary", timeout_ms = 30000}
-- c.work is the Work handle; c.observation.tag is ready, pending, blocked or uncertain.
local s = sessions.open{definition = "research:worker", operation_key = "open/worker"}
local w = s:send{input = "Check the baseline", operation_key = "send/baseline"}
local a = w:await{timeout_ms = 30000}
local closing = s:close{operation_key = "close/worker"}
```

- `call{definition, input, operation_key, output?, profile?, workdir?, timeout_ms?}` opens a session with its first work in one owner operation and awaits it once. It returns `{work, observation}` on every observation branch. An unsuccessful settlement is a `ready` observation whose `result.outcome` is not `succeeded`.
- `open{definition, profile?, workdir?, operation_key}` returns a Session. `send{session?, input, output?, operation_key}` (or `session:send`) returns a Work whose `receipt` proves intake only. Work is queued; nothing runs inside the call.
- `cancel{work, operation_key}` and `close{session, operation_key}` return an Operation whose `await` reports `stopped`/`already_terminal` or `closed`, or an uncertain evidence branch.
- `await{subject}`, `work:await` and `operation:await` observe one work or operation; `timeout_ms` is at most 60000 and bounds observation, never execution. `session:await(work)` also checks that the work belongs to the session.
- `join{works, operation_key, policy?, quorum?, timeout_ms?}` takes 1 to 64 distinct works, returns one `JoinAwait` with every child's observation in input order, and validates `quorum` against the set.
- `get(session_ref)` and `work(work_ref)` rehydrate a Session or Work from a ref; `work:state()` reads the `WorkState`, which carries `sender`, the owner-set authenticated sender of the work (a SessionRef when the caller is a session, else the principal). Callers never supply a sender. Refs (`bs:`, `bw:`, `bo:`, `bj:` qualified strings) are the only addresses; `:ref()` returns one.
- Handles capture the session incarnation and send it as `expected_incarnation`; a session reset makes them fail with `STALE` rather than act on the new incarnation.
- `list{filter?, cursor?}` filters by `workspace`, `definition`, `lifecycle` and `activity` (`idle`, `working`, `blocked`, `stalled`); session snapshots carry both. `catalog{kind?, include_unavailable?, cursor?}` returns the owner's candidates.

Requests are validated before dispatch (`INVALID`): bounded text and refs, JSON inputs of at most 64 KiB and depth 16.

### Operation keys

Every mutation requires an explicit `operation_key`. The SDK cannot derive a
durable identity from the current application broker or client, so applications
must persist their own key before dispatch and reuse it after an uncertain
reply. Reusing a key with different arguments is a conflict.

Session snapshots expose `thread_ref`, `workspace`, driver/provider, definition and the latest settled result summary. `session:history{cursor?, limit?}` pages immutable Work inputs and refs in sequence order; rehydrate each Work to observe its current result. `client.navigate(launch, definition_id, arguments?)` queues an admitted app open through the current authenticated broker execution. A receiving app listens on `bee.application.navigate` and passes the message sender and payload to `client.navigation(launch, sender, payload)`; the helper returns bounded arguments only for the current broker execution.
