# Application contracts (development version 1)

## Vocabulary

A **definition** is a registry process entry, identified by its registry ID and
application revision. An **instance** is one logical launch. An **execution PID**
is one running process. A **view** is an instance's visual surface. A **mount** is
a revocable, recipient-bound capability to observe, send input or resize a view.
A **workspace** owns a desktop lifetime; a **presenter** is its replaceable UI.
A **service** is not a view-owned instance; that lifetime is reserved for a later
subsystem. Do not use PID, definition ID and instance ID interchangeably.

Current limits: 64 admitted definitions, 16 view-owned instances, 16 policy bindings
per definition, 16 stop waiters per instance, 128 completed owner request IDs.
Deduplication is bounded and in-memory, not durable exactly-once execution.

## Definition and admission

`meta.type = bee.application` and `meta.application` declare `api_version: 1`,
`lifetime: view`, nonempty `revision` and `title`, `instance_policy: singleton|multiple`,
optional `icon`, `group` (slash-separated menu path), and `role`. Roles supply
contextual discoverability, never authority. Only protected
`bee:application_admission.bindings` selects allowed definitions, policy IDs and
operation grants (`appearance_write`, `application_stop`, `catalog_read`).
Executable source or configuration changes require a new application revision;
one revision identifies one exact runnable definition.

The broker reconciles the effective protected declaration on its existing
lifecycle tick and before each new open. It compares decoded bindings and
descriptors from one immutable snapshot as well as the history revision:
registry overlays can change these values without advancing history. Unchanged
values reuse the existing scopes and do not republish the catalog. A change
rebuilds the host-selected scopes and rechecks the catalog before publication. A
compatible new revision of an automatic application replaces its execution
behind the same viewport after the old producer exits and its pending checkpoint
settles. The instance, controller and observer mounts, display assignment,
geometry and last acknowledged checkpoint remain continuous. A manual
application or one whose resume schema or restart policy changed keeps its
existing execution. Removing a binding blocks new opens. An invalid declaration
or unavailable policy clears future admission until a valid replacement can be
loaded, without terminating existing instances. Replaying an already completed
open may still focus that existing instance; it does not create a new execution.

Replacement has one owner-local state on the instance. Explicit close and
workspace shutdown cancel it. A later catalog revision cannot overwrite an
already observed producer exit; if the exact target revision is no longer
available, the replacement fails closed. A failed renewal spawn revokes its
unused producer grant. An unexpected exit outside replacement is reported as an
application failure, and the workspace preserves an automatic application's
last acknowledged recovery record and display assignment for the next host
recovery.

This is registry reconciliation only: Hub installation does not publish an
admission binding or grant an application approval. The reviewed publication
owner and Modules approval workflow remain unfinished. `make app-admission-check`
exercises the actual broker against source and pack, including scope replacement,
revocation, invalid-declaration recovery and retained producers. The fixture owns
its registry writes; this is not an installed-package approval acceptance test.

The protected binding also accepts `scope_management: boolean`, defaulting to
`false`. Unknown binding fields and nonboolean values are refused. The broker
uses this decoded host selection when constructing the application scope;
application metadata and launch arguments cannot opt in. Ordinary bindings use
`bee:app_boundary_policy`. Opted-in bindings use
`bee:scope_managing_app_boundary` and still need explicit policies granting the
scope operations they use. The broker contains no application identity check.

Only the reviewed native harness application currently opts in. It owns native
execution with OS-user authority and needs to call driver configuration methods
under an empty scope. Scope management is a trust decision: the application can
construct and replace call scopes, including reconstructing them from policies
it already holds. Remaining deny policies are therefore defaults for this
trusted application, not a confinement guarantee. Driver configuration itself
runs with an explicitly empty scope, which denies store, executor and nested
function-call access. Ordinary applications retain their existing scope denial.

Focused acceptance proves default/false/true decoding and malformed-field
refusal. Real Claude/Codex window startup, input, resize, rebind and cancellation
pass with the host selection enabled; disabling only that selection restores
the runtime's scope-creation denial. This does not prove authenticated provider
turns or production process-tree cleanup.

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
`workspace_id`, `instance_id`, `view_id`, `definition_id`, `definition_revision`,
`registry_revision`
and `launch_token`. `bee.application:client` validates it. The revision identifies
the registry state observed for launch; it is not a promise that a mutable loader
pins every future import. Transactional activation is a future installer concern.

`workspace_id` is the required opaque ID from the owning workspace database.
The workspace installs it in the broker's trusted bootstrap context; applications
cannot select it through launch arguments. `client.reference(launch)` returns a
copied `{workspace_id, instance_id, view_id}` logical reference. It contains no
execution PID, mount, token or permission. Reopening an application in the same
workspace retains the workspace ID even when execution changes.

Broker replies carry `workspace_id`; the workspace and presenter require it
to match their trusted bootstrap identity before acting on a reply. The workspace
also checks it on checkpoint delivery. New session windows retain that ID through
geometry changes, snapshots and persistence. Legacy local saved windows without
the field remain readable and receive the current owner's identity on reopen.
Identity still does not replace sender authentication or capability checks.

Private desktop application requests also carry `workspace_id`. The workspace
and broker both require their own identity before open, close, bind or shutdown
can reach execution. Missing or foreign targets receive `workspace_mismatch`;
they cannot silently fall back to the local workspace. The shell clears pending
close state on that error and allows explicit retry. These checks qualify local
routing; they do not implement remote dispatch or multi-workspace clients.

The stored recovery record remains local to its owning database. This reference
helper does not add remote routing or turn local open/close APIs into
cross-workspace operations. Sender, instance and capability checks remain the
authority boundary. Restart the whole workspace after updating this launch
contract; F12 only replaces the presenter.

Open requests may carry an optional bounded `thread_id` association. The value uses
the thread record identifier bound (nonempty, printable, at most 160 bytes). It is
an owner-selected descriptive association and grants no thread membership or
operation permission. It is carried by the host-authorized open request and the
broker's immutable instance; applications cannot set or infer it from launch
arguments. Identified replies and host inventory expose the association, and
checkpoint records retain it for recovery. An open without `thread_id` may restore
the association saved with its selected checkpoint.

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
empty list. `bee run definition-id [arguments...]` passes the application
identifier through the executable's default `bee` command and launches it with explicit arguments. Nonempty explicit
arguments take precedence over a saved checkpoint for that initial launch.

### Registered CLI handlers

`bee claude`, `bee codex`, `bee agy` and `bee grok` resolve the component-owned
managed launch definition and open the Agent window fullscreen. They use the
same measured plan, setup, admission, carrier, thread, hook and MCP path as a
selection from the Agent picker. The executable must already be available under
the host-selected launch policy. The standalone binary preserves the caller's
working directory. Native options such as `--state` precede the alias.
Managed aliases accept no trailing raw arguments because those arguments could
bypass reviewed profile options; arbitrary harness commands remain available
inside Native Terminal with its OS-user authority.
If an existing native state directory still selects an older installed pack,
use `bee recover codex` to run the rebuilt embedded application with fresh
registry history. This preserves workspace databases and does not upgrade the
installed Hub selection.

Admitted application metadata can declare `application.commands`, a dense list
of up to 16 `{name, arguments?, fullscreen?}` records. Names are lowercase ASCII
identifiers, at most 40 characters, with digits, underscores and hyphens after
the first letter. `run`, `update`, `recover` and `wippy` are reserved by the native host.
Duplicate matches fail rather than choosing an arbitrary application. Discovery
considers only host-admitted applications; metadata grants no execution authority.
Prefix arguments and caller arguments share the existing bounded argument decoder.
Fullscreen is an idempotent initial presentation request after successful open.

Terminal declares only the `terminal` handler. Its named executor can run
explicit native argument vectors with OS-user authority; empty
arguments start `/bin/bash -i`. Quoting preserves empty strings, whitespace and
shell metacharacters without shell evaluation. Other applications gain no native
execution permissions from declaring a handler.
An application that takes launch arguments validates them before opening
anything and treats them as selection, never as a command to act: Timeline
accepts an optional thread ID and its checkpoint saves the thread, its
subscription identity and the local view state, so restoration reattaches
to what the owner holds and never creates work automatically.

A read-only viewer of an owner (the Timeline over a thread) never mutates the
owner's state: it lists and reads, holds its own subscription cursor, and
waits for change through a read-only operation that claims no obligation
(`bee.threads.delivery:watch`, distinct from `wait`, which claims). Viewing a
thread with pending obligations for the viewer leaves those obligations and
the delivery history unchanged. Page acknowledgment moves the owner's cursor
for that subscription; it records consumer progress, not proof the viewer saw
the page. A viewer that folds a page into memory and acknowledges it, then
loses its process before persisting those rows, resumes past the acknowledged
cursor and shows the unsaved rows as a bounded gap, never as seen. A viewer
closes only its own subscriptions and only when it leaves a thread; a
presenter reload keeps the subscription so it resumes, and a durable
subscription an app abandons is bounded by the owner, not the viewer.

After initializing its input/output, the app calls `client.ready(launch)`.
The broker checks the actual sender PID, instance/view identities and launch token.
UI apps signal after their initial frame; Terminal signals after PTY attachment.
The native program can still fail after attachment; EXIT remains authoritative.

Producer readiness is independent of a desktop consumer. The broker accepts an
admitted open without a bound presenter, acknowledges readiness and checkpoints,
and retains its viewport for later attachment. An `open` success may carry an
empty mount. If mounting to a bound recipient fails, readiness still succeeds;
a separate `attached` error reports `attachment_failed` without terminating the
app. A later bind can attach to the same producer. The local workspace launcher
still requires a physical desktop; this broker capability is not a headless profile.

Broker owner requests use `bee.app.request`: `version: 1`, nonempty `request_id`,
`op: open|close|bind|unbind|shutdown`, with the operation's definition/view/recipient.
For `bind`, supplying both `id` and `instance_id` targets that exact live view
within `workspace_id`. A mismatched instance returns `not_found` without revoking
any grant. An empty recipient detaches only that view; other controllers and the
default recipient for future opens remain unchanged. Omitting both identifiers
retains the local desktop's whole-broker bind. Supplying only one is malformed.
Both forms remain restricted to the trusted broker owner, not arbitrary clients.
`unbind` requires a nonempty recipient PID and no view/instance target. It clears
that recipient as the default for future opens, then revokes its current controller
grants. Other recipients and the application processes remain intact. Revocation
is per grant: an error retains the failed grant's owner record and is returned to
the caller; it does not claim the whole recipient detached. A retry uses a new
request ID. This is a trusted owner operation, not client admission by itself.
Replies use `bee.app.reply`, version 1, correlated request ID, operation, view ID
(`id`), instance ID, title, mount, optional `thread_id`, and explicit `error_code`/
`error` strings. Host live inventory carries the same optional association. A
singleton open that explicitly names an association different from the live
instance returns `thread_conflict`; it never rebinds the instance. Checkpoint
selection follows an explicit requested association, while an unbound open may
restore the association saved with its checkpoint.
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

The broker resolves viewport default colors from the theme and presentation role
at creation and on appearance changes. Windows Classic uses a black console with
light text for the `terminal` role while ordinary application panels remain
silver. Explicit program colors remain intact. The role selects presentation,
not additional permissions.

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
work. An application reaches a subsystem's store only inside that subsystem's
methods, which attach their own store policy; `bee:workspace_storage_boundary`
denies the stores no method may open on an application's behalf, so a store
reached through an owner's methods (threads, approvals) is not listed there.
Every local desktop application acts as the client's actor (`bee.local`);
admission grants an application calls, not an identity of its own. Native execution requires OS-level confinement before admitting untrusted
shell commands or external agents. TTY capability isolation is not filesystem isolation.

## Durable checkpoint and restore

An app opts in with `resume_schema` and `restart_policy: automatic|manual`.
Automatic restart keeps a saved app pending while its definition is absent from
the admitted catalog, including during durable overlay recovery. Catalog changes
resume eligible saved apps through the same serialized restore queue. Missing
apps do not block desktop readiness, and no unavailable definition is launched.
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
The broker keeps a pending candidate separately from the last acknowledged
resume state. Only a correlated successful owner reply changes the state in
live application descriptions; refusal, timeout and supersession preserve the
previous acknowledged value. A timeout leaves the write outcome unknown.

The workspace preserves acknowledged data, logical instance/view IDs, their optional
thread associations, geometry, window mode and preferences. On boot, automatic
instances are reopened in saved order after admission is checked. Manual instances
resume when opened from Start. An explicit thread selection only considers a
checkpoint with the same association; an unbound open can recover the saved one.
The new launch carries `resume_schema` and `resume_state`; process and terminal
capabilities are newly created. Runtime PID strings may be reused across runtime
boots and must never serve as persistent identities. Failed/incompatible restores
retain their checkpoint rather than deleting it. Closing a live view-owned instance
removes its resume record after EXIT; exiting the workspace retains it.

Settings checkpoints its selected pane and browsing position. Its About pane
reports the version and source/runtime/native pins embedded in the loaded Bee
bundle; editable source displays an explicit development-unknown fallback. A chat driver can
checkpoint a conversation UID. A terminal needs a surviving session service to
rejoin a live PTY; the current native Terminal deliberately declares no cold-resume
contract. Database migration version, registry version, application revision and
resume schema are separate version domains.

The native Agent window has not yet connected provider session observations to
this recovery protocol. Its proposed integration reuses retained session files
and acknowledged checkpoints; see [native Agent recovery](handoffs/NATIVE_AGENT_RECOVERY.md).

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
`client.close_result(launch, sender, payload)` and matched to their pending request.
Acceptance begins cooperative cleanup, followed by termination if necessary.
The protected host admission binding selects `close_grace_ms`, an integer from
0 to 60000, defaulting to 250. The native Agent window has a 60000ms allowance
for pending hook delivery and its receipt. Application metadata and close replies
cannot extend that allowance; explicit force stop bypasses it. Repeated close clicks
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
a queued send is insufficient. The per-app allowance does not extend the overall
workspace shutdown deadline: the broker still reports incomplete cleanup after
3.5 seconds. Agent conversation recovery across node shutdown remains a separate
acceptance gate. Launching new apps is rejected
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

Closing a view still stops its app process. Work that must outlive a view runs
in its own supervised process or under an owner service (the approval outbox
worker, the placement runner, a carrier), and such an app does not opt into a
cancellation warning because closing it stops nothing durable. Minimize and F12
never request close. Future independent application lifetimes and headless
clients must distinguish detach from stop explicitly.
