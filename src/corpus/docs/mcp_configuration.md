# Configurable managed MCP

A protected managed-launch policy may declare `gateway_surface` alongside
`gateway_tools`. The tool list is an independent ceiling: selecting a trait
never exposes a tool outside it. Admission measures the configuration and binds
it to the managed attempt. Component metadata describes a capability; it does
not authorize invocation or scope.

The MCP route handler is `bee.gateway.api:mcp_http`, routed at `/mcp/:action`. The host owns the listener, router, route, and selected tool
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
Claude Code launches that select Bee gateway tools include `mcp__bee__session`
in `--allowedTools`, so `session read` works in `dontAsk` mode. Local Claude
`Edit` and `Write` are separate filesystem tools; a gateway-only authoring
session stages source with `overlay put` and `overlay append`.

Context is ordinary native `ctx` data. It does not choose security actors or
permissions. Native `with_context` overlays it on inherited context, so host
endpoint composition also controls ambient context visible to a tool. Native
Terminal retains operating-system-user authority; MCP scope is not a filesystem
sandbox.

Every tool call receives the reserved `bee.gateway.binding` context key with
`binding_id`, `thread_id`, `action_id`, `attempt_id` and, when host-selected,
`policy_ref`, `workspace_id` and `origin_view`. Agents cannot add or replace this key. These IDs support
audit and destination attribution; they are not authority, and each owner still
checks membership and permission.

A client that caches discovery can call the stable `call_tool` tool with
`{name, arguments}`. It takes the same active-tool and authorization path as a
direct call. The gateway does not rewrite a running harness's system prompt.

## Built-in tools

`overlay` reaches the public `bee.gov.binding:overlay_call` facade. `guide`
names no overlay: without `section` it returns the short index with the
section list, with `section` one section, and with `include_example` the
minimal worked example with its entries JSON inline. `create`, `list files
in`, `read`, `put`, `append`, `remove` and `freeze` operate only on the
caller's overlay identity. They use `overlay_id`; a caller-supplied
`workspace_id` is refused. Inline file text is bounded to 65,536 bytes,
canonical padded base64 to 87,384 bytes (65,536 decoded), and a complete MCP
JSON request to 524,288 bytes.
`list` without an ID enumerates only the caller's overlays; with one it lists
that overlay's files. `append` uses an exact byte offset, expected overlay
revision and fresh idempotency key. The owner computes the assembled SHA-256
digest; `read` pages up to 16,384 decoded bytes.

`components` is the managed-agent read-only Hub view. It permits `catalog`,
`details`, `inspect`, `state`, `files`, `read_file`, `installed`,
`installed_source` and `plan`, each with its own required fields, bounds and
examples in the tool schema.
The nested request retains Hub's exact component, version, resource and path
decoders. It cannot apply a package, change registry state, activate an overlay
or grant package permissions.
`inspect` and `state` require an exact Hub artifact version; use
`installed_source` for the effective Lua source of a locally installed
development version, and `installed` (which takes no request body) for the
effective inventory. `read_file` windows are capped at 16,384 bytes with
`next_offset`. See [hub inspection](hub_inspection.md).

`install_request`, `uninstall_request` and `install_status` are write tools
beside `components`. A request names a Hub package (`component`, optional
exact `version`); the host resolves the plan and files one approval bound to
the caller's thread and attempt. The person decides it in Approvals; the
caller's next `install_status` applies exactly the approved plan digest, and a
replayed poll replays its receipt. They are admitted through the host's
`tool_install_policy_ref` link and never grant Hub management to the
caller. See [agent installation requests](hub_inspection.md#agent-installation-requests).

Read `capabilities` before authoring: it reports the admitted tools with
their policies, the trait catalog, the bound workspace and thread, and the
authoring path.

## Sessions

Ten tools are the only way to start an agent, give it work and read what it
produced: `session_catalog`, `session_open`, `session_run`, `session_send`,
`session_await`, `session_join`, `session_get`, `session_list`,
`session_cancel` and `session_close`. The flow is catalog, open, send, await,
close.

1. `session_catalog` lists the definitions and profiles whose executor is
   ready: the driver is installed, logged in and supported on this platform.
   `include_unavailable` adds the rest with the reason each is not ready.
   Nothing else lists agents, and the call starts nothing.
2. `session_open` takes `spec` (`definition`, optional `profile`, `workdir` and
   `workspace`) and `operation_key`, and returns a `SessionRef`. The session is
   durable: it survives turns, process exits and owner restarts, and no
   process runs while it is idle. The host admits the definition against the
   caller's policy before the session opens.
3. `session_send` takes `session`, `input` (text, or `{schema, value}`), an
   optional `output` schema reference and `operation_key`. It commits one
   immutable unit of work and returns a `WorkReceipt`. A receipt says the work
   is queued; it is not a result. A busy session queues the work, and nothing
   is injected into a running process. `session_send` is the only way to give a
   session work: a task, a follow-up or a correction.
4. `session_await` takes the `WorkRef` (or an operation reference) and
   `timeout_ms` (default 30000, at most 60000) and returns one observation tagged `ready`
   (with the result), `pending`, `blocked` (with what unblocks it) or
   `uncertain`. Queued or accepted is not done, and a timeout never cancels
   the work.
5. `session_close` seals intake and drains accepted work. Await the returned
   operation for the closure.

`session_run` submits one job on a fresh session that closes after settlement;
it returns a `WorkReceipt` to await. `session_join` observes an ordered set of
`WorkRef` values under `all_success`, `all_settled`, `first_success` or
`quorum`, and returns every child's observation; uncertain is not settled.
`session_get` inspects an exact session, work or operation, or recovers an
operation from its saved `operation_key`. `session_list` pages durable
sessions, including idle and closed ones, with a stable snapshot and a feed
cursor. `session_cancel` requests cancellation of one work and keeps its
session open; the receipt says `requested`, and the operation's observation
reports `stopped`, `already_terminal` or `uncertain`.

Every mutation requires `operation_key`. Reuse the same key after a lost
reply; changing the input under a key is a conflict, and `session_get` with
the saved key recovers the operation. Caller identity travels only in the
authenticated call context, never in a payload. Each tool is one method of the
`bee.threads.sessions` owner contract, and the gateway holds no session state; see
[gateway](gateway.md#sessions).

After an owner restart the scheduler reconciles the last placement attempt
before any new invocation. An outcome it cannot prove is reported as
`uncertain`, never silently re-run.

Batch worker definitions run under CLI permission controls, not operating
system confinement; definitions for drivers with no provable control, such as
Grok and OpenCode, are recorded `unconfined`.

## Transcript

`thread_read` reads the committed records of the bound thread after a cursor.
`member_thread` names another thread the caller is an active member of, such as
the thread of a session it opened; the field defaults to the bound thread, the
thread owner checks membership again, and an unrelated thread is refused as
`NOT_FOUND`. It never widens access beyond the caller's own membership.

`thread_message` records one note on the bound thread transcript. Its
arguments are `message_id`, `message_kind` (`progress` or `notification`),
bounded `content` and an idempotency key; it names no recipient or session.
A note is recorded only; it does not schedule execution and wakes nothing. To
give a session work, call `session_send`.

`delivery` checks a frozen artifact without staging it (`preflight`, which
needs the frozen `snapshot_digest`), requests delivery of a frozen artifact
(`request`, which stages it and reads the destination's preflight verdict),
and reads a staged version's review, selection and activation state
(`status`); its destination defaults to the session's own workspace. Check a
candidate with `preflight` before `request`. An overlay named by the
workspace-application rule (overlay `todo`, namespace `app.todo`,
application `app.todo:app`) is admitted by the shipped host profiles, so an
installed agent can deliver an application to its workspace without host
configuration. `publish` publishes only the exact locally reviewed and
applied version, and can require an approved trait. Neither tool writes an
overlay or makes an approval decision.

## Trait configuration

For example, a host may make note recording selectable while keeping thread
reads always available:

```yaml
gateway_tools: [thread_read, thread_message]
gateway_surface:
  tools: []
  traits:
    - id: research:notes
      title: Research notes
      prompt: Record progress notes on the thread as you work.
      tools: [thread_message]
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
Approvals presents it in Needs you; the agent polls
`access_status`. Once an approver decides, the gateway consumes the exact
effect and records the new selection atomically with its surface revision.

The approval owner remains the decision authority. Replays do not duplicate a
grant or reactivate a later-deselected trait. Restart recovery verifies the
same proposal and configuration before applying an already consumed effect.
A grant lasts only for its binding and is still subject to expiry, credential
rotation and revocation. An agent cannot approve itself, publish arbitrary
registry state or rely on an application ID in context as target authorization.

For listener, credential and hook behavior, see [gateway](gateway.md) and
[gateway hooks](gateway_hooks.md). For the application-authoring path, see
[distributed overlay delivery](distributed_app_delivery.md).
