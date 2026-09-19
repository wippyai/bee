# Documentation map

The repository Markdown is currently authoritative. Bee does not yet publish a
runtime documentation catalog. A future registry catalog should
package these same pages with status and version, not maintain a second copy.

| Read for | Current source |
|---|---|
| Run and develop | [Repository README](../README.md), [agent guide](AGENT_GUIDE.md) |
| Contributions, reviews and community standards | [Contributing](../CONTRIBUTING.md) |
| Vulnerabilities and credential handling | [Security](../SECURITY.md) |
| What exists and who owns it | [Foundation status](FOUNDATION_STATUS.md) |
| Ordered path from the current checkpoint to Bee v1 | [Finish plan](FINISH_PLAN.md) |
| Code style and placement | [Development conventions](DEVELOPMENT.md) |
| App admission, launch, messages and recovery | [Application contracts](APPLICATION_CONTRACTS.md) |
| Database guarantees | [Storage](STORAGE.md), [workspace state](WORKSPACE_STATE.md) |
| Local journal, Timeline and subscriptions | [Threads](THREADS.md) |
| Node metadata, ledger-backed synchronization and approval inbox | [Sync and inbox](SYNC_AND_INBOX.md) |
| Native binary, update modes and I/O events | [Native distribution](NATIVE_DISTRIBUTION.md) |
| Running the current pack while the global bee is stale | [Fresh pack launch](handoffs/FRESH_PACK_LAUNCH.md) |
| Runtime PRs and removal of local patches | [Runtime upstream work](RUNTIME_UPSTREAM.md) |
| Local artifacts, CI gates and release tags | [Releasing](RELEASING.md) |
| GitHub protections, credentials and repository settings | [GitHub setup](GITHUB.md) |
| Whole-system destination: governed edits, installation plans, sharing and federated inboxes | [System map](SYSTEM_MAP.md) |
| Package seams and native distribution | [Package boundaries](PACKAGE_BOUNDARIES.md) |
| Harness hooks, MCP, sessions and gotchas per coding agent | [Harness inventory](HARNESS_INVENTORY.md) |
| Compose bounded managed Agents on one durable thread and author a reviewed candidate | [Managed autoresearch](AUTORESEARCH.md) |
| Thread record families, delivery rules and driver bindings | [Thread records](THREAD_RECORDS.md) |
| Namespaces, contracts and build order for threads, approvals and drivers | [Component layout](COMPONENT_LAYOUT.md) |
| How overlays and Hub modules add drivers, transports, channels, agents and tools | [Registry extension](REGISTRY_EXTENSION.md) |
| Independent governance implementation plan and runtime admission gate | [Governance implementation](GOVERNANCE_IMPLEMENTATION.md) |
| Exact Hub package inspection and remaining installation gates | [Hub installation](HUB.md) |
| Launch definitions, remote topology, lifecycle states, pause and status | [Launch routing](LAUNCH_ROUTING.md) |
| Docker placement, workspace resources, dependency chain, thread subscriptions | [Placement and subscriptions](PLACEMENT_AND_SUBSCRIPTIONS.md) |
| The ordered build with a proof per step | [Build sequence](BUILD_SEQUENCE.md) |
| Step 2 contract: typed records, thread authority operations, migrations 2 and 3, tests | [Thread authority](THREAD_AUTHORITY.md) |
| Step 3 contract: obligations, claim batches, owner incarnation, subscriptions with pages, waits, recap projection, migrations 4 and 5 | [Thread delivery](THREAD_DELIVERY.md) |
| Step 7: driver contract, binding schema, kit, stream-json transport, Claude and Codex normalizers with captured fixtures | [Driver module](../src/driver/README.md) |
| Step 9, catalog: driver bindings classified per registry generation, activation separate from admission | [Harness module](../src/harness/README.md) |
| Shared migration ledger and SQLite open helper used by threads and placement | [Persist module](../src/persist/README.md) |
| Step 8: placement contract, launch and attempt values, state machines | [Placement module](../src/placement/README.md) |
| Carrier contract: provenance, checkpoint, lifecycle order, control records, epochs, crash points | [Carrier](CARRIER.md) |
| Gateway: authenticated loopback thread port for harness children, bindings, delivery-minted credentials, readiness, drain, real-harness acceptance | [Gateway](GATEWAY.md) |
| Gateway hooks: contract, endpoint adapters, intake lifecycle and carrier integration | [Gateway hooks](GATEWAY_HOOKS.md) |
| Configurable MCP tools, multiple traits, native context and remaining acceptance | [MCP configuration](MCP_CONFIGURATION.md) |
| Agent profiles, per-profile environment and system prompt, Docker placement with the full UI: scheduling proposal | [Profiles and Docker proposal](handoffs/PROFILES_DOCKER_PROPOSAL.md) |
| Step 8: native placement, attempt runner, receipts, homes, measured cleanup capability | [Native placement](../src/placement/native/README.md) |
| Step 6: resource authority, associations under the host ceiling, exactly bound grants, resolve for placements | [Resources module](../src/resources/README.md) |
| Step 6: credential broker, host-admitted sources, environment projections, bytes once to the materializer | [Credentials module](../src/credentials/README.md) |
| Step 9, admission: launch definitions, measured resolution, requester-authenticated admission, retry-safe start | [Harness module](../src/harness/README.md) |
| Historical foundation review and extension proposals | [Foundation review](FOUNDATION_NEXT.md) |
| Cross-node protocol: six terms, request envelope, exposure levels, interfaces, sessions, guards, launch owner, build steps | [Hive protocol](HIVE_PROTOCOL.md) |
| Proposed supervisor peer establishment, replacement and bounded dispatch | [Hive supervisor](HIVE_SUPERVISOR.md) |
| Hive startup work and remaining acceptance | [Hive bootstrap](HIVE_BOOTSTRAP.md) |
| Proposed Hive launch, enrollment and machine/node/workspace topology | [Hive topology](HIVE_TOPOLOGY.md) |
| Proposed durable human approval and distributed inbox projection | [Approvals](APPROVALS.md) |
| Subscription sessions and owner-qualified send | [Thread sessions](THREAD_SESSIONS.md) |

Historical and design references:

- [Platform study](PLATFORM_STUDY.md): source evidence and POC limitations at the study date.
- [Desktop foundation](DESKTOP_FOUNDATION.md) and [local desktop](LOCAL_DESKTOP.md): target architecture, including unimplemented systems.
- [Foundation review](FOUNDATION_REVIEW.md): critique of baseline `ddf6ba8`, before the foundation sweep.
- [UI refinement](UI_REFINEMENT.md): UI design intent; current acceptance tests establish verified behavior.
- [Workspace attachments](WORKSPACE_ATTACHMENTS.md): proposed workspace identity, client layout ownership and local/remote view boundaries.
- [Client/host extraction](CLIENT_HOST_SPLIT.md): current coupling, owner split, appearance scope, migration and acceptance plan.
- [Portable harnesses](PORTABLE_HARNESSES.md): proposed repository-folder and pack execution, headless CI results and selective export.

When these disagree, implemented contracts and their source/tests take precedence
over roadmap prose. Fix the disagreement rather than adding another design page
that silently supersedes it.
