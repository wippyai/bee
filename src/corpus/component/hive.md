# bee.hive

The cross-node call protocol. Every node runs one supervisor; a caller on any
node sends it a request and waits for the reply on a topic of its own. The
supervisor authorizes application operations against live admission, installed
exposure and the authenticated peer-node audience, then executes them inside
the installed application scope. Legacy service routes pass the caller's
authenticated PID to the destination service for domain authorization. `bee hive init` joins the Bee
nodes on a machine into one hive; `bee hive invite` on one machine and
`bee hive join TOKEN` on another join their hives. The token carries every
endpoint the inviting machine is reachable at (LAN, Tailscale, virtual
interfaces); the joiner dials them concurrently, pins the first whose identity
matches the token, and the inviting machine dials back to verify the joiner's
address. The token's ten minutes bound only the join; the joined machine stays in the
hive, and bees running on either machine restart themselves to use it. Bees
remember the addresses of the other machine's nodes and use them as seeds.

| Entry | Responsibility |
|---|---|
| `bee.hive:hive` | The granted app-facing `hive.call` facade; no registry lookup grant is needed |
| `bee.hive.binding:call` | The protected host function behind the bounded `hive.call` capability |
| `bee.hive:protocol` | The wire values and helpers: `call`, `decode_reply`, `ready`, `forwarded`, `forward`, `ok`, `fail`, `supervisor_name`, `node_of`, `clustered` |
| `bee.hive.service:supervisor` | The supervisor process, run as `bee.hive.service:supervisor_service` on `bee:workers` under the actor `bee.hive.supervisor` |
| `bee.hive.security` | Policies `supervisor`, `routing`, `routing_changes`, `caller` and `messaging` |

## Protocol

- `protocol.call(node, op, args, timeout)` resolves the supervisor of `node` (this node's through its node-local name `bee.hive.supervisor`, another node's through the mesh-wide name `bee.hive.supervisor/<node>`) and sends it a `bee.hive.call` request `{op, args, reply_topic, ttl}`. The reply is `{ok, value?, error?}`; a missing reply within `timeout` returns an error. The additive fifth argument enables supervisor-sender verification and bounded reply decoding; the application facade always enables it and reports timeout as outcome unknown. The request carries how long the caller waits, so a supervisor never delivers it after the caller gave up.
- An operation name is `<prefix>.<op>`. The supervisor reads `registry.entry` entries of `meta.type: bee.hive.route` with `data: {prefix, name}`, and hands `<op>` to the process registered node-locally as `name`. Routes follow registry commits. Stock routes: `node` to `bee.node`, `threads` to `bee.threads`, `sync` to `bee.sync` (marked `meta.sync: receiver`), and `approvals` to `bee.approvals`. Approvals uses an explicit operation map and destination approver authorization, with owner revision and digest checks retained.
- A routed service announces readiness with `protocol.ready(name)`; the supervisor accepts the announcement only from the process holding `name` on its node and monitors it. Requests for a service that is not running wait (up to 64 per service) until it announces; requests whose caller stopped waiting are dropped.
- The service receives the operation on the topic `bee.hive.forward` as `{op, args, caller, reply_topic, expires}`. `protocol.forwarded(from, data)` accepts it only from this node's supervisor and returns `nil` otherwise. The service answers with `process.send(caller, reply_topic, protocol.ok(value))` or `protocol.fail(message)`.
- `protocol.node_of(pid, local_node)` is the node a PID belongs to; the mesh authenticates the node of a remote sender's PID.

## Application operations

An application declares `meta.application_ref`, an authored `meta.hive_service`
and a `meta.hive_operation` name, revision, input/output schemas and effect.
`application.call` resolves those declarations only inside the installed grant
owner's overlay. It requires live admission, an exact destination-approved
`hive.expose` grant and an audience admitting the authenticated sending node.
Queued calls repeat authorization. Four execution slots and a 64-call queue
bound the installed-scope executor. Policy mode remains fail-closed until
trusted subject mappings exist; package operations without an installed overlay
also fail closed.

App code imports `bee.hive:hive`; its granted `hive.call` host function bounds
exact destination nodes, workspaces, application addresses, services and
operations. Mutations require a bounded idempotency key. Durable destination
receipts replay completed results, reject changed requests and retain an
unknown outcome for interrupted work. A deadline ends waiting, not execution.

MCP `app_tools` and `tests` accept an optional node. Omission keeps local
behavior; peer discovery includes only live, exposed operations approved for
the sending node. Remote test runs use the existing runner and return a run_id
whose status is read on that node. See `docs/hive_test_sdk` and the overlay
guide section `hive_sdk` for the complete preflight-proven manifest.

Host services use explicit route entries, node-local registration,
`protocol.ready` and authenticated forwarded requests. They retain their own
domain authorization. Adding a legacy route is host composition, not an
application exposure grant.
