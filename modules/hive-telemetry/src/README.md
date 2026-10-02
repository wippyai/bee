# bee.hive.telemetry

Optional Hive cluster telemetry, as a package the host composes. The kernel
keeps only the primitive: the node host manager answers which workspaces are
live here to an authorized caller. This package pages that answer, aggregates
it across peers, and shapes it for presentation.

## Operations

The node operations and cluster aggregate are open Hive operations; the host
exposes them through its `hive.expose.open` ceiling, and the supervisor
dispatches them through that same generic ceiling with no per-operation code.

| Operation | Responsibility |
|---|---|
| `bee.hive.telemetry:presence` | Node presence: protocol revision, role, cluster size |
| `bee.hive.telemetry:stats` | Runtime statistics: numeric memory, goroutines, CPU count |
| `bee.hive.telemetry:catalog_list` | Public operation catalog in bounded pages |
| `bee.hive.telemetry:holdings` | One bounded page of this node's live workspace holdings with each host phase and lease count |
| `bee.hive.telemetry:cluster` | One holdings page from each named node (at most eight), with the local runtime's link state (`connected`, `outbound`/`inbound` direction and remote address) |

`holdings` reads the node host manager's own read model through its owner
request; a missing manager is an error, never an empty page. `cluster` fans
out through this node's supervisor with a five-second timeout per node; a
node that cannot be reached, refuses, or answers a malformed page is
`unavailable`, never counted as holding nothing. The cluster view decodes one
`system.cluster.members()` snapshot: a missing link reports `connected: false`,
while a link reports whether this node dialed (`outbound` or `inbound`) and the
remote socket address seen here. Link state remains separate from whether the
node's holdings operation answered. Neither operation grants anything or
changes state.

## Approved application status reads

Workspace applications request `contract.call` for binding
`bee.hive.telemetry.binding:status`, methods `snapshot` and `detail`. The
normal delivery review shows that exact binding and method list; the person
approves it on each destination. Call through the application capability
gateway, imported as `bee.gov.binding:contract_call` with native module
`funcs`, rather than importing private stores or using native membership APIs:

```lua
local reply, err = funcs.call("bee.gov.binding:contract_call", {
    binding = "bee.hive.telemetry.binding:status", method = "snapshot",
    arguments = {{}},
})
```

The gateway returns `{ok, value, error?}`. A successful snapshot's `value` is
`{nodes = {...}}`; detail uses `method = "detail", arguments = {{node_id = id}}`
and returns `{node = {...}}`. Decode all replies as unknown before use. Each
node has `node_id`, `name`, `online`, and `status` (`ok` or `unavailable`).
Available rows include numeric `running_sessions` and `pending_approvals`.
Unavailable rows omit counts; do not display those as zero. `online` reports
local/runtime link state independently of the summary's availability.

Snapshot accepts only an empty object and lists at most 64 nodes from runtime
membership plus the host's retained Hive peers, excluding native display
clients. Detail accepts only `node_id` and refuses identities outside that
same set. `bee.hive.telemetry:node_summary` reads names through Node and counts
through the Threads and Approvals owners. Running means a currently accepted
execution under the current owner epoch; idle or queued sessions do not count.
Pending approvals exclude expired and settled requests. Counts cover the node's
workspaces without exposing prompts, request bodies, decisions or credentials.

Refresh by calling snapshot periodically in an asynchronous worker (for example,
every two seconds); rendering and input read its local cache. Both the gateway and status callee check
the application's own live approved grant, so
revocation stops access. No Hive or approval decision authority is granted.

## Host composition

The package declares its requirements through `ns.dependency` on
`bee/application`, `bee/hive`, `bee/threads`, `bee/approvals`, `bee/node`
and `bee/gov`, and requests its exposure
through an `ns.requirement` for the `hive.expose` capability naming its open
operations. Its operations run under host-selected policies:
`bee.security.hive:hive_telemetry_policy` for node and cluster membership reads,
`bee.hive.telemetry.security:holdings_policy` for the manager read,
and `bee.hive.telemetry.security:cluster_policy` for the supervisor fan-out.
Exposure and execution stay host-selected through the install-granted
`hive.expose.open` ceiling in the supervisor exposure scope and the
supervisor dispatch policy.

## Testing

`make test` runs `tests/lua/hive_telemetry`: telemetry output bounds, the
holdings page end to end against the live host manager, and the cluster
aggregate against stubbed node membership and an injected caller (link
directions and addresses, counts, unavailable nodes, malformed pages, strict
membership and input decoding). The kernel primitive keeps its own unit test
at `tests/lua/launch/holdings_test.lua` (`bee.launch:holdings_test`).

Bee links `target_peers` to the native owner's live
`bee.hive.host:enrollment` entry. Its `peers` list retains enrolled offline
Hive nodes; its `nodes` list names local desktop clients and is excluded from
Hive status. A missing supervisor or owner reply yields unavailable counts,
not zero.
