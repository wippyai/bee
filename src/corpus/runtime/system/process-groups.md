# "Process Groups"

_Path: en/system/process-groups_

> "Configure cluster-aware named process groups with decentralized membership, broadcasts, monitoring, and reconciliation."

## Table of Contents

- Process Groups

## Content

# Process Groups


A `pg.scope` lets processes join named groups and receive broadcasts addressed to a group. The model follows Erlang/OTP `pg`: groups are created on first join, a process can belong to many groups and join one group multiple times, and each cluster node maintains its own membership state and reconciles with peers over the internode mesh. This page is a configuration and behavior reference; the YAML blocks are entry fragments.

The Lua API is documented in [Process Groups](lua/core/pg.md); this page covers the scope entry kind and its configuration. See the [Cluster Guide](guides/cluster.md) for the surrounding membership model.



## Entry Kind


| Kind | Description |
|------|-------------|
| `pg.scope` | An independent process-group namespace with its own membership state and cluster mesh |

Each scope is isolated: groups and members in one scope are invisible to another. A process opens a scope by its entry ID (`pg.open("app:pg")`) and operates within it.

```yaml
- name: pg
  kind: pg.scope
  lifecycle:
    auto_start: true
```



## Configuration


All fields are optional. The table lists their defaults.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `protocol_timeout` | duration | 5s | Timeout for inter-node sync/discover operations |
| `broadcast_timeout` | duration | 5s | Timeout for delivering a broadcast to a single member |
| `anti_entropy_interval` | duration | 30s | Cadence of the reconcile loop; one peer is synced per tick |
| `circuit_breaker_failures` | int | 3 | Consecutive send failures to a node before its circuit opens |
| `circuit_breaker_reset_time` | duration | 10s | Wait before an open circuit moves to half-open for a test send |
| `max_retries` | int | 3 | Retry attempts for a failed broadcast |
| `retry_base_delay` | duration | 100ms | Initial backoff delay between retries |
| `retry_max_delay` | duration | 1s | Maximum backoff delay |
| `action_queue_size` | int | 256 | Depth at which an "approaching capacity" warning is logged |
| `action_queue_max_size` | int | 1024 | Hard capacity of the internal event-loop queue; operations are dropped when full |
| `monitor_buffer` | int | 64 | Per-subscription event channel capacity; events drop for a subscriber whose buffer fills |
| `max_groups` | int | 0 | Maximum distinct groups (0 = unlimited) |
| `max_members_per_group` | int | 0 | Maximum members per group, counting multi-joins (0 = unlimited) |

```yaml
- name: pg
  kind: pg.scope
  anti_entropy_interval: 30s
  circuit_breaker_failures: 3
  max_members_per_group: 10000
  lifecycle:
    auto_start: true
```



## How It Works


**Single-writer state.** Each scope runs a single-goroutine event loop (the gen_server pattern). All mutations are serialized through it; reads of members and groups are served from atomically-published snapshots, so they never block the loop.

**Join/leave propagation.** A local join or leave is applied to the loop and then fanned out to the union of the live membership peers and any previously-discovered remote nodes. Sending to that union ensures a freshly joined or not-yet-converged node still receives the change.

**Broadcast.** `broadcast` snapshots the full cross-cluster member list inside the loop, then delivers to each member outside the loop so a slow recipient cannot stall the scope. `broadcast_local` does the same but only for members on the local node.

**Monitor and events.** Subscribing and snapshotting the current members happen in one event-loop tick, so a subscriber never misses or double-counts a change that races the subscription. Subscribers receive `member.joined` / `member.left` events; a leave for a process that joined N times reports the PID N times, preserving multiplicity.

**Anti-entropy and discovery.** On start, a scope sends discover messages to a small random subset of peers (capped to avoid an N² storm when many nodes restart at once). When a node joins, it receives a full state sync. The anti-entropy loop then periodically pushes a full sync to one peer at a time, so any broadcast a peer missed eventually converges. The receiver applies a differential sync — only members actually added or removed emit events.

**Circuit breakers.** A per-node circuit breaker tracks consecutive send failures. After `circuit_breaker_failures` failures it opens and sends to that node are skipped until `circuit_breaker_reset_time` elapses, when one test send is allowed. Join/leave broadcasts that hit an open breaker are retried with exponential backoff up to `max_retries`.



## Observability


A liveness health check (`pg.broadcast_recent.<scope>`) reports unhealthy if a scope sees no broadcast traffic for an extended period, surfacing a wedged event loop or a persistent partition. See the [Observability Guide](guides/observability.md).



## See Also


- [Process Groups](lua/core/pg.md) - The Lua API
- [Cluster](guides/cluster.md) - Membership and the clustering model
- [Process Model](concepts/process-model.md) - Processes, PIDs, and messaging



## Navigation

Previous: "Process Host" (system/process-host)
Next: "Terminal" (system/terminal)
