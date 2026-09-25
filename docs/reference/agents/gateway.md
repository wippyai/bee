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
listener generation. A drain rejects new admissions, releases waits with
released/draining, and stops the listener at its recorded deadline.

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

The host may admit thread_read, thread_wait, thread_message, thread_sessions,
thread_notify, session_directory, session_send, session_inbox, session_ack,
session_reply, thread_launch, launch_definitions, capabilities, Governance
overlay, Hub components, delivery and docs. Each tool receives only bounded
arguments. The binding supplies thread, subject, action, attempt and context.
Tool results carry the JSON reply as text and as structured content with an
output schema; failures use one normalized error shape
`{code, message, field, retryable, remedy}` naming the next call. The server
advertises `listChanged` because trait selection changes the tool set:
re-list tools and read `session` after `select` before calling one.

capabilities is the read-only report of what the host admits for the caller's
workspace: the admitted tools with the policy each runs under, the trait
catalog with allowed, active and requestable traits, the bound workspace and
thread, launch rights with the launch policy reference, and the authoring
path (overlay guide, delivery preflight). launch_definitions lists the
definitions the caller's launch policy admits with placements, overrides and
saved profile IDs and revisions; it starts nothing.

thread_message always writes a message record through the thread owner.
Callers cannot choose sender, thread, record family or context. Without
`session` it writes to the bound thread; with `session` it writes to that
running session's thread, addressed to its action and naming the caller's.
thread_wait is read-only and does not create an obligation.

thread_sessions pages the live, unsealed bindings of the caller's workspace
in stable action order, one per action under its newest carrier epoch, and
keeps only those whose thread the bound subject can read, as answered by the
thread owner's `get` run as the subject. The scan is complete; `cursor` and
`limit` select a window and the reply names `next_cursor` (absent at the end)
with `eof`. thread_notify resolves a session the same way and registers the
thread owner's one-shot notice on the caller's own thread. An unreadable or
unknown session is `NOT_FOUND`; a binding without a workspace has no peer
sessions. See [Configurable managed MCP](../../guides/agents/mcp.md#coordinating-with-other-sessions). thread_launch starts only a
definition named in the caller's launch-policy allow-list, in the binding's
workspace or in a `workspace_id` the caller's scope may launch into; its child
is admitted through the ordinary carrier path with its own policy. Its
optional `thread`, `workdir`, `placement` and saved profile choices decode
with `bee.application:agent_protocol` and take effect only where the
definition and its launch policy allow the override.

session_directory pages local live actions in the caller's workspace that the
host grants `bee.sessions.discover` on, in stable name order with the same
cursor paging. It returns a name and exact `{node_id, action_id}` address,
grant epoch, current attempt state and latest inbox delivery state. The
recipient thread owner supplies the epoch and states without granting access
to its records. A send grant alone does not make a peer discoverable. If
names collide in historical data, callers use the exact address; new live
admissions reject a duplicate workspace name.

session_send takes an exact address, current `grant_epoch`, retry key,
`message_id` and bounded content. The gateway supplies the authenticated
sender action and thread and computes the payload digest. The destination
owner requires a host-selected `bee.sessions.send` policy for the exact
`<workspace_id>/<node_id>/<action_id>` resource and its own acceptance rule.
The bundled Bee host grants managed agents a send attempt to actions in their
own workspace; the destination owner checks the authenticated workspace and
recipient's acceptance. Another host may select the bundled deny policy or a
narrower exact-address policy. session_inbox pages the bound
action's items; session_ack marks one item acknowledged; session_reply commits
a reply to the original sender's address with an explicit cross-thread
`in_reply_to` reference and outcome. These tools commit durable records and
receipts. A fixture-enabled Claude structured carrier can insert an identified
item between turns through its fenced stdin controller. Shipped production
policies leave that path disabled pending executable acceptance. The gateway
does not type into a PTY or forward inbox messages across Hive.
`session_send` and `session_inbox` expose the persisted `delivery_status`:
`waiting_for_restart` when the target has no live attempt and `undeliverable`
when its action has ended. These statuses do not change the item's receipt
`state` or grant an automatic restart.

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
