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
| `frame` | The application frame every Bee application draws with: size classes and layout, header, tabs, action bar, status and key-hint footer, list window, table (full width, or confined to a list pane's `area`), panels, form fields, wizard steps and empty state |
| `viz` | The visualization kit on the frame: sparklines, line and area charts, bars, columns, stacked bars, histograms, heatmaps, status grids, gauges, progress, stat tiles, inline table bars, timelines, small graphs and bounded live series with a redraw cadence |
| `thread_protocol` | Exact bounded requests and replies for the authenticated application-to-broker thread facade |
| `folder_picker` | A folder picker over the roots the host admits through the workspace catalog's `roots` and `folders` operations: the pure paging and navigation model and its table on the frame |
| `agent_protocol` | The typed request that starts a managed agent, shared by `agents`, the gateway's `thread_launch` and the harness that admits it |
| `agents` | Managed agents for applications and agents: `launch` or `run` one on an existing or a new thread with a chosen working directory and placement, read its `status`, `wait` for it through its thread and `cancel` it, all as the caller's own actor through `bee.harness.launch:agent_call`; `run` returns a durable receipt promptly; `cancel` supports idempotent cancel intents and terminal carrier wait; the host grants `bee.harness.launch` on each definition a caller may start |
| `host_leases` | Leases on node-managed workspace hosts: the holder registers a lease name, asks the node host manager for a workspace's host and releases it; the manager answers only the holder of that name, and the host policy `bee.security.desktop:workspace_host_lease_policy` decides who may name leases |

Applications still run as standalone processes. The host admits their exact
definition and policies; the broker supplies execution identity and durable
thread bindings. Registry metadata and SDK imports do not authorize an
application or a thread operation.
