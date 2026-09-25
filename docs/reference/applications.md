# Application contracts

This is the version 1 contract for view-owned applications. A **definition**
is an admitted registry process entry, identified by its stable definition ID
and exact application revision. An **instance** is one logical launch; an
**execution** is one running process; a **view** is its visual surface. A
**mount** is a recipient-bound capability to observe, send input or resize a
view. A workspace owns application state and a presenter is a replaceable
desktop surface. A process ID, definition ID and instance ID are different
identities.

The broker bounds one workspace at 64 admitted definitions, 16 view-owned
instances, 16 policy bindings per definition, 16 stop waiters per instance and
128 completed owner request IDs. Request deduplication is bounded and in
memory; it is not durable exactly-once execution.

## Admission

An application definition uses `meta.type = bee.application` and
`meta.application` with `api_version: 1`, `lifetime: view`, a nonempty
`revision` and `title`, and `instance_policy: singleton|multiple`. It may
declare an icon, slash-separated menu group, role and bounded
`application.commands`. Roles and metadata affect discovery and presentation;
they never grant authority. Executable or configuration changes require a new
revision, and one revision identifies one exact runnable definition.

The protected `bee.security:application_admission.bindings` selection supplies shipped
definitions, policy IDs and grants such as `appearance_write` and
`application_stop`. A reviewed governed overlay may add a
workspace-local definition through the host's
`bee:governance_activation_profiles.applications` selection. Activation freezes
the selected artifact, owner, bindings and external policy definitions in its
immutable intent and creates one reserved admission record beside the artifact.
Portable content cannot claim that identity. Static and governed claims cannot
name the same definition, and their combined count remains bounded.

Governed bindings default static-only operation grants to false. Either binding
may select `thread_access: none|observe_post`; omission means `none`.
`observe_post` gives the exact admitted revision a broker-bound facade for
reading, subscribing and posting on its initiating agent's bound thread. It
does not provide raw Threads policies, arbitrary thread selection or thread
storage. Application metadata and launch arguments cannot select it.

An agent-authored app may declare a measured capability request through an
`ns.requirement` whose metadata names a catalog capability, parameters, reason
and `security.policy` value kind. It must append to the app entry's
`.security.policies +=` target. The destination resolver validates the request
against the protected host catalog and retains it in the immutable preflight
candidate. A request does not select a grant or alter the broker's admission
binding. App content that supplies `security.actor` or `security.groups` is
refused by preflight on every entry kind.

The catalog's policy and resource expansions, semantic grant comparison and
host-authored human wording are pure values for future install review. Installing
those grants, reusing an approval on a contained upgrade, and enforcing them at
service boundaries remain proposals; the current application authority below
is still selected by the host's existing admission binding.

The broker accepts a governed record only for its own workspace while the
current normalized host profile selects the same source, owner, bindings and
policies. Hub installation alone does not publish an admission binding or
grant application authority. Removing a binding blocks new opens and recovery;
existing processes continue until their normal lifecycle. Withdrawing a
governed profile also makes its retained record ineffective immediately and
causes the next governed thread operation to follow the revocation path.

The broker compares decoded descriptors, bindings, accepted governed-admission
digests and registry revision from one immutable snapshot. An unchanged
selection reuses scopes. A changed selection rebuilds host scopes and checks
the catalog before publication. Invalid declarations or unavailable policies
clear future admission without terminating existing instances.

The optional protected `scope_management` binding field defaults to `false`;
unknown fields and nonboolean values are rejected. Ordinary applications use
`bee.security:app_boundary_policy`. The reviewed native harness application may use
`bee.security:scope_managing_app_boundary` to construct call scopes from policies it
already holds. That is a host trust decision, not application metadata, and is
not a confinement guarantee. Driver configuration still runs with an empty
scope, denying store, executor and nested function calls. Native execution
has the operating system user's authority.

## Threads and application authority

Applications receive a host-created actor whose stable ID derives from the
trusted workspace and logical instance. Its metadata includes workspace,
definition, revision and execution generation. A compatible replacement keeps
the actor ID and advances the generation. Metadata, roles and launch
arguments never authorize calls.

For `observe_post`, the broker binds the application to the initiating thread
and requires both the exact admitted revision's selection and a live
`bee.application:runtime` grant. The authenticated facade exposes `read`,
`post`, `subscribe`, `page`, `ack_page`, `resume` and `unsubscribe`. Each
request carries the logical instance, launch token and execution generation;
the caller cannot choose a thread, actor, workspace, membership or grant. The
broker rechecks the durable binding and exact Threads membership revision on
every operation and supplies the stable application actor.

Closing first commits a durable revoke fence and disables the facade, then
removes the execution while membership cleanup may continue. Recovery treats
unavailable membership as unknown and never adopts or removes another revision.
If membership is removed or access changes to `none`, the next facade request
returns `DENIED`, revokes and cleans the binding, and restart does not restore
or advertise the instance. During compatible replacement, a request received
while the old producer is retiring returns `UNCERTAIN`; it is never run against
stale definition bytes. The old launch token and generation cannot authenticate
after replacement.

Timeline is a read-only owner viewer. It lists and reads through its own
subscription cursor and uses `bee.threads.delivery:watch` for wakeups;
`wait` claims an obligation and is not a viewing operation. Page acknowledgment
records consumer progress, not proof that rows were seen. If the app loses
unsaved rows after acknowledging a page, it resumes past that cursor and shows
the gap as bounded unsaved data rather than marking it seen. It closes only its
own subscriptions; presenter reload keeps them so they can resume. Viewing
does not mutate thread obligations or delivery history.

## Starting managed agents

An application starts a managed agent with `bee.application:agents`, which
calls `bee.harness.launch:agent_call` as the application's own actor. The host
decides what it may start: it attaches `bee.security.harness:agent_call_policy` (the call) and a
policy granting `bee.harness.launch` on each launch definition the application
may start to its admission binding. The request is
`bee.application:agent_protocol`'s launch: `definition_ref`, `brief`,
`idempotency_key` and optional `workspace_id`, `saved_profile_id` with
`saved_profile_revision`, `thread`, `workdir` and `placement`. `thread`,
`workdir` and `placement` take effect only where the definition and its launch
policy allow the override. A window definition is refused with
`LAUNCH_MODE_UNSUPPORTED`; launch a batch or session definition.

```lua
local agents = require("agents")   -- imports: agents: bee.application:agents

local run, fault = agents.launch({
    definition_ref = "bee.driver.codex:research_batch",
    brief = "Summarize the build scripts in this folder.",
    idempotency_key = "summarize-build-1",
    workdir = {root_ref = "bee.environment:workspace_root", path = "legacy/app"},
    thread = {thread_id = launch.thread_id},
})
if not run then return fault.code .. ": " .. fault.message end
local status = agents.wait(run, 300000)       -- blocks in slices of at most 60 s
if status and status.state ~= "ended" then
    agents.cancel(run)                          -- NOT_STARTED until the child runs
end
```

`launch` returns `{thread_id, action_id, attempt_id, definition_ref, title,
brief}`; the same `idempotency_key` replays the same run. `status`, `wait` and
`cancel` each return `status, fault`; on failure status is nil and fault is
`{code, message}`. The status shape is `{thread_id, attempt_id, state,
outcome?, answer?}` with `state` equal to `starting`, `running`, `cancelling`
or `ended`. These calls read the child's thread and need the application to
belong to it, as its creator or a member. `wait` watches the thread and
returns at the deadline with the last status. `status`, `wait` and `cancel`
need only `run.thread_id` and `run.attempt_id`; keep the whole launch result
for display and later calls. `wait` blocks the calling process in slices of at
most 60 seconds. A UI event loop can call it from a `coroutine.spawn` worker
to keep drawing. `thread = {thread_id = id}` selects an existing thread;
`thread = {title = text}` asks for a new one. `cancel` stops a
running child through the placement that started it, which accepts only the
attempt's owner; the attempt then settles `cancelled`. A run whose child has
not started is refused with `NOT_STARTED`.

Launch definitions are registry entries with `meta.type = bee.launch_definition`;
a definition ID alone does not reveal whether the
host lets this application launch it. The installed driver definitions include
`bee.driver.claude:research_batch`,
`bee.driver.codex:research_batch`, `bee.driver.codex:named_batch`,
`bee.driver.agy:research_batch` and `bee.driver.muse:research_batch`. This is
an inventory of definitions, not an authorization list. An application has no
public API to list the definitions it may launch or saved profile IDs and
revisions. The Agent app manages saved profiles; a caller must obtain an exact
ID and revision from the person, and the host still decides admission.

The application `agents` helper exposes launch, status, wait and cancel. It
does not expose child thread records, intermediate output, a live steering
channel or an app-side equivalent of gateway `thread_message` or
`thread_read`. `client.thread_request` routes operations for an authenticated
initiating thread through the broker when a host grants that thread access;
the shipped workspace-application rule sets `thread_access: none`. A UI may
show its own run statuses and final `status.answer`, but cannot claim a live
child transcript through this API.

## Launch and lifecycle

The broker supplies one validated launch value containing `version`, broker and
workspace process IDs, `workspace_id`, `instance_id`, `view_id`,
`definition_id`, optional `thread_id`, `execution_generation`,
`definition_revision`, `registry_revision` and `launch_token`. The client
library validates and copies it. `client.reference(launch)` returns only the
logical `{workspace_id, instance_id, view_id}` reference; it contains no PID,
mount, token or permission.

`workspace_id` is the opaque ID installed by the owning workspace in trusted
bootstrap state. The broker, workspace and presenter require it to match their
own identity on replies, checkpoints and private open/close/bind/shutdown
requests. A missing or foreign identity returns `workspace_mismatch` and never
falls back to the local workspace. These are local routing checks, not remote
dispatch or multi-workspace clients.

An authorized open may carry a bounded `thread_id` association. It is a
printable descriptive thread record ID of at most 160 bytes; it grants no
membership or operation permission. `bee.application.open` rejects a caller
chosen association, and applications cannot infer one from arguments. The
broker carries the selected association through launch, replies, inventory and
checkpoints. A singleton opened with a different live association returns
`thread_conflict`.

An open may carry up to 16 dense string arguments, each at most 1 KiB and 8 KiB
combined, without control characters. The broker and client validate them.
Arguments participate in open deduplication, are launch-only, are not accepted
on close/bind/shutdown, and are not automatically persisted. Focusing a live
singleton does not deliver new arguments. `bee run definition-id [arguments...]`
uses this boundary; explicit initial arguments take precedence over a selected
checkpoint.

Producer readiness does not depend on a presenter. The broker can acknowledge
an admitted open, retain its viewport and checkpoint state, and attach a later
recipient. A failed initial attachment reports `attachment_failed` without
terminating the application. The local workspace launcher still selects a
physical desktop; this behavior is not a managed headless launch profile.

After initializing its input/output, an app calls `client.ready(launch)`. The
broker authenticates the sender PID, instance/view identities and launch token.
UI apps signal after their initial frame and Terminal after PTY attachment;
later process failure is reported by EXIT. Readiness is independent of a
presenter, but it does not make a native process safe to checkpoint or recover.

Owner requests use `bee.app.request`, version 1, a nonempty request ID and
`open|close|bind|unbind|shutdown`. Requests are accepted only from the trusted
broker owner and include the workspace identity. A bind may target an exact
view and instance; an empty recipient detaches that view. An unbind names a
recipient and removes its default plus current controller grants. Revocation is
per grant and a failed grant remains recorded for retry. Replies use
`bee.app.reply`, correlate the request and include view/instance identity,
title, mount, optional thread association and explicit error fields. EXIT
produces an unsolicited `closed` reply. Duplicate successful opens focus the
existing instance and never replay obsolete mounts.

This boundary currently couples one process to one view. Independent services,
multi-view applications and separate detach-versus-stop lifetimes are
proposals; they require distinct owner operations.

## Built-in handlers and presentation

`bee claude`, `bee codex`, `bee agy`, `bee grok` and `bee muse` select their
reviewed managed launch definitions and use the same admission, carrier,
thread, hook and MCP path as the Agent picker. They preserve the caller's
working directory and accept no trailing raw arguments. `bee recover <name>`
uses the embedded managed definition when the selected installed pack is stale,
while preserving workspace databases and application state. Native Terminal exposes
the `terminal` handler and runs an explicit native argument vector with the
OS user's authority; an empty vector starts `/bin/bash -i`. Declaring a handler
does not grant native execution to another application.

An admitted command declaration contains at most 16 lowercase ASCII command
names, optional bounded prefix arguments and an idempotent fullscreen request.
Host names `run`, `update`, `recover` and `wippy` are reserved. Duplicate
matches fail; discovery includes admitted definitions only. Arguments select
an application and are never interpreted as an instruction to perform a
privileged action.

Apps read appearance through `bee.appearance.request` (`state|set`) and
`bee.appearance.state`, version 1, with a request ID. Writes require the
protected appearance grant. The session commits the preference and projection
revision; broker-originated changes are validated before adoption. The theme
and presentation role choose viewport defaults; a role does not add permission.

`bee.application:client.title(launch, title)` queues a title of at most 80
bytes without controls; an empty title restores the admitted title. Queued
does not mean committed. The broker authenticates PID, instance/view IDs and
launch token, coalesces updates and routes them through the session. A user's
window label takes precedence and survives supported checkpoint recovery. The
admitted icon is copied to presentation state; Settings may use compact icon
tabs and the taskbar clips icons to two cells, falling back to the title. A
user may set a separate window label and named accent; applications cannot
submit those private desktop commands. Native PTY OSC title forwarding is not
implemented.

Process control uses `bee.application.control` (`stop|force_stop`,
`execution_pid`) and `bee.application.result`. The broker checks the caller's
grant and target ownership; a successful stop is reported only after EXIT.
`termination_pending` is not success. Desktop command messages are private to
the owning workspace and acknowledge committed scene, tabs, preferences and
errors.

## Checkpoint and restore

An application opts in with `resume_schema` and
`restart_policy: automatic|manual`; the default is `never`. Schema names are
application-owned compatibility contracts and are independent of package,
registry, database and migration versions. Automatic instances remain pending
while their definition is absent and resume only after admission; unavailable
definitions do not block desktop readiness. A changed or incompatible schema
keeps the saved record rather than feeding it to a different definition.

`client.checkpoint(launch, json_string)` queues at most 64 KiB of opaque,
application-owned JSON and returns a request ID. A successful
`bee.application.checkpoint_result` means the workspace transaction committed;
one pending request is retained per app, superseded requests report
`superseded`, and a five-second wait may end with an unknown result. Only an
acknowledged receipt changes the saved resume state.

The workspace preserves acknowledged state, logical instance/view IDs, optional
thread association, geometry, mode and preferences. On boot it reopens
automatic instances in saved order after admission checks; manual instances
resume from Start. Process and terminal capabilities are recreated. Failed
restores retain their checkpoint. Closing a live view-owned instance removes
its resume record after EXIT; workspace shutdown retains it. An application
that returns normally has closed its view. An EXIT with an error result from a
ready application is an application failure, and the workspace keeps an
automatic instance's record and display assignment for recovery. A revoked thread
binding removes the saved record and prevents restoration. Stored JSON never
contains credentials, grants, PIDs or runtime objects. Native Terminal has no
cold-resume contract; a surviving session service would be required to rejoin
a PTY.

## Questions and close

`client.query(launch, options)` submits a broker-owned `confirm` or `text`
question. Titles are limited to 80 bytes, messages to 512, accept labels to
24 and text input to 256, all without controls. A second pending question for
one view returns `busy`. Results contain `accept|cancel`, a value and an error;
questions are not persisted, are canceled on app exit, and F12 retains the
question while resetting transient input and focus. They are plain text, not
password fields. A positive answer is not a capability grant.
The options are `{kind = "confirm"|"text", title = string, message?, accept?,
initial?}`. Listen on `bee.application.query.result` before calling `query`;
it returns `request_id, error`. Decode the broker message with
`client.query_result(launch, tostring(message:from()), message:payload():data())`
and match its `request_id`. The decoded reply is `{request_id, action =
"accept"|"cancel", value, error}`; a busy reply has `error = "busy"`.

Terminal key events use `key_type` values such as `runes`, `space`, `enter`,
`backspace`, `tab`, `up`, `down`, `left`, `right`, `pgup` and `pgdown`;
the payload also carries `key`, `ctrl`, `alt` and `shift`. Mouse wheel events
have `type = "mouse"`, `action = "wheel"` and `button = "wheel_up"` or
`"wheel_down"` (some senders use `"up"` or `"down"`).
`bee.application:text.bound(value, limit)` replaces control
characters, including newlines, with spaces and truncates on a UTF-8
character boundary.

An app opts into negotiated close with `client.ready(launch,
{negotiate_close = true})` and the authenticated close request/result helpers.
The first valid readiness acknowledgement fixes the policy. The broker waits
two seconds for an app response; a confirmation can then wait for the user.
Silence exposes Force stop/Cancel, cancellation returns `cancelled`, and
acceptance starts cooperative cleanup before termination if needed. The host
binding selects `close_grace_ms` from 0 to 60000, default 250; application
metadata and close replies cannot extend it. The native Agent window uses the
host-selected long allowance for pending hook delivery. Repeated close clicks
share one negotiation, stale senders and tokens cannot accept it, and a pending
ordinary question becomes `busy`.

Workspace quit gathers opted-in decisions while continuing checkpoint writes
and reports incomplete cleanup after its bounded deadline. Only a successful
checkpoint receipt guarantees a save. Ctrl+Q and fatal process or terminal loss
remain emergency exits without a graceful-close guarantee. When the workspace
host stops or is lost, the broker cancels every application and exits only after
each has exited; an application still running eight seconds after its cancel is
terminated. The Terminal application returns only after its PTY child is reaped,
so a stopped owner leaves no shell behind. Closing a view stops its view-owned
process; work that must outlive a view belongs to a supervised owner service.
