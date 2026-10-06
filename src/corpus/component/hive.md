# bee.hive

The cross-node call protocol. Every node runs one supervisor; a caller on any
node sends it a request and waits for the reply on a topic of its own. The
supervisor routes the operation to the node-local service that serves its
prefix, passing the caller's authenticated PID. `bee hive init` joins the Bee
nodes on a machine into one hive.

| Entry | Responsibility |
|---|---|
| `bee.hive:protocol` | The wire values and helpers: `call`, `ready`, `forwarded`, `forward`, `ok`, `fail`, `supervisor_name`, `node_of`, `clustered` |
| `bee.hive.service:supervisor` | The supervisor process, run as `bee.hive.service:supervisor_service` on `bee:workers` under the actor `bee.hive.supervisor` |
| `bee.hive.security` | Policies `supervisor`, `routing`, `routing_changes`, `caller` and `messaging` |

## Protocol

- `protocol.call(node, op, args, timeout)` resolves the supervisor of `node` (this node's through its node-local name `bee.hive.supervisor`, another node's through the mesh-wide name `bee.hive.supervisor/<node>`) and sends it a `bee.hive.call` request `{op, args, reply_topic, ttl}`. The reply is `{ok, value?, error?}`; a missing reply within `timeout` returns an error. The request carries how long the caller waits, so a supervisor never delivers it after the caller gave up.
- An operation name is `<prefix>.<op>`. The supervisor reads `registry.entry` entries of `meta.type: bee.hive.route` with `data: {prefix, name}`, and hands `<op>` to the process registered node-locally as `name`. Routes follow registry commits. Stock routes: `node` to `bee.node`, `threads` to `bee.threads`, `sync` to `bee.sync` (marked `meta.sync: receiver`).
- A routed service announces readiness with `protocol.ready(name)`; the supervisor accepts the announcement only from the process holding `name` on its node and monitors it. Requests for a service that is not running wait (up to 64 per service) until it announces; requests whose caller stopped waiting are dropped.
- The service receives the operation on the topic `bee.hive.forward` as `{op, args, caller, reply_topic, expires}`. `protocol.forwarded(from, data)` accepts it only from this node's supervisor and returns `nil` otherwise. The service answers with `process.send(caller, reply_topic, protocol.ok(value))` or `protocol.fail(message)`.
- `protocol.node_of(pid, local_node)` is the node a PID belongs to; the mesh authenticates the node of a remote sender's PID.

A package exposes operations to the hive by adding a route entry and a service that registers its name, calls `protocol.ready` and answers forwarded requests. The service imports `protocol: bee.hive:protocol` and needs the `bee.hive.security:messaging` policy to send.
