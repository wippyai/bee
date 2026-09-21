# Configurable managed MCP

A protected managed-launch policy may declare `gateway_surface` alongside
`gateway_tools`. The tool list is an independent ceiling: selecting a trait
never exposes a tool outside it. Admission measures the configuration and binds
it to the managed attempt. Component metadata describes a capability; it does
not authorize invocation or scope.

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

`overlay` reaches the public `bee.governance:overlay_call` facade. `guide`
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
in the caller's workspace and thread. It accepts a definition reference, brief
and retry key, and returns the child thread, action and attempt identity plus
the admitted title. The child gets its own launch policy and tool scope. A
launch that would create a different thread is refused rather than orphaned.

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

A host can declare `access: {workspace_id, policy, traits}` for traits that are
initially unavailable. Such traits cannot also be active, base tools or freely
selectable traits. The host fixes the approval workspace, approver policy,
executable targets, tool scopes and fixed application context.

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
