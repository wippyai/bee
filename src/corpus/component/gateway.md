# bee.gateway

The gateway is the authenticated MCP and hook port a managed agent reaches over
HTTP. It owns bindings, opaque tokens stored only as hashes, the listener epoch,
drain, readiness, the tool catalog and the HTTP handlers. Caller identity travels
only in the authenticated call context, never in a payload. Granting a tool,
trait or approval is always an owner decision; registry metadata grants nothing.

## Listener

`bee.gateway.api:gateway_listener` (`http.service`) binds `127.0.0.1:0`; the
native listener chooses the port and discovery reads the assigned address from
supervisor state (`bee.gateway.api:gateway_endpoint`, `bee.gateway.binding:address`).
Routes on `gateway_router`: `GET /ready`, `POST /mcp/:action`, `POST /hook/:action`,
`GET /hook/:action/:event` and `POST /hook/:action/mcp`. MCP and hook requests
must name the exact interface and port in `Host`. A host may select a loopback
or RFC1918 IPv4 interface for a local container, with its readiness permission.
A request body is bounded at 512 KiB.

## Tools

The MCP server is `bee` (protocol `2025-06-18`, `tools/list`, `tools/call`).

| Tool | Purpose |
|---|---|
| `session_catalog`, `session_open`, `session_run`, `session_send`, `session_await`, `session_join`, `session_get`, `session_list`, `session_cancel`, `session_close` | One method each of `bee.threads.sessions:contract` and `:catalog` (see [sessions](sessions)). They are the way to start an agent, give it work and read its result. Arguments are the published closed schemas; every mutation requires `operation_key`; the gateway keeps no session state and each owner reply is held to the published output schema |
| `thread_read`, `thread_message` | Read the bound thread (or a member thread the caller belongs to); record a note on it that schedules nothing |
| `capabilities` | Read-only report of the admitted tools with their policies, the traits, the bound workspace and thread |
| `overlay` | Caller-owned Governance overlay: a read-only `guide` (index, sections, worked example) and create, list, read, put, append, remove, freeze. A `put` carries at most 64 KiB of text or 87,384 bytes of base64 |
| `docs` | Offline platform documentation: list by topic, search, and read bounded windows by stable id |
| `components` | Read-only inspection of installed components, Hub packages and installation plans |
| `delivery` | `preflight`, `request` and `status` for a frozen overlay pack; names the human steps it cannot take (review in Overlays, approval in Approvals) |
| `publish` | Publishes the exact application version a person has reviewed, approved and applied at this destination |
| `application_open` | Opens an already admitted application with literal arguments; workspace and origin view come from the binding |
| `request_capability`, `capability_status` | Ask the person to elevate one attempt with one host catalog capability for a bounded time; approval consumption writes one Resources grant for that thread actor, which the attempt's placement resolves and no child inherits |
| `install_request`, `uninstall_request`, `install_status` | File and poll Hub installation requests |
| `publish_request`, `publish_status` | File and poll Hub publication requests |
| `session`, `call_tool` | `session` reads or selects traits and requests host-declared access (`request_access`, `access_status`); `call_tool` calls a currently active tool by name |

The host may admit any subset. Each built-in tool runs under a policy the host
links through `bee.gateway.env` references (`tool_session_policy_ref`,
`tool_read_policy_ref`, `tool_message_policy_ref`, `tool_overlay_policy_ref`,
`tool_docs_policy_ref`, `tool_components_policy_ref`, `tool_delivery_policy_ref`,
`tool_publish_policy_ref`, `tool_application_open_policy_ref`,
`tool_install_policy_ref`, `tool_hub_publish_policy_ref`). Configured component tools
join the built-ins at admission, and `catalog.from_framework` projects an admitted
agent closure's function tools and traits: each function id becomes one MCP tool
under its `llm_alias`, with no authority of its own.

## Approvals and effects

Elevation, trait access, installation and publication file one thread-bound
approval with the approvals owner and share `subject_call`, which runs owner calls
as the binding's subject under an explicit policy set and consumes an approved
decision exactly once under one effect key. Filing grants nothing.
Installation resolves the exact Hub plan with Hub read authority only;
`gateway_installation_service` applies the approved plan with the approved digest and
replays Hub's idempotent operation after an uncertain call. Publication seals the
source tree into one pack file with Hub management authority; after approval
`gateway_publication_service` re-measures the file and uploads it only when the
Hub-reported digest equals the approved pack digest. Trait access is recorded as
the shared `mcp.access` capability scoped to the binding
(`bee.capability:model` checks the scope and builds the revocation report).
The approval policies come from `bee.gateway.env:install_configuration_ref` and
`publish_configuration_ref`; an absent approval link fails closed.

## Hooks and profile scopes

Hook endpoints carry `bee.gateway.security:session_boundary_policy`. Delivery runs
as the authenticated binding's SessionRef; Sessions checks identity, workspace and
the current native attempt before journaling a turn or answering a permission
request. Saved profile MCP scopes are checked after argument decoding for every
direct or `call_tool` call: `methods` bounds the owner target, `operations` the
decoded operation, and definition scopes inspect nested Session specs. Profile file
grants are attempt-bound Resources records carried privately in the frozen surface
and resolved again before dispatch; their expiry, revocation or replacement
refuses the call.

## Namespaces

| Namespace | Content |
|---|---|
| `bee.gateway` | `protocol` values |
| `bee.gateway.env` | Resource references, tool policy references, hook executable |
| `bee.gateway.catalog` | Tool catalogs, schemas, session bundle and profile scope values |
| `bee.gateway.hooks` | Hook payload normalization |
| `bee.gateway.api` | MCP protocol library (`mcp`), HTTP handlers, listener, router and endpoints |
| `bee.gateway.binding` | Lifecycle, hook, effect and request operations (`open`, `admit`, `seal`, `materialize`, `revoke`, `address`, ...) |
| `bee.gateway.persist`, `.migrations` | Binding, credential, hook, listener and surface stores and their migrations |
| `bee.gateway.security` | Policies and the approval, installation and publication libraries |
| `bee.gateway.service` | The `worker` and `publication_worker` processes |
