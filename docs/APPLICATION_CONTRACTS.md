# Application contracts (development version 1)

## Vocabulary

A **definition** is a registry process entry, identified by its registry ID and
application revision. An **instance** is one logical launch. An **execution PID**
is one running process. A **view** is an instance's visual surface. A **mount** is
a revocable, recipient-bound capability to observe, send input or resize a view.
A **workspace** owns a desktop lifetime; a **presenter** is its replaceable UI.
A **service** is not a view-owned instance; that lifetime is reserved for a later
subsystem. Do not use PID, definition ID and instance ID interchangeably.

Current limits: 64 admitted definitions, 16 view-owned instances, 8 policy bindings
per definition, 16 stop waiters per instance, 128 completed owner request IDs.
Deduplication is bounded and in-memory, not durable exactly-once execution.

## Definition and admission

`meta.type = bee.application` and `meta.application` declare `api_version: 1`,
`lifetime: view`, nonempty `revision` and `title`, `instance_policy: singleton|multiple`,
optional `icon`, `group` (slash-separated menu path), and `role`. Roles supply
contextual discoverability, never authority. Only protected
`bee:application_admission.bindings` selects allowed definitions, policy IDs and
operation grants (`appearance_write`, `application_stop`).

The admitted icon is copied into the window's presentation state. Settings can
select compact icon tabs; the taskbar clips icons to two terminal cells and falls
back to a short title when no icon is declared. Icons never identify or authorize
an application: actions still target the stable view ID.

The user can set a separate per-window label and named accent through the
presenter's context menu. The session commits these values, and supported
checkpoint recovery preserves them. Applications cannot submit that private
desktop command themselves.

`bee.application:client.title(launch, title)` queues an application title update.
Titles are limited to 80 bytes without controls; an empty string restores the
admitted definition title. Success means queued, not committed or persisted.
The broker authenticates the sender PID, instance/view IDs and launch token,
coalesces updates on its 100ms tick and routes them through the session. User
labels take precedence and clearing a label reveals the latest app title.
Updates survive presenter replacement; apps must announce again after cold
restart. Native PTY OSC title forwarding is not implemented.

`src/apps/` is the default package composition, currently shipped in the same
pack as core. Physical directories do not change registry IDs. Separate Hub
package releases will follow contract stabilization.

## Launch and lifecycle

The broker supplies one launch value with `version`, `broker_pid`, `workspace_pid`,
`instance_id`, `view_id`, `definition_id`, `definition_revision`, `registry_revision`
and `launch_token`. `bee.application:client` validates it. The revision identifies
the registry state observed for launch; it is not a promise that a mutable loader
pins every future import. Transactional activation is a future installer concern.

Open requests may carry `arguments`, a dense list of up to 16 strings (1 KiB each,
8 KiB combined, no control characters). Omission means an empty list. The broker
copies validated arguments into the launch value, and `client.launch` validates
and copies them again. Applications own semantic decoding: argument text never
grants access to a thread, filesystem or executor. Arguments participate in the
broker's bounded request deduplication identity. They are not accepted on close,
bind or shutdown operations.

This is a launch-only boundary: focusing an existing singleton does not deliver
new arguments or restart it. Arguments are not automatically persisted; an app
must checkpoint the domain identifiers it needs for recovery. Start opens with an
empty list. `./run.sh --app definition-id [arguments...]` uses the native `bee-app`
command to launch an application with explicit arguments. Nonempty explicit
arguments take precedence over a saved checkpoint for that initial launch.
Test Status accepts a thread ID and optional run ID; its checkpoint saves only
the thread, so restoration never requests a new run automatically.

After initializing its input/output, the app calls `client.ready(launch)`.
The broker checks the actual sender PID, instance/view identities and launch token.
UI apps signal after their initial frame; Terminal signals after PTY attachment.
The native program can still fail after attachment; EXIT remains authoritative.

Broker owner requests use `bee.app.request`: `version: 1`, nonempty `request_id`,
`op: open|close|bind|shutdown`, with the operation's definition/view/recipient.
Replies use `bee.app.reply`, version 1, correlated request ID, operation, view ID
(`id`), instance ID, title, mount, and explicit `error_code`/`error` strings.
Unsolicited `closed` is emitted on EXIT. Duplicate successful opens focus the
existing live instance; they never replay obsolete mount handles.

This protocol currently couples one app process to one view. Normal close means
stop that view-owned instance. Future multi-view apps and background services need
separate close-view and stop-instance operations rather than silently changing it.

## App operations

Appearance uses `bee.appearance.request` (`state|set`) and
`bee.appearance.state`, with version 1 and a request ID. All apps can read; writes
require the protected grant. The session commits preferences and its projection
revision. Broker-originated updates are checked before apps adopt them.

Runtime process control uses `bee.application.control` (`stop|force_stop`,
`execution_pid`) and `bee.application.result`, with version 1, request ID and
explicit errors. The broker checks the caller grant and target ownership. A stop
result is successful only after EXIT. `termination_pending` is not success.

Desktop commands are an internal finite version-1 vocabulary. Only the workspace
can send them to its session. Complete acknowledgements include committed scene,
tabs, preferences and errors. No-op placement still publishes state so the
presenter can settle a drag. Acknowledgements are processed while rejoining too.

## Extension discipline

Route new operations through their owning subsystem, authenticate the sender and
check explicit grants there. Keep registry/overlay writes behind the future
publication owner. Do not expand the base app policy to make an individual app
work. Native execution requires OS-level confinement before admitting untrusted
shell commands or external agents. TTY capability isolation is not filesystem isolation.

## Durable checkpoint and restore

An app opts in with `resume_schema` and `restart_policy: automatic|manual`.
The default is `never`. Schema names are application-owned compatibility contracts,
not inferred from the package version. A changed package may read an old schema,
but Bee will not silently feed data into a different declared schema.

`client.checkpoint(launch, json_string)` queues up to 64 KiB of app-owned JSON and
returns a request ID. It does **not** claim persistence. The app can listen for
`bee.application.checkpoint_result` from its broker, version 1, with that request
ID and `error_code`/`error`. Success means the workspace database transaction
committed. Only one outstanding request per app is retained; replaced requests
receive `superseded`, and waiting requests have a five-second deadline. Apps should
checkpoint during work and avoid depending on a final shutdown exchange.

The workspace preserves acknowledged data, logical instance/view IDs, geometry,
window mode and preferences. On boot, automatic instances are reopened in saved
order after admission is checked. Manual instances resume when opened from Start.
The new launch carries `resume_schema` and `resume_state`; process and terminal
capabilities are newly created. Runtime PID strings may be reused across runtime
boots and must never serve as persistent identities. Failed/incompatible restores
retain their checkpoint rather than deleting it. Closing a live view-owned instance
removes its resume record after EXIT; exiting the workspace retains it.

Settings checkpoints its selected pane and browsing position. A chat driver can
checkpoint a conversation UID. A terminal needs a surviving session service to
rejoin a live PTY; the current native Terminal deliberately declares no cold-resume
contract. Database migration version, registry version, application revision and
resume schema are separate version domains.

Stored JSON is opaque application data, not serialized authority. It must not
contain reusable grants, credentials or runtime objects. The database is a local
workspace file, not an encrypted secret store. Future overlay/Hub activation must
validate migration compatibility before activation and keep a tested recovery path;
these install/activation transactions are not implemented by this store.

## Shell queries and close negotiation

Shell questions are implemented through `bee.application:client.query(launch,
options)`. Options contain `kind: "confirm" | "text"`, `title`, and optional
`message`, `accept` and `initial` strings. Limits are 80 bytes for the title,
512 for the message, 24 for the accept label and 256 for input, without controls.
The return is a request ID or an error; successful send means queued.

Register `process.listen("bee.application.query.result", {message = true})` before
sending. Decode received messages with `client.query_result(launch,
tostring(message:from()), message:payload():data())`, then match the returned
request ID. This validates the broker sender and app identity. Results contain
`action: "accept" | "cancel"`, `value`, and `error` (empty or `busy`). A second
pending question for the same view returns busy. Questions requested during
startup remain pending until the view appears.

The broker owns pending questions and generates fresh presentation IDs, distinct
from app request IDs. Replies from stale presenters or unrelated actors do not
resolve them. F12 preserves the question, but resets transient text edits and
button focus. App exit removes its question. Questions are not persisted across
cold starts. Confirmations default to Cancel; text queries start in the field.
Escape cancels. Tab, arrows, Enter and mouse operate controls; app input is
isolated. Existing tabs and Alt+Tab switch applications without cancelling a
question. Queries are plain text, not secret/password fields.

Apps can opt into negotiated close with `client.ready(launch,
{negotiate_close = true})`. Register `bee.application.close` before readiness,
then decode requests with `client.close_request(launch, sender, payload)` and
reply with `client.close_reply(launch, request.request_id, decision)`. A decision
has `action: "accept" | "cancel" | "confirm"`; confirmation also accepts bounded
`title`, `message` and `accept` strings. Close policy is fixed by the first valid
readiness acknowledgement. Apps without opt-in retain the fast close path.

The broker waits two seconds for the app's answer without starting termination.
A confirmation then waits for the user without a kill deadline. Silence produces
an explicit Force stop/Cancel dialog. Cancellation reports `cancelled` to close
callers and sends `bee.application.close.result` to the app with its original
request ID and `action: "cancel"`. Apps that pause work during negotiation must
resume on this authenticated result, decoded with
`client.close_result(launch, sender, payload)` and matched to their pending request. Acceptance begins the existing 250ms
cooperative cleanup, followed by termination if necessary. Repeated close clicks
share one negotiation; stale IDs and forged senders/tokens cannot accept it.
A pending ordinary query is cancelled when close negotiation begins. New queries
during negotiation receive `busy`; title announcements remain accepted.

Source/pack acceptance uses an opted-in native Terminal fixture and verifies a
live PTY through cancellation, input recovery, F12, invalid-token rejection and
explicit close. An unresponsive fixture verifies that timeout does not kill work.
The bundled Terminal opts in and always asks before closing its PTY. It cannot
reliably distinguish an idle prompt from a valuable foreground job. Typing `exit`
inside the native shell remains a direct application exit. For opted-in apps, normal desktop quit
now gathers decisions into one confirmation. No app closes while another decision
is pending; cancellation keeps them alive. Acceptance starts parallel cooperative cleanup while the workspace continues
servicing checkpoint writes. Recovery records survive workspace shutdown; an
individual app close still removes its record. Completion waits for observed app
exits and known persistence requests, with a bounded failure path that reports
unacknowledged cleanup. Only a successful checkpoint receipt guarantees a committed
save. Apps requiring a save before consent must await that receipt before accepting;
a queued send is insufficient, and final cleanup has only a 250ms grace period. Launching new apps is rejected
while quit is pending. Apps that accept without a question do not add a prompt.

The failed-presenter recovery screen retains Ctrl+Q as an emergency exit that
bypasses negotiation. Physical terminal loss, process cancellation and fatal core
failure can likewise end the workspace without a usable confirmation UI. These
are not graceful-close guarantees.

Ownership stays narrow: applications define questions; the broker owns pending
requests and close decisions; the workspace forwards only authenticated presenter
responses; the presenter owns drawing and input focus. Pure `interactions`,
`lifecycle` and `shutdown` modules manage values without process or storage access.
A positive dialog response is not a general capability grant.

Closing a view still stops its app process. Test Status's independent worker
continues when its view closes, so that app does not opt into a cancellation
warning. Minimize and F12 never request close. Future independent application
lifetimes and headless clients must distinguish detach from stop explicitly.
