# "Cluster"

_Path: en/concepts/cluster_

> "How Wippy nodes discover peers, route process messages, and coordinate through gossip and Raft."

## Table of Contents

- Cluster

## Content

# Cluster


A single Wippy node is a complete runtime. A **cluster** connects several nodes so processes can use cluster-wide names, route messages across nodes, and coordinate through locks, groups, and a shared consensus core.

Clustering is opt-in (`cluster.enabled`). This page explains the model your code sees; for topology, configuration, and operations see the [Cluster Guide](guides/cluster.md).



## Cluster Model


Nodes discover one another through **gossip** (SWIM). A node joins through a seed, after which membership and failure information converge without a central coordinator. A bounded **Raft** core provides linearizable consensus through a dynamically reconciled voter set, while other nodes participate through gossip.

The application-facing model has three parts: **names**, **routing**, and **coordination primitives**.



## Naming


A process is normally addressed by its PID. In a cluster, it can also be registered under a **name** and reached by that name from other nodes. The selected **scope** determines the consistency guarantee and coordination cost:

| Scope | Visibility | Guarantee | Use it for |
|-------|------------|-----------|------------|
| **Local** | this node | instant, no coordination | node-local helpers |
| **Eventual** | cluster-wide | converges after gossip; conflicts resolve and notify the loser | service, group, and bounded presence names |
| **Consistent** | cluster-wide | linearizable singleton via Raft | the standard cluster-wide named service |
| **Strong** | cluster-wide | Consistent, plus every live node acknowledges before the name is active | control-plane singletons and locks |

The scopes are ordered as `Local < Eventual < Consistent < Strong` by consistency and coordination cost. Select the least costly scope that meets the required guarantee. Names are registered through [`process.registry`](lua/core/process.md). Local names are removed when the process exits; Consistent and Strong names are also reaped on process exit or node departure. Eventual names are removed explicitly or when their origin node leaves, not automatically when only the owning process exits.



## Routing


Routing connects a registered name to the process that owns it:

- **Reads are local.** Every node resolves a name from its own replica or gossip-disseminated cache — no network round-trip to look up a name. This keeps resolution fast and keeps working during partitions.
- **Resolution has a fixed order.** A name is resolved across the planes most-authoritative first — Consistent and Strong (Raft), then Eventual (gossip), then Local — so a cluster-wide name shadows a local one of the same string.
- **Writes route to the authority.** A Consistent or Strong registration goes through the Raft leader; a node that isn't the leader forwards the write and waits for the result. Once committed, the active binding is disseminated over gossip so every node — including those not in the Raft core — can resolve the name locally afterward.
- **Messaging routes by PID.** When you `process.send` to a name, it resolves to a PID and the relay delivers the message to the owning node. Your code addresses a process the same way whether it lives on this node or another — location is transparent.

Applications register and resolve names without addressing the authority node directly. After resolution, messages route to the node that owns the target PID.



## Primitives


Clustering exposes a small set of coordination building blocks:

- **Membership and identity** — the live set of nodes and this node's identity and role. Use it to discover peers or shard work. See [`system.cluster`](lua/system/system.md) and [`system.node`](lua/system/system.md).
- **Consensus state** — the Raft leader, term, and this node's role, for diagnostics and leader-aware logic. See [`system.raft`](lua/system/system.md).
- **Cluster-wide names** — register and resolve processes by name and scope, the foundation everything else builds on. See [`process.registry`](lua/core/process.md).
- **Distributed locks** — cluster-wide mutual exclusion with at most one holder, released automatically if the holder dies. See [`system.lock`](lua/system/system.md).
- **Process groups** — join named groups and broadcast to every member across all nodes, Erlang-style. See [Process Groups](lua/core/pg.md).

These primitives share membership and routing infrastructure. Consistent and Strong names and distributed locks use the Raft core. Process groups use gossip membership to discover peers, send changes over the relay, and periodically exchange full state for convergence.



## See Also


- [Cluster Guide](guides/cluster.md) — Topology, configuration, and operations
- [Process Management](lua/core/process.md) — Spawning, messaging, and the name registry
- [Process Groups](lua/core/pg.md) — Named groups and broadcast
- [System](lua/system/system.md) — `system.cluster`, `system.node`, `system.raft`, `system.lock`
- [Process Model](concepts/process-model.md) — Processes, PIDs, and messaging



## Navigation

Previous: "Process Model" (concepts/process-model)
Next: "Functions" (concepts/functions)
