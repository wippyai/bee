# Documentation map

Repository documentation describes the implemented contracts and the boundaries
that keep them safe. Bee also ships a generated, hashed documentation corpus so
managed agents can search those contracts offline; refresh it with the existing
generator when the corpus is intentionally updated.

| Read for | Source |
|---|---|
| Runtime modules and Bee contracts available offline | [Agent documentation corpus](../src/docs/README.md) |
| Running Bee and local development | [Repository README](../README.md), [agent guide](development/agent-guide.md), [development conventions](development/conventions.md) |
| Ownership and boundaries | [System map](development/ownership.md), [package boundaries](development/package-boundaries.md) |
| Contributions and community standards | [Contributing](../CONTRIBUTING.md) |
| Vulnerabilities and credential handling | [Security](../SECURITY.md) |
| Bee visual language and accessible terminal UI | [UI brand book](guides/ui.md) |
| Desktop, workspace host, client attachments, and layout persistence | [Desktop](guides/desktop.md) |
| Application admission, launch, messages, and recovery | [Application contracts](reference/applications.md) |
| Workspace storage and application state | [Storage](reference/storage.md), [workspace state](reference/workspace-state.md) |
| Threads, Timeline, subscriptions, and delivery | [Threads](reference/threads.md) |
| Node metadata, synchronization, and approval inbox | [Sync and inbox](reference/sync-and-inbox.md), [approvals](reference/approvals.md) |
| Native executable, updates, and I/O events | [Native distribution](operations/native.md) |
| Runtime integration and upstream boundaries | [Runtime integration](development/runtime.md) |
| Release artifacts and publication | [Releasing](operations/releasing.md) |
| GitHub protections and repository settings | [GitHub setup](development/github.md) |
| Hub package inspection and local installation | [Hub](guides/hub.md) |
| Managed harness gateway, hooks, and MCP configuration | [Gateway](reference/agents/gateway.md), [gateway hooks](reference/agents/hooks.md), [MCP configuration](guides/agents/mcp.md) |
| Governed application delivery | [Distributed app delivery](guides/overlays.md) |
| Harness, placement, resource, and credential module contracts | [Harness module](../src/harness/README.md), [placement module](../src/placement/README.md), [native placement](../src/placement/native/README.md), [resources module](../src/resources/README.md), [credentials module](../src/credentials/README.md) |
| Persistence, governance, Hub, Hive, and sync module contracts | [Persist module](../modules/bee-persist/src/README.md), [governance module](../src/governance/README.md), [Hub module](../src/hub/README.md), [Hive module](../src/hive/README.md), [sync module](../src/sync/README.md) |

Use the source module README and tests for implementation details. A contract
describes a callable boundary only when the source and its checks implement it;
unfinished operations remain explicitly marked as proposals.
