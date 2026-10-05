# bee.app

The public application SDK. It provides bounded launch arguments, application
client and interaction values, caller helpers and naming values. These libraries
carry values only: they do not admit an
application, select a workspace, open a store, or grant access to a thread.

| Entry | Responsibility |
|---|---|
| `client`, `arguments`, `interaction` | Application launch and broker-facing values used by standalone application processes |
| `caller` | Typed owner replies decoded through the shared `bee.values:reply` boundary |
| `names` | Shared naming values for applications and desktop consumers |
| `bee.app.status:startup_progress` | Pure retained-startup phase decoding shared by launch and desktop clients; callers authenticate progress senders and follow owner readiness and failure events |

Shared frame, appearance, bounded text and presentation kits are owned by
[bee.ui](../../ui/src/README.md). Import `bee.ui:frame`, `bee.ui:appearance`,
`bee.ui:text`, `bee.ui.forms:forms`, `bee.ui.viz:viz`, `bee.ui.diagram:diagram`
and `bee.ui.picker:folder` directly.

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
Status readers and presentation decoders also live in that optional package.
The base package selects only `bee/values` and `bee/ui`.

Owner clients live with their components: import `bee.sessions.client:sessions`
for managed work and `bee.workspace.client:host_leases` for node-managed host
leases. Their contracts are documented in [Sessions](../../sessions/src/README.md)
and [Workspace](../../workspace/src/README.md). Owner clients grant no authority.

`client.navigate(launch, definition_id, arguments?)` queues an admitted app open
through the current authenticated broker execution. A receiving app listens on
`bee.app.navigate` and passes the sender and payload to
`client.navigation(launch, sender, payload)`, which returns bounded arguments
only for the current broker execution.

The SDK root is `bee.app`; a feature UI child such as `bee.files.app` is a
separate namespace with its own app entry. Process topics use `bee.app.*`.
Deploy topic changes together with the SDK, broker and every sender and receiver,
then restart the node owner and its processes from committed state. Selective
live code handoff cannot mix the old and new topic protocols.
Application principals retain `bee.application:<workspace_id>:<instance_id>`:
Threads persists them in immutable records and command receipts, and workspace
binding recovery matches them against stored memberships.
