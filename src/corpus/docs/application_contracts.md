# Application contracts

This is the version 1 contract for view-owned applications. A **definition**
is a `process.lua` registry entry with `meta.type = bee.app`. An **instance**
is one launch of a definition on a desktop; it runs as one process with one
view. The node owner (`bee.node`) is the broker: it admits definitions,
starts instances, routes the `bee.app.*` messages below and keeps instances
across restarts. An app is built on `bee.app:client`.

## Declaration

An app definition carries `meta.application`:

| Field | Rule |
|---|---|
| `api_version` | `1` |
| `lifetime` | `view` |
| `revision` | nonempty, at most 80 bytes; advance it whenever source or configuration changes |
| `title` | nonempty, at most 80 bytes |
| `instance_policy` | `singleton` or `multiple` |
| `icon` | optional, at most 8 bytes |
| `group`, `role` | optional presentation hints (at most 160 and 32 bytes) |
| `menus` | optional list of up to 16 `bee.menu` entry ids |
| `terminal` | optional boolean; `true` runs the app as a terminal page |
| `resume_schema`, `restart_policy` | see Checkpoint |
| `commands` | optional list of up to 16 command handlers |

`menus` names where the Start panel shows the app: `bee.shell:apps_menu`
(Apps), `bee.shell:system_menu` (System, for apps that inspect and manage the
node) and `bee.shell:desktop_menu` (the desktop's context menu). An app that
names no menu is installed and runnable but appears in no menu. Roles, menus
and metadata describe an app; they never grant authority.

```yaml
- name: app
  kind: process.lua
  meta:
    type: bee.app
    application:
      api_version: 1
      title: Hello
      lifetime: view
      revision: "1"
      instance_policy: singleton
      menus: [bee.shell:apps_menu]
  source: file://app.lua
  method: main
  modules: [tty, process, channel]
  imports:
    client: bee.app:client
    appearance: bee.ui:appearance
    frame: bee.ui:frame
```

`bee NAME` opens the app that handles command name `NAME`. A handler is
`{name, arguments?, fullscreen?}` in `meta.application.commands`, or a
`bee.app_command` registry entry whose data names `name`, `definition_id`,
optional `arguments` and `fullscreen`. Names are lowercase `[a-z][a-z0-9_-]*`
up to 40 bytes; `run`, `runtime`, `update`, `client` and `node` are reserved.
A name matching more than one installed app is refused. `bee claude`,
`bee codex`, `bee agy`, `bee grok`, `bee muse` and `bee opencode` open the
Sessions app on the matching driver and accept no trailing arguments.

## Admission and authority

Every app runs as a host-created actor derived from the workspace, instance,
definition and revision, inside the policy group `bee.node.security:application`
plus the policies its process entry and admission name. Metadata and launch
arguments never authorize calls.

The node owner finds a definition's admission binding in this order:
`bee.node.application_admission` registry entries (the host's own apps),
then the overlays governance admitted for the workspace, then the packages it
composes. A binding has `definition_id`, `policies`, `thread_access`
(`none` or `observe_post`), `appearance_write`, `application_stop`,
`scope_management` and `close_grace_ms`. An app without a binding runs in the
base group. `scope_management: true` selects
`bee.node.security:scope_managing_application`, which lets the app build call
scopes; the Sessions app (`bee.harness.app:app`) holds it. Native execution has
the operating system user's authority; no binding makes it a sandbox.

An agent-authored app declares capabilities with `ns.requirement` entries
that name a catalog capability; a request grants nothing until a person
approves it. See [distributed_app_delivery](distributed_app_delivery.md) and
[component/capability](../component/capability.md).

## Launch and lifecycle

The broker passes one launch value to the app's `main`. `client.launch(value)`
validates and copies it: `version`, `broker_pid`, `workspace_pid`,
`workspace_id`, `instance_id`, `view_id`, `definition_id`, optional
`thread_id`, `execution_generation`, `definition_revision`,
`registry_revision`, `launch_token`, `resume_schema`, `resume_state`,
`arguments` and `appearance`. `client.reference(launch)` returns only
`{workspace_id, instance_id, view_id}`.

Messages to the broker carry `version = 1`, the instance id and the launch
token; the broker refuses a message that does not come from the instance's
own process with its token.

| Topic | Sent by | Helper |
|---|---|---|
| `bee.app.ready` | app | `client.ready(launch, {negotiate_close = true}?)` |
| `bee.app.title` | app | `client.title(launch, title)` |
| `bee.app.query` | app | `client.query(launch, options)` |
| `bee.app.checkpoint` | app | `client.checkpoint(launch, json)` |
| `bee.app.request` | app | `client.navigate(launch, definition_id, arguments?)` |
| `bee.app.close.reply` | app | `client.close_reply(launch, request_id, decision)` |
| `bee.app.query.result`, `bee.app.checkpoint_result`, `bee.app.close`, `bee.app.close.result`, `bee.app.navigate` | broker | `client.query_result`, `client.close_request`, `client.close_result`, `client.navigation` |

Call `client.ready(launch)` after the first frame is presented. Every helper
returns whether the message was queued, never whether it was applied.

An open may carry up to 16 string arguments, each at most 1 KiB, without
control characters. Opening a running singleton on the same desktop focuses
it and delivers any arguments to it on `bee.app.navigate`; the receiver
decodes them with `client.navigation(launch, sender, payload)`, which accepts
only the broker's message for the current instance, view, generation and
token. Opening a definition from inside an app uses `client.navigate`.

`client.title(launch, title)` sets a window title of at most 80 bytes
without control characters.

A running app is stopped by cancellation; its process exiting closes its view.
Apps are linked to the node owner, so an owner failure takes its apps with it
and the restarted owner reopens each kept instance.

## Questions and close

`client.query(launch, options)` asks the person a `confirm` or `text`
question and returns `request_id, error`. Options are `{kind, title,
message?, accept?, initial?}`; titles are at most 80 bytes, messages 512,
accept labels 24 and text input 256, all without control characters. Listen
on `bee.app.query.result` before calling `query` and decode the reply with
`client.query_result(launch, tostring(message:from()), message:payload():data())`,
which yields `{request_id, action = "accept"|"cancel", value, error}`. A
second question while one is pending replies `error = "busy"`. A positive
answer is not a capability grant.

An app opts into negotiated close with `client.ready(launch,
{negotiate_close = true})`. The broker then sends `bee.app.close` and waits
for `client.close_reply` with `accept`, `cancel` or `confirm` (the person is
asked); a forced close stops the app without asking. Without negotiation a
close stops the app.

## Checkpoint and restore

An app opts in with `resume_schema` (nonempty, at most 80 bytes, no control
characters) and `restart_policy: automatic|manual`; the default is `never`.
Preflight reports `APPLICATION_CHECKPOINT` for an app whose metadata the
desktop cannot open.

`client.checkpoint(launch, json_string)` queues at most 64 KiB of opaque,
application-owned JSON and returns a request id. The broker replies on
`bee.app.checkpoint_result` with `error_code` empty once the state is stored,
or `invalid_checkpoint` when `resume_schema` differs from the definition's, or
`storage`. The stored state is passed back as `launch.resume_state` when the
node reopens the instance. Stored state never contains credentials, grants or
PIDs.

## Presentation

Draw through `bee.ui:frame` and read appearance through `bee.ui:appearance`;
see [component/ui](../component/ui.md). `launch.appearance` carries the
current preferences. Terminal key events carry `key_type` values such as
`runes`, `space`, `enter`, `backspace`, `tab`, `up`, `down`, `left`, `right`,
`pgup` and `pgdown`, plus `key`, `ctrl`, `alt` and `shift`; mouse events have
`type = "mouse"` with `action` and `button`. `bee.ui:text.bound(value, limit)`
replaces control characters with spaces and truncates on a UTF-8 boundary.

## Running managed agents

An app opens and drives managed agents with `bee.threads.sessions.client:sessions`,
which calls the `bee.threads.sessions:contract` and
`bee.threads.sessions:catalog` owner contracts as the app's own actor. The
client grants nothing: the owner authorizes every operation. The flow is
catalog, open, send, await, close. `send` is the only way to give a session
work; its receipt proves intake only, and the result comes from `await`.

```lua
local sessions = require("sessions")   -- imports: sessions: bee.threads.sessions.client:sessions

local page = sessions.catalog{}                         -- admitted definitions and profiles with readiness
local s, fault = sessions.open{definition = "bee.driver.codex.profiles:research_batch", operation_key = "research/open"}
if not s then return fault.code .. ": " .. fault.message end
local work = s:send{input = "Summarize the build scripts in this folder.", operation_key = "research/send"}
local seen = work:await{timeout_ms = 30000}
s:close{operation_key = "research/close"}
```

Functions: `open`, `call`, `send`, `cancel`, `close`, `await`, `join`, `get`,
`work`, `list`, `history` and `catalog`; `sessions.client()` returns an
independent client. `call{definition, input, ...}` opens a session with its
first work and awaits it once. Every function returns `value, Fault`; a Fault
carries `code`, `message` and a `retry` of `never`, `same_key`, `refresh` or
`reconcile`. `await` bounds observation, never execution: a timeout is a
pending observation and the work keeps running. Every mutation carries an
`operation_key`, so a replayed handler receives the original receipt; a lost
reply is `UNKNOWN_OUTCOME` and is retried with the same key. See
[component/sessions](../component/sessions.md).

Launch definitions are registry entries with `meta.type = bee.launch_definition`.
Installed driver definitions include `bee.driver.<name>.profiles:research_batch`
for `claude`, `codex`, `agy`, `grok`, `muse` and `opencode`, plus
`bee.driver.codex.profiles:named_batch` and each driver's `default_window`.
The catalog lists which are ready; the owner still decides admission when
`open` runs.

`bee.app.threads:client` (`request`, `result`) formats `bee.app.thread.request`
messages carrying the operations `read`, `post`, `subscribe`, `page`,
`ack_page`, `resume` and `unsubscribe`.
