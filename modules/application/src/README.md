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
| `agent_protocol` | The typed request that starts a managed agent, shared by `agents`, the gateway's `thread_launch` and the harness that admits it |
| `agents` | Managed agents for applications and agents: `launch` or `run` one on an existing or a new thread with a chosen working directory and placement, read its `status`, `wait` for it through its thread and `cancel` it, all as the caller's own actor through `bee.harness.launch:agent_call`; `run` returns a durable receipt promptly; `cancel` supports idempotent cancel intents and terminal carrier wait; the host grants `bee.harness.launch` on each definition a caller may start |
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
