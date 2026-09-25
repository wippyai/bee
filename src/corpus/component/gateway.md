# bee.gateway

`bee/gateway` owns the authenticated thread port a managed harness child
reaches over HTTP. It owns bindings, opaque tokens stored only as hashes, the
listener epoch, drain, readiness, and HTTP handlers. The listener itself
(`http.service`, router, and endpoints) belongs to the host composition. The
activation binds native loopback port zero and reads the assigned address
through supervisor state. Agent
profiles declare `thread_read`, `thread_wait`, `thread_message`,
`thread_sessions` and `thread_notify` (find, address and be told about other
running sessions of the workspace whose threads the subject reads), the
`session_directory`, `session_send`, `session_inbox`, `session_ack` and
`session_reply` tools for separately owned action inboxes, the
caller-owned Governance `overlay` tool, and `thread_launch`, which starts one
host-allow-listed managed launch in the caller's own workspace and returns the
child's thread, action and attempt. The host may admit any subset; no default
launch policy advertises `thread_launch` or names an `agent_launch` definition,
so an agent starts another only where the owner has opted in. The
overlay tool also carries a read-only `guide` operation stating this
destination's application authoring contract and one minimal example (derived
from the same rule tables preflight enforces). It can stage and freeze files but
cannot publish or activate them.

The host can explicitly admit `application_open` to open an already admitted
application with literal arguments. Workspace and origin-view identities come
from the authenticated binding, not tool arguments. The workspace host assigns
the new app to that view's display using the existing assignment store; a
headless binding leaves it unassigned. The result carries qualified view and
instance identities for subsequent interaction.

The HTTP MCP route bounds each JSON request at 512 KiB. Overlay calls through MCP
accept at most 64 KiB of text or 87,384 bytes of canonical base64 per put
(at most 64 KiB decoded);
larger authoring files require another admitted facade rather than an oversized
gateway request. The underlying overlay store keeps its own larger
limits for non-MCP callers.
All four default profiles include the `thread_message` write. Claude/Codex also
declare lifecycle hooks.

The host may assign a workspace-local name at admission; an omitted name is
the action ID, and another live action cannot reuse it. Directory entries use
exact `{node_id, action_id}` addresses and show only peers the subject may
discover, with attempt and latest inbox delivery state. The send tool needs
the host's `bee.sessions.send` grant on the exact workspace/node/action
resource and the target owner must accept the sender. The bundled Bee host
selects a workspace send policy for managed agents; the destination owner
still requires the authenticated sender to belong to that workspace, the
current epoch and the recipient's acceptance. An installing host can select
the deny policy or a narrower address policy instead. Inbox tools commit and
read durable items. `session_send` and `session_reply` accept a node-qualified
remote address: the gateway asks the host-selected remote resolver for the
thread and workspace it names (the bundled host links
`bee.hive.service:remote_sessions`, which calls the destination owner's
`inbox_resolve`), then sends there. Resolution is discovery only — the
destination owner authenticates the forwarded principal and re-checks
workspace, send grant, target action and epoch — and a composition that links
no resolver answers a remote address as not found.

The default remains `127.0.0.1:0`. A host may explicitly select a loopback or
RFC1918 IPv4 interface for a local container, with its corresponding readiness
permission. The native listener chooses the port; discovery verifies both its
interface and execution identity. MCP and hook requests must name that exact
interface and port in Host. This does not grant network access, enroll another
node, implement managed Docker execution or establish provider conversation
recovery.

## Host composition

A host composes `bee/gateway` and selects its database, listener, endpoint
configuration, and harness executable storage. It may also select the approval
request and consume policies and the policies for each built-in MCP tool. An
absent approval link fails closed. The selected endpoint describes a destination;
it does not grant network authority.

The host creates the HTTP service, router, and endpoint routes that call the
component's API functions. It also selects the policies that permit callers to
use those functions and the policies a bound tool receives. Requirements and
registry metadata describe those links; they never grant authority by
themselves.

## Namespaces

`bee.gateway` keeps the component's shared resources and values, including the
stable database, listener, address, and hook-executable entries. The callable
lifecycle and hook operations are in `bee.gateway.binding`; the HTTP handlers
are in `bee.gateway.api`; and endpoint lookup is
`bee.gateway:address`. `bee.gateway.migrations`,
`bee.gateway.persist`, and `bee.gateway.security` contain the component's
migration, storage, and policy implementation. There are no root-namespace
forwarding functions for the lifecycle operations.

The `catalog.from_framework` projection exposes an admitted agent closure's
selected function tools and traits through the gateway: each function id
becomes one MCP tool under its `llm_alias` adapter alias with its input
schema, and each trait keeps its prompt with those aliases. The alias carries
no authority; the host supplies one policy list per function id, and
selection still refuses any tool outside the admitted ceiling.
