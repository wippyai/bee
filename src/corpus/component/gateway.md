# bee.gateway

The authenticated thread port a managed harness child reaches over HTTP on a
host-selected interface. This package holds the authority (bindings, opaque tokens stored only as
hashes, the listener epoch, drain, readiness) and the HTTP handlers; the
listener itself (`http.service`, router, endpoints) belongs to the host
composition. The activation candidate binds native loopback port zero and reads
the assigned address through supervisor state. The production-listener fixture
passes real thread and credential checks on two runtimes. Candidate Agent
profiles declare `thread_read`, `thread_wait`, `thread_message`, the
caller-owned Governance `workspace` tool, and `thread_launch`, which starts one
host-allow-listed managed launch in the caller's own workspace and returns the
child's thread, action and attempt. The host may admit any subset; no default
launch policy advertises `thread_launch` or names an `agent_launch` definition,
so an agent starts another only where the owner has opted in. The
workspace tool also carries a read-only `guide` operation stating this
destination's application authoring contract and one minimal example (derived
from the same rule tables preflight enforces). It can stage and freeze files but
cannot publish or activate them.

The host can explicitly admit `application_open` to open an already admitted
application with literal arguments. Workspace and origin-view identities come
from the authenticated binding, not tool arguments. The workspace host assigns
the new app to that view's display using the existing assignment store; a
headless binding leaves it unassigned. The result carries qualified view and
instance identities for subsequent interaction. Source/pack HTTP and desktop
acceptance includes checkpoint restoration after restart.

The HTTP MCP route bounds each JSON request at 512 KiB. Workspace calls through MCP
accept at most 64 KiB of text or 87,384 bytes of canonical base64 per put
(at most 64 KiB decoded);
larger authoring files require another admitted facade rather than an oversized
gateway request. The underlying Governance workspace keeps its own larger store
limits for non-MCP callers.
All four default profiles include the `thread_message` write. Claude/Codex also declare
lifecycle hooks. Standalone Claude/Codex fixture children pass authenticated
MCP reads, message append/replay and waits; real provider conversations remain
a separate gate. See `docs/GATEWAY.md`.

The default remains `127.0.0.1:0`. A host may explicitly select a loopback or
RFC1918 IPv4 interface for a local container, with its corresponding readiness
permission. The native listener chooses the port; discovery verifies both its
interface and execution identity. MCP and hook requests must name that exact
interface and port in Host. This does not grant network access, enroll another
node, or implement managed Docker execution.
