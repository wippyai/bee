# Gateway

bee.gateway gives an admitted managed agent a bounded MCP surface over a
host-owned HTTP listener. The listener is normally 127.0.0.1:0; it is not a
public service. The host selects the endpoint, tool set, hook events and
credential environment names. The gateway owns bindings, credential hashes and
hook intake. The carrier, placement service and runner own the launch
lifecycle.

## Component boundary

Gateway is the `bee/gateway` component, loaded from `modules/gateway/src`.
Its root namespace keeps shared resources and values. Lifecycle and hook queue
calls use `bee.gateway.binding:*`; HTTP route handlers use
`bee.gateway.api:*`; endpoint discovery uses
`bee.gateway:address`. The root namespace has no forwarding functions
for those calls.

A host composes the component and selects the database, listener, endpoint
configuration, harness executable storage, approval policies, and the policies
for admitted built-in tools. The host also owns the HTTP service, router, and
routes that call the API handlers. An endpoint selection describes where the
listener runs; it does not give a caller network authority. Tool, caller, and
listener permissions remain host-selected policies.

## Connection and credentials

The listener accepts loopback and explicitly selected RFC1918 IPv4 addresses.
Wildcard, public, link-local and hostname addresses are refused. Requests must
use the selected Host address and port; localhost is accepted only for the same
127.0.0.1 endpoint. Browser origins are refused.

Every admitted attempt has one revocable binding for its subject, action,
attempt, thread, host-assigned workspace name, owner incarnation, carrier epoch,
expiry and exact tool set. Names must be unique among live actions in one
workspace; an omitted name is the action ID.
The binding is created after durable launch preparation and before placement
starts. It is not created by a plan, and the carrier cannot choose its subject
or thread. A replacement carrier may inherit the current binding for its child;
older epochs cannot replace it.

admit returns an identity, never token bytes. Placement obtains a one-time
materialization key for the carrier-recorded binding, and only its runner can
exchange that key for the current credential generation. The gateway stores
credential hashes and presentation metadata. Tokens are delivered only in the
selected child environment, never in URLs, command arguments, records, evidence
or logs. Reissue is compare-and-set and invalidates the prior generation.
Revocation, expiry, listener replacement and failed startup refuse later use.

Readiness makes a loopback request with a fresh nonce and verifies the current
listener generation. A drain rejects new admissions and stops the listener at
its recorded deadline.

## Gateway operations

| Operation | Caller | Purpose |
|---|---|---|
| open | managed host | Records a listener address and advances its epoch. |
| admit, reissue, revoke, check | carrier or authorized manager | Manage one bound attempt and its credential generation. |
| authorize_materialization, materialize | placement service and its runner | Deliver one credential to the authenticated child process. |
| revoke_attempt | placement supervision | Retire bindings after a fenced attempt failure or loss. |
| ready, drain | carrier or managed host | Verify listener readiness or begin controlled shutdown. |
| mcp | authenticated child | Serve JSON-RPC initialize, tools/list and tools/call. |
| hook operations | authenticated child and carrier | Accept and drain lifecycle observations as described in [Gateway hooks](hooks.md). |

An MCP tool name maps to one existing owner operation. Tool annotations and
driver flags describe behavior; the binding and target owner still enforce
authority.

## Agent tools

The host may admit the ten session tools (session_catalog, session_open,
session_run, session_send, session_await, session_join, session_get,
session_list, session_cancel, session_close), thread_read, thread_message,
capabilities, Governance overlay, Hub components, Hub installation requests
(install_request, uninstall_request, install_status), delivery, publish, docs
and application_open. Each tool receives only bounded
arguments. The binding supplies thread, subject, action, attempt and context.
Tool results carry the JSON reply as text and as structured content with an
output schema; failures use one normalized error shape
`{code, message, field, retryable, remedy}` naming the next call. The server
advertises `listChanged` because trait selection changes the tool set:
re-list tools and read `session` after `select` before calling one.

capabilities is the read-only report of what the host admits for the caller's
workspace: the admitted tools with the policy each runs under, the trait
catalog with allowed, active and requestable traits, the bound workspace and
thread, and the authoring path (overlay guide, delivery preflight).

### Sessions

The ten session tools are the only way to start an agent, give it work and read
its result. They project the `bee.sessions:contract` and `bee.sessions:catalog`
owner contracts one method each; the gateway holds no session state. Arguments
are the published closed schemas, every mutation requires `operation_key`, and
caller identity travels only in the authenticated call context, never in a
payload. The owner binding opens under the host-linked
`target_tool_session_policy`, and each owner reply is held to the published
output schema. A reply that violates it is an `UNAVAILABLE` owner fault.

The flow is catalog, open, send, await, close:

1. session_catalog lists the definitions and profiles whose executor is ready.
   `include_unavailable` adds the rest with reasons. It starts nothing.
2. session_open takes `spec` (`definition`, optional `profile`, `title`,
   `workdir`) and returns a `SessionRef` that survives turns and owner
   restarts. No process runs while the session is idle.
3. session_send takes `session`, `input` and an optional `output` schema
   reference. It commits one immutable unit of work and returns a `WorkReceipt`.
   A receipt says the work is queued; it is not a result. A busy session queues
   the work; nothing is injected into a running process. This is the only way
   to give a session work.
4. session_await takes a `WorkRef` (or an operation reference) and returns one
   tagged observation: `ready` with the result, `pending`, `blocked` or
   `uncertain`. A timeout never cancels the work. The same reference always
   names the same work.
5. session_close seals intake and drains by default, or requests cancellation
   with `mode: cancel`. Await the returned operation for closure.

session_run submits one job on a fresh session that closes after settlement and
returns a `WorkReceipt`; await it. session_join observes an ordered set of
`WorkRef` values under `all_success`, `all_settled`, `first_success` or
`quorum`. session_get inspects one session, work or operation, or recovers an
operation by its saved `operation_key`. session_list pages durable sessions
with a stable snapshot and feed cursor. session_cancel requests cancellation of
one work and keeps its session open; the receipt says `requested` and the
operation observation reports `stopped`, `already_terminal` or `uncertain`.

Reuse the same `operation_key` after a lost reply; changing the input under a
key is a conflict.

### Transcript

thread_read reads committed records of the bound thread after a cursor. With
`member_thread` it reads a thread the caller is an active member of, such as
the thread of a session it opened; the field defaults to the bound thread and
the thread owner checks membership again. An unrelated thread is refused as
`NOT_FOUND`.

thread_message records one note on the bound thread transcript as the
authenticated subject: `message_id`, `message_kind` (`progress` or
`notification`), bounded `content` and an idempotency key. Callers cannot
choose sender, thread, recipients, record family or context. A note is
recorded only; it does not schedule execution and does not wake a session. To
give a session work call session_send.

This gateway tool writes `record` under its own agent tool policy. It does
not add `record` permission to a workspace application's generated
`threads.message` grant (see [Applications](../applications.md)).

delivery and publish take their destination `workspace_id` from the binding:
an omitted `workspace_id` is the binding's own workspace, a request naming any
other workspace is refused, and a binding without a workspace can use neither
tool. delivery has three operations: `preflight` checks a frozen digest
without staging a version and needs `snapshot_digest`; `request` stages the
version and reads the destination's preflight verdict and also needs
`snapshot_digest`; `status` reads a staged version's review, selection and
activation status. Check a candidate with preflight before requesting
delivery. delivery stages versions, so it is not annotated read-only.

application_open is available only through the active, approval-granted
bee.application:runtime trait. It accepts definition_id, literal arguments and
an idempotency key, then routes only an already applied, admitted definition
through the workspace host and applications broker. It cannot publish, activate,
write the registry or apply an overlay. The trusted binding supplies the
workspace, thread, durable approval receipt and, for a window agent, the
originating display. Its result names the workspace, view, instance, definition,
title, reuse state and assigned display when one exists. A retry has one bounded
in-flight operation; an uncertain reply does not start another application.

## Configuration and limits

Drivers render provider configuration into the selected private home and use
the host-selected credential environment variables. They do not receive token
bytes in configuration. Claude and Codex support the rendered MCP setup and
hook adapters; a provider that cannot accept the required configuration cannot
be admitted for those features.

Gateway HTTP uses bounded bodies, exact Host checks, bearer authentication and
no CORS. The runtime HTTP client does not expose redirect refusal, so readiness
is limited to the controlled loopback acceptance path.

Run the relevant checks with:

    make gateway-check
    make managed-launch-fixture-check
    make cross-session-check
    make app-journey-check
