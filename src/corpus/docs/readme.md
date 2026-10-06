# Documentation map

The corpus holds the runtime reference pages Bee application authors use, the
contracts of Bee's components, the terminal toolkit and proven reference
applications. Every page is read by stable id through the `docs` tool; the
manifest records each document's topic, size and digest, and `make lint`
checks that they match the files.

| Read for | Documents |
|---|---|
| Working on Bee: layout, make targets, tests | `docs/agent_guide` |
| Component ownership and boundaries | `docs/system_map`, `docs/package_boundaries` |
| Visual language and placement, color and breakpoint rules for application screens | `docs/ui_brand_book`, `docs/app_style` |
| Drawing, layout, styles, input and the application client | `toolkit` |
| Copyable application screens | `reference_apps/index` and one page per application |
| Writing an agent driver for another CLI | `reference_drivers/opencode`, `component/driver` |
| Application admission, launch, messages and recovery | `docs/application_contracts`, `component/app`, `component/app:threads` |
| Delivering an application or driver as a governed overlay | `docs/distributed_app_delivery`, `component/gov` |
| Threads, timeline, subscriptions and delivery | `docs/threads`, `component/threads`, `component/sessions` |
| Managed agents: harness, carrier, gateway, hooks and MCP configuration | `docs/carrier`, `docs/gateway`, `docs/gateway_hooks`, `docs/mcp_configuration`, `component/harness`, `component/gateway` |
| Placement, resources, credentials and drivers | `component/placement`, `component/placement:native`, `component/placement:docker`, `component/resources`, `component/credentials`, `component/driver` |
| Approvals and the approval inbox | `docs/approvals`, `docs/sync_and_inbox`, `component/approvals` |
| Hub package inspection and installation | `docs/hub_inspection`, `component/hub` |
| Node state, sync and the hive | `component/node`, `component/sync`, `component/hive`, `docs/sync_and_inbox` |
| Shared bounds, canonical JSON and reply decoding | `component/values` |
| Stock applications and the application menu | `component/apps:help`, `component/apps:modules`, `component/apps:overlays`, `component/apps:processes`, `component/apps:settings`, `component/apps:terminal`, `component/shell` |
| Environment and resource entries | `component/env`, `component/resources` |
| Lua runtime modules (process, channel, registry, sql, fs, http, tty and others) | `runtime/lua/...` |

Use the component sources and their tests under `src/<component>` and
`tests/lua/<component>` for implementation detail. A contract describes a
callable boundary only when the source implements it.
