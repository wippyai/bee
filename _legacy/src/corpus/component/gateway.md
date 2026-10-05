# bee.gateway

`bee/gateway` owns the authenticated thread port a managed harness child
reaches over HTTP. It owns bindings, opaque tokens stored only as hashes, the
listener epoch, drain, readiness, and HTTP handlers. The listener itself
(`http.service`, router, and endpoints) belongs to the host composition. The
activation binds native loopback port zero and reads the assigned address
through supervisor state. Agent
profiles declare `thread_read` and `thread_message` (read the transcript, and
record a note on it that schedules nothing), the ten `session_*` tools, the
caller-owned Governance `overlay` tool, offline `docs`, read-only `components`
and `capabilities`, and application `delivery`. These normal window policies
also serve saved headless sessions. Hidden research batch policies expose only
the session and thread tools. Other tools below require separate host admission. The
`session_catalog`, `session_open`, `session_run`, `session_send`,
`session_await`, `session_join`, `session_get`, `session_list`,
`session_cancel` and `session_close` tools project the `bee.sessions:contract`
and `bee.sessions:catalog` owner contracts one method each; they are the only
way to start an agent, give it work (`session_send`) and read its result
(`session_await`). Arguments are the published closed schemas; every mutation
requires `operation_key`; caller identity travels only in the authenticated
call context, never in a payload; the owner binding opens under the host-linked
`target_tool_session_policy`, and each owner reply is held to the published
output schema. The gateway keeps no session state. `session_open` and `session_run` accept
`spec.presentation = "headless" | "window"`, defaulting to `headless`. Window
sessions receive Work through driver hooks and retain their terminal when the
person closes the viewer. Snapshots expose the selected `presentation`.
The host may admit any subset. The
overlay tool also carries a read-only `guide` operation stating this
destination's application authoring contract and one minimal example (derived
from the same rule tables preflight enforces). It can stage and freeze files but
cannot publish or activate them.

The host can explicitly admit `application_open` to open an already admitted
application with literal arguments. Workspace and origin-view identities come
from the authenticated binding, not tool arguments. The workspace host assigns
the new app to that view's display using the existing assignment store; a
headless binding leaves it unassigned. The result carries qualified view and
instance identities for subsequent interaction.

A binding may also admit `request_capability` and `capability_status`. An
elevation request asks the person for one host catalog capability with bounded
parameters and a TTL; the approval shows the catalog's own wording bound to the
authenticated thread and attempt. Consuming it writes one resources grant for
that thread actor, which that attempt's placement resolves and no child attempt
inherits. A request is measured and checked for a realizable resource grant
and a present association with sufficient access before an approval is filed.
The association is checked again before an approved decision is consumed. A
replay returns the same grant; the binding's own surface policy selects the
approver. Filing the request grants nothing.

MCP `request_access` records the approved traits as the shared `mcp.access`
capability scoped to that binding. The gateway keeps the approval and trait
receipt in its own store; the shared capability model checks the scope and
formats the revocation report.

`install_request`, `uninstall_request` and `install_status` file and poll Hub
installation requests the same way. The gateway resolves the exact Hub plan as
the bound subject with Hub read authority only, and files one thread-bound
approval under the approval policy the host's `target_install_configuration`
entry names. An owner worker reads approved installation effects from the
approvals owner and resolves each proposal's binding ID through the gateway
owner, then checks the host-selected policy and persisted attempt context before
consuming the decision and calling Hub apply with the approved digest. Consumed
requests stay in the owner's queue until its bounded applied or terminal outcome
is recorded; restarting the worker replays Hub's idempotent operation after an
uncertain call. Hub retains the complete receipt, and status polling returns its
recorded state and message even if the asking session ended. Elevation, MCP
access and installation share `subject_call` for subject-bound owner calls and
approval consumption.

`publish_request` files Hub publication requests and the read-only
`publish_status` reports them. The gateway seals the admitted source tree into
one worker-owned pack file with Hub management authority, then files one
thread-bound approval showing module, version, pack digest, visibility,
organization and source under the approval policy the host's
`target_publish_configuration` entry names. Once the person approves, the
approval commit wakes the publication effect worker, which consumes the
decision and uploads exactly the sealed file; the file is re-measured first
and the Hub-reported digest must equal the approved pack digest. Hub retains
the receipt with the pack digest beside the Hub digest.

The HTTP MCP route bounds each JSON request at 512 KiB. Overlay calls through MCP
accept at most 64 KiB of text or 87,384 bytes of canonical base64 per put
(at most 64 KiB decoded);
larger authoring files require another admitted facade rather than an oversized
gateway request. The underlying overlay store keeps its own larger
limits for non-MCP callers.
All four default profiles include the `thread_message` write. Claude/Codex also
declare lifecycle hooks. Both HTTP hook endpoints carry the exact
`bee.gateway.security:session_boundary_policy` call grant alongside its policy
resolver. Delivery runs as the authenticated binding's SessionRef; Sessions
checks that identity, workspace and current native attempt before journaling a
turn or answering a permission request.

The default remains `127.0.0.1:0`. A host may explicitly select a loopback or
RFC1918 IPv4 interface for a local container, with its corresponding readiness
permission. The native listener chooses the port; discovery verifies both its
interface and execution identity. MCP and hook requests must name that exact
interface and port in Host. This does not grant network access, enroll another
node, implement managed Docker execution or establish provider conversation
recovery.

## Host composition

A host composes `bee/gateway` and selects its database, listener, endpoint
configuration, and harness executable storage. It may also select the approval
request and consume policies and the policies for each built-in MCP tool. An
absent approval link fails closed. The selected endpoint describes a destination;
it does not grant network authority.

The host creates the HTTP service, router, and endpoint routes that call the
component's API functions. It also selects the policies that permit callers to
use those functions and the policies a bound tool receives. Requirements and
registry metadata describe those links; they never grant authority by
themselves.

## Namespaces

`bee.gateway` declares the component, dependencies and host requirements, and
exports the shared `protocol` values. Resource references, database configuration
and the hook-executable entry live in `bee.gateway.env`. Tool catalogs, schemas
and profile scope values live in `bee.gateway.catalog`; hook normalization lives
in `bee.gateway.hooks`.

The callable lifecycle and hook operations are in `bee.gateway.binding`; the
HTTP handlers are in `bee.gateway.api`; and endpoint lookup is
`bee.gateway.binding:address`. `bee.gateway.migrations`,
`bee.gateway.persist`, `bee.gateway.security`, and `bee.gateway.service` contain
the component's migration, storage, authorization, policy and background worker
implementation. The host-owned listener, router and routes are composed beside
the handlers in `src/gateway/api`.

The `catalog.from_framework` projection exposes an admitted agent closure's
selected function tools and traits through the gateway: each function id
becomes one MCP tool under its `llm_alias` adapter alias with its input
schema, and each trait keeps its prompt with those aliases. The alias carries
no authority; the host supplies one policy list per function id, and
selection still refuses any tool outside the admitted ceiling.

Saved profile MCP scopes are checked after argument decoding for every direct or `call_tool` call. `methods` bounds the owner target, `operations` bounds the decoded operation, and definition scopes also inspect nested Session specs. Profile file grants remain attempt-bound Resources records, carried privately in the frozen surface and resolved again before dispatch. Capabilities reports the admitted references; the protected `bee.gateway.binding.resource_grants` call context carries them to host-selected owner tools. Session/work references also undergo destination-operation checks, including peer sends and joins. Their expiry, revocation or replacement refuses the call; profile metadata never creates a tool policy or owner permission.
