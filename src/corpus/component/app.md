# bee.app

The public application SDK. An application is a `process.lua` entry with
`meta.type: bee.app`; these libraries carry values only. They do not admit an
application, select a workspace, open a store or grant access to a thread.

| Entry | Responsibility |
|---|---|
| `bee.app:client` | Launch decoding and the application-to-broker messages: ready, title, close, query, checkpoint, navigate |
| `bee.app:arguments` | Bounded launch argument decoding and fingerprint |
| `bee.app:interaction` | Interaction (confirm and input query) specs and responses |
| `bee.app:caller` | Typed owner replies decoded through the shared `bee.values:reply` boundary |
| `bee.app:names` | Bounded display labels for names |
| `bee.app:descriptor` | Decodes the `meta.application` record of a `bee.app` entry |

Frames, appearance, text and presentation kits belong to `bee.ui`: import
`bee.ui:frame`, `bee.ui:appearance`, `bee.ui:text`, `bee.ui.forms:forms`,
`bee.ui.viz:viz`, `bee.ui.diagram:diagram` and `bee.ui.picker:folder` directly.

Reference screens for each application class are served under the
`reference_apps` topic. They use only this public API and are not registered
entries.

Applications run as standalone processes. The host admits their exact
definition and policies; the broker supplies execution identity and durable
thread bindings. Registry metadata and SDK imports do not authorize an
application or a thread operation.

## Declaration

`bee.app:descriptor` decodes the `meta.application` record of a `bee.app` entry.
`api_version` is 1 and `lifetime` is `view`. Required: `title` (up to 80
characters) and `revision` (up to 80). `instance_policy` is `singleton` or
`multiple`. Optional: `icon` (up to 8), `group`, `role`, `menus` (up to 16
`bee.menu` entry ids, for example `bee.shell:apps_menu`), `terminal` (boolean),
`restart_policy` (`never`, `automatic` or `manual`) and `resume_schema` (up to
80 characters; required when the restart policy is not `never`). An invalid
record is not a valid declaration and the app is not listed. Advance `revision`
whenever the source or configuration changes.

## Client

`client.launch(value)` decodes the launch message the broker delivers and
returns a launch value (`broker_pid`, `instance_id`, `view_id`,
`definition_id`, `execution_generation`, `launch_token`, `resume_schema`,
`resume_state`, `arguments`, `appearance`), or nil when invalid. Messages to the
broker carry the launch token; send success means queued.

| Call | Broker topic |
|---|---|
| `client.ready(launch, {negotiate_close?})` | `bee.app.ready` |
| `client.title(launch, title)` | `bee.app.title` (80 bytes, no control characters) |
| `client.close_request(launch, sender, value)` / `client.close_reply(launch, request_id, decision)` | `bee.app.close.reply`; decision action is `accept`, `cancel` or `confirm` |
| `client.query(launch, {kind, title, message?, accept?, initial?})` | `bee.app.query`; listen for `bee.app.query.result` first, then decode with `client.query_result` |
| `client.checkpoint(launch, state)` | `bee.app.checkpoint`; needs a `resume_schema`, state up to 65536 bytes |
| `client.navigate(launch, definition_id, arguments?)` | `bee.app.request` with `op = "open"` |

A receiving app listens on `bee.app.navigate` and passes the sender and payload
to `client.navigation(launch, sender, payload)`, which returns bounded arguments
only for the current broker execution. Authenticate every inbound message by
comparing its sender with `launch.broker_pid`.

`client.reference(launch)` returns the logical view reference
(`workspace_id`, `instance_id`, `view_id`), which carries no PID or token.

## Threads

The authenticated thread facade is the optional `bee.app.threads:client`
library, documented in `component/app:threads`. Owner clients live with their
components, for example `bee.threads.sessions.client:sessions` for managed
work; they grant no authority.

## Principals

Application principals have the form `bee.application:<workspace_id>:<instance_id>`;
Threads persists them in records and command receipts.
