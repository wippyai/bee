# Configurable managed MCP

A protected managed-launch policy may declare `gateway_surface` alongside
`gateway_tools`. The tool list is an independent ceiling: selecting a trait
never exposes a tool outside it. Admission measures the configuration and binds
it to the managed attempt. Component metadata describes a capability; it does
not authorize invocation or scope.

The MCP route handler is `bee.gateway.api:mcp_http` from the `bee/gateway`
component. The host owns the listener, router, route, and selected tool
policies; configuring the route or a tool does not grant caller authority.

## Surface declaration

`gateway_surface` contains:

- `tools`: component tool descriptions with name, operation, description,
  policies, schema and annotations;
- `traits`: `{id, title, prompt, tools}` declarations; several may be active;
- `base_tools`: tools selected for every session within the tool ceiling;
- `active_traits`: initial trait IDs;
- `fixed_context`: host-selected context data; and
- `dynamic_keys`: context keys the binding may set.

Built-in tools are included automatically. Duplicate names and the reserved
`session` and `call_tool` names are refused. Every selected operation still
needs its own endpoint invocation permission and domain authorization. Tools
run as the binding's subject with the named host-approved policies; tool code
does not receive endpoint context, actor or scope construction rights.

## Session and context

`session` with `{operation = "read"}` returns the current revision, admitted
and active traits, dynamic context, allowed dynamic keys and tool schemas.
`{operation = "select", expected_revision, active_traits, context}` replaces
selection atomically. A stale revision, an unknown trait/key or an attempt to
overwrite fixed context is refused.

Context is ordinary native `ctx` data. It does not choose security actors or
permissions. Native `with_context` overlays it on inherited context, so host
endpoint composition also controls ambient context visible to a tool. Native
Terminal retains operating-system-user authority; MCP scope is not a filesystem
sandbox.

Every tool call receives the reserved `bee.gateway.binding` context key with
`binding_id`, `thread_id`, `action_id`, `attempt_id` and, when host-selected,
`policy_ref`, `workspace_id` and `origin_view`. A thread-launched child inherits
its origin view. Agents cannot add or replace this key. These IDs support
audit and destination attribution; they are not authority, and each owner still
checks membership and permission.

A client that caches discovery can call the stable `call_tool` tool with
`{name, arguments}`. It takes the same active-tool and authorization path as a
direct call. The gateway does not rewrite a running harness's system prompt.

## Built-in tools

`overlay` reaches the public `bee.governance.binding:overlay_call` facade. `guide`
returns the destination's authoring contract and minimal example without naming
or granting an overlay. `create`, `list`, `read`, `put`, `remove` and `freeze`
operate only on the caller's overlay identity. They use `overlay_id`; a
caller-supplied `workspace_id` is refused. Inline file text is bounded to
65,536 bytes, canonical padded base64 to 87,384 bytes (65,536 decoded), and a
complete MCP JSON request to 524,288 bytes.

`components` is the managed-agent read-only Hub view. It permits `catalog`,
`details`, `inspect`, `state`, `files`, `read_file`, `installed` and `plan`.
The nested request retains Hub's exact component, version, resource and path
decoders. It cannot apply a package, change registry state, activate an overlay
or grant package permissions.

`thread_launch` starts a definition from the caller's launch-policy allow-list
in the caller's workspace or in an optional `workspace_id`. It accepts a
definition reference, brief and retry key, and returns the child thread,
action and attempt identity plus the admitted title. A workspace other than
the binding's needs `bee.workspaces.launch` on it in the caller's own scope
(the host attaches `bee:workspace_launch_policy` only to agents it lets act
across workspaces); the launch then runs as the same actor bound to that
workspace. The child gets its own launch policy and tool scope and holds a
host lease on its workspace while it runs.

The request may also choose, each only where the definition's
`allowed_overrides` and its launch policy's `allowed_overrides` both name the
override (`FORBIDDEN` otherwise):

| Field | Choice | Override |
|---|---|---|
| `thread` | `{thread_id}`: an existing thread the caller is an active member of; `{title}`: a new thread with that title | `thread` (a caller-thread definition joining the caller's own thread needs none) |
| `workdir` | `{resource}`: a resource associated in the workspace; `{root_ref, path}`: a folder under a root the host admits, associated at setup | `workdir` |
| `placement` | `native` or `docker`; a kind other than the host's placement binding is `PLACEMENT_UNAVAILABLE` | `placement` |
| `saved_profile_id`, `saved_profile_revision` | a saved profile's preferences for the same definition | none |

Without `thread`, the child joins the caller's thread, so a definition that
opens its own thread is refused with `LAUNCH_THREAD_UNSUPPORTED` rather than
orphaned. Shipped driver definitions and their host policies allow the
`thread` and `workdir` overrides; none allows `placement`, and no Docker
placement binding is installed.

## Coordinating with other sessions

`thread_sessions`, `thread_message` with `session`, and `thread_notify` let one
running agent coordinate with another the way two interactive coding sessions
hand work to each other, for any harness:

- `thread_sessions` lists the running sessions of the caller's workspace whose
  threads the bound subject may read, the caller included (`self`). A session
  is the live gateway binding of an action; each entry has its address
  (`session`, the action ID), attempt, thread and thread title.
- A session address is an action ID, an attempt ID, or a thread ID that holds
  exactly one running session. An ambiguous thread is refused and lists the
  actions to choose from.
- `thread_message` with `session` and no `recipient_ids` records the message
  on that session's thread as the caller's subject. It names the session's
  subject as the recipient, its action in `recipient_action_ids` and the
  caller's own action in `sender_action_id`, so sessions sharing one subject
  can tell who is addressed and reply by address. A message to another thread
  carries no action context there.
- `thread_notify` with `session` and an idempotency key asks the thread owner
  to tell the caller once when that session ends its current turn or exits.
  The notice is a `notification` message on the caller's own thread, addressed
  to its action and caused by the ending record; a waiting `thread_wait` there
  wakes on it. A session that has already exited is reported at once.

Reach follows thread membership: a session on a thread the subject is not a
member of is neither listed nor addressable, and the owner refuses the write
if membership changed. Two independently opened Agent windows run as different
application actors on their own threads, so they reach each other only after
the thread owner joins one to the other's thread; no gateway tool grants
membership. Sessions started with `thread_launch` on the caller's thread share
it and its subject and always reach each other; a child on another thread is
reached through `thread_sessions` and `thread_notify` like any other session.

A harness learns of new records only when it calls a thread tool: every
harness pulls through `thread_read` and `thread_wait`. Nothing types a message
into a running window or writes it to a structured session's input. A window
harness's `Stop` hook is recorded as a hook-sourced turn signal, so notices see
window agents end turns the way stream agents report them. Sessions on another
Hive node are not listed or addressable: Hive forwards only the thread owner's
`send` and `send_status`, and bindings, reads and waits stay node-local.

`delivery` requests delivery of a frozen artifact and reads a staged version's
review, selection and activation state. `publish` publishes only the exact
locally reviewed and applied version, and can require an approved trait. Neither
tool writes an overlay or makes an approval decision.

## Trait configuration

For example, a host may make coordination waiting selectable while keeping
thread reads always available:

```yaml
gateway_tools: [thread_read, thread_wait]
gateway_surface:
  tools: []
  traits:
    - id: research:coordination
      title: Research coordination
      prompt: Read the thread and wait for new results before continuing.
      tools: [thread_wait]
  base_tools: [thread_read]
  active_traits: []
  fixed_context: {project: selected-project}
  dynamic_keys: [experiment]
```

The client reads the session, selects the trait with the returned revision and
sets `{experiment: "baseline"}`. An unlisted trait/tool or a caller-provided
`project` value is refused. Only the protected launch policy can admit this
surface.

## Agent-requested access

A host can declare `access: {policy, traits}` for traits that are
initially unavailable. Such traits cannot also be active, base tools or freely
selectable traits. The host fixes the approver policy, executable targets, tool
scopes and fixed application context. The approval workspace is the binding's
workspace, which the launch selects; a binding without a workspace cannot
request access.

An agent sends `session` `request_access` with an idempotency key, requested
traits and a bounded reason. The gateway creates a durable request bound to its
binding, action, attempt, thread, configuration digest and fixed context.
Approvals presents it through the ordinary Inbox; the agent polls
`access_status`. Once an approver decides, the gateway consumes the exact
effect and records the new selection atomically with its surface revision.

The approval owner remains the decision authority. Replays do not duplicate a
grant or reactivate a later-deselected trait. Restart recovery verifies the
same proposal and configuration before applying an already consumed effect.
A grant lasts only for its binding and is still subject to expiry, credential
rotation and revocation. An agent cannot approve itself, publish arbitrary
registry state or rely on an application ID in context as target authorization.

For listener, credential and hook behavior, see [Gateway](../../reference/agents/gateway.md) and
[Gateway hooks](../../reference/agents/hooks.md). For the application-authoring path, see
[distributed overlay delivery](../overlays.md).
