# bee.app

The public application SDK. It provides bounded launch arguments, application
client and interaction values, caller and status helpers, presentation kits
and naming values. These libraries carry values only: they do not admit an
application, select a workspace, open a store, or grant access to a thread.

| Entry | Responsibility |
|---|---|
| `client`, `arguments`, `interaction` | Application launch and broker-facing values used by standalone application processes |
| `caller`, `status_reader`, `status_surface` | Typed owner replies and bounded presentation values |
| `names` | Shared naming values for applications and desktop consumers |
| `viz` | The visualization kit on the frame: sparklines, line and area charts, bars, columns, stacked bars, histograms, heatmaps, status grids, gauges, progress, stat tiles, inline table bars, timelines, small graphs, scatter plots, candlestick and range charts, a braille radial gauge, a spinner, 100% stacked bars, progress with ETA and bounded live series with a redraw cadence |
| `forms` | The input kit on the frame: a text field (cursor, word and line motions, select-all, paste, placeholder, `max_length`, masked mode), a bounded number field, a scrolling multi-line text area, a select/dropdown, a checkbox, a radio group and a toggle, plus a form container that owns focus order (Tab/Shift-Tab/click), per-field validation, dirty tracking and a disabled state |
| `diagram` | Layout diagrams on the frame: `mesh` (nodes at chosen or ringed positions, braille-routed edges, node hits), `treemap` (squarified tiles of sized items) and `flame` (icicle chart of a value tree); pure painters with hit targets, in the same node and bar vocabulary as `viz` |
| `folder_picker` | A folder picker over the roots the host admits through the workspace catalog's `roots` and `folders` operations: the pure paging and navigation model and its table on the frame |
| `sessions`, `sessions_protocol` | The typed `sessions` client: `call`, `open`, `send`, `await`, `join`, `cancel`, `close`, `get`, `work`, `history`, `list` and `catalog` over the `bee.sessions` owner contracts, with Session, Work and Operation handles; `sessions_protocol` holds the closed reply types and their decoders |
| `startup_progress` | Pure retained-startup phase decoding and inactivity deadline values shared by launch and desktop clients; callers authenticate progress senders and select and enforce timeout bounds |
| `host_leases` | Leases on node-managed workspace hosts: the holder registers a lease name, asks the node host manager for a workspace's host and releases it; the manager answers only the holder of that name, and the host policy `bee.security.desktop:workspace_host_lease_policy` decides who may name leases |

Shared frame, appearance and bounded text are owned by [bee.ui](../../ui/src/README.md).
Import `bee.ui:frame`, `bee.ui:appearance` and `bee.ui:text` directly.

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

The authenticated Threads facade is opt-in through
[bee/application-threads](../../application-threads/src/README.md). Import
`bee.app.threads:client` directly for its `request` and `result` helpers.
The base package still selects `bee/threads` for its Sessions value decoding,
caller fault bounds and status projection helpers.

## Sessions client

`sessions` (`bee.sessions.client:sessions`) calls the `bee.sessions:contract` and
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
local s = sessions.open{definition = "research:worker", budgets = {turn = {provider_steps = 12, tokens = 20000}},
    supervision = {quiet_period_ms = 45000, on_stall = "report"}, operation_key = "open/worker"}
local w = s:send{input = "Check the baseline", budgets = {turn = {tokens = 5000}}, operation_key = "send/baseline"}
local a = w:await{timeout_ms = 30000}
local closing = s:close{operation_key = "close/worker"}
```

- `call{definition, input, operation_key, output?, profile?, workdir?, budgets?, supervision?, timeout_ms?}` opens a session with its first work in one owner operation and awaits it once. It returns `{work, observation}` on every observation branch. An unsuccessful settlement is a `ready` observation whose `result.outcome` is not `succeeded`.
- `open{definition, profile?, workdir?, budgets?, supervision?, operation_key}` returns a Session. `send{session?, input, output?, budgets?, operation_key}` (or `session:send`) returns a Work whose `receipt` proves intake only. Work is queued; nothing runs inside the call.
- `budgets = {turn?: Budget, session?: Budget}` is opt-in on open. Send accepts `budgets.turn` and tightens the session turn defaults. Session totals are durable; token intake uses descriptor-declared accounting and may overshoot within a provider step. Cost and window limits currently reject as unsupported. Exceeding a budget returns `outcome = "budget_exceeded"` with `BUDGET_EXCEEDED` and placement exit evidence.
- `cancel{work, operation_key}` and `close{session, operation_key}` return an Operation whose `await` reports `stopped`/`already_terminal` or `closed`, or an uncertain evidence branch.
- `await{subject}`, `work:await` and `operation:await` observe one work or operation; `timeout_ms` is at most 60000 and bounds observation, never execution. `session:await(work)` also checks that the work belongs to the session.
- `join{works, operation_key, policy?, quorum?, timeout_ms?}` takes 1 to 64 distinct works, returns one `JoinAwait` with every child's observation in input order, and validates `quorum` against the set.
- `get(session_ref)` and `work(work_ref)` rehydrate a Session or Work from a ref; `work:state()` reads the `WorkState`, which carries `sender`, the owner-set authenticated sender of the work (a SessionRef when the caller is a session, else the principal). Callers never supply a sender. Refs (`bs:`, `bw:`, `bo:`, `bj:` qualified strings) are the only addresses; `:ref()` returns one.
- Handles capture the session incarnation and send it as `expected_incarnation`; a session reset makes them fail with `STALE` rather than act on the new incarnation.
- `list{filter?, cursor?}` filters by `workspace`, `definition`, `lifecycle` and `activity` (`idle`, `working`, `blocked`, `stalled`); session snapshots include quiet-period evidence when stalled. `supervision.quiet_period_ms` on open selects the period, defaulting to 60000. Stalled reports inactivity; `supervision.on_stall="cancel_work"` requests a stop with placement evidence. `catalog{kind?, definition_ref?, query?, sort?, include_unavailable?, cursor?}` returns the owner's candidates.

Requests are validated before dispatch (`INVALID`): bounded text and refs, JSON inputs of at most 64 KiB and depth 16.

### Operation keys

Every mutation requires an explicit `operation_key`. The SDK cannot derive a
durable identity from the current application broker or client, so applications
must persist their own key before dispatch and reuse it after an uncertain
reply. Reusing a key with different arguments is a conflict.

Session snapshots expose `thread_ref`, `workspace`, driver/provider, definition and the latest settled result summary. `session:history{cursor?, limit?}` pages immutable Work inputs and refs in sequence order; rehydrate each Work to observe its current result. `client.navigate(launch, definition_id, arguments?)` queues an admitted app open through the current authenticated broker execution. A receiving app listens on `bee.app.navigate` and passes the message sender and payload to `client.navigation(launch, sender, payload)`; the helper returns bounded arguments only for the current broker execution.

`sessions.open` and `sessions.call` accept optional `presentation = "headless" |
"window"`. Headless is the default. Window opens an interactive session with a
retained native terminal and a detachable viewer when the host grants
presentation to a controlling person. Its snapshot exposes `presentation` so
Sessions navigation selects that terminal. Work still uses `send` and reaches
interactive sessions through their driver hooks at the next turn boundary.
Closing a viewer leaves the session running; `close` or `cancel` stops its
placement with exit evidence.

The SDK root is `bee.app`; a feature UI child such as `bee.files.app` is a
separate namespace with its own app entry. Process topics use `bee.app.*`.
Deploy topic changes together with the SDK, broker and every sender and receiver,
then restart the node owner and its processes from committed state. Selective
live code handoff cannot mix the old and new topic protocols.
Application principals retain `bee.application:<workspace_id>:<instance_id>`:
Threads persists them in immutable records and command receipts, and workspace
binding recovery matches them against stored memberships.
