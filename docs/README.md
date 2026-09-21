# Documentation map

Repository documentation describes the implemented contracts and the boundaries
that keep them safe. Bee also ships a generated, hashed documentation corpus so
managed agents can search those contracts offline; refresh it with the existing
generator when the corpus is intentionally updated.

| Read for | Source |
|---|---|
| Runtime modules and Bee contracts available offline | [Agent documentation corpus](../src/docs/README.md) |
| Running Bee and local development | [Repository README](../README.md), [agent guide](AGENT_GUIDE.md), [development conventions](DEVELOPMENT.md) |
| Ownership and current limits | [System map](SYSTEM_MAP.md), [package boundaries](PACKAGE_BOUNDARIES.md) |
| Contributions and community standards | [Contributing](../CONTRIBUTING.md) |
| Vulnerabilities and credential handling | [Security](../SECURITY.md) |
| Bee visual language and accessible terminal UI | [UI brand book](UI_BRAND_BOOK.md) |
| Desktop, workspace host, client attachments, and layout persistence | [Desktop](DESKTOP.md) |
| Application admission, launch, messages, and recovery | [Application contracts](APPLICATION_CONTRACTS.md) |
| Workspace storage and application state | [Storage](STORAGE.md), [workspace state](WORKSPACE_STATE.md) |
| Threads, Timeline, subscriptions, and delivery | [Threads](THREADS.md) |
| Node metadata, synchronization, and approval inbox | [Sync and inbox](SYNC_AND_INBOX.md), [approvals](APPROVALS.md) |
| Native executable, updates, and I/O events | [Native distribution](NATIVE_DISTRIBUTION.md) |
| Runtime integration and upstream boundaries | [Runtime integration](RUNTIME_UPSTREAM.md) |
| Release artifacts and publication | [Releasing](RELEASING.md) |
| GitHub protections and repository settings | [GitHub setup](GITHUB.md) |
| System ownership and package boundaries | [System map](SYSTEM_MAP.md), [package boundaries](PACKAGE_BOUNDARIES.md) |
| Hub package inspection and local installation | [Hub](HUB.md) |
| Managed harness gateway, hooks, and MCP configuration | [Gateway](GATEWAY.md), [gateway hooks](GATEWAY_HOOKS.md), [MCP configuration](MCP_CONFIGURATION.md) |
| Governed application delivery | [Distributed app delivery](DISTRIBUTED_APP_DELIVERY.md) |
| Harness, placement, resource, and credential module contracts | [Harness module](../src/harness/README.md), [placement module](../src/placement/README.md), [native placement](../src/placement/native/README.md), [resources module](../src/resources/README.md), [credentials module](../src/credentials/README.md) |
| Driver, persistence, governance, Hub, Hive, and sync module contracts | [Driver module](../src/driver/README.md), [persist module](../src/persist/README.md), [governance module](../src/governance/README.md), [Hub module](../src/hub/README.md), [Hive module](../src/hive/README.md), [sync module](../src/sync/README.md) |

Use the source module README and tests for implementation details. A contract
describes a callable boundary only when the source and its checks implement it;
unfinished operations remain explicitly marked as proposals.
