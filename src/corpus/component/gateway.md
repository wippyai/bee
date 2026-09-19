# bee.gateway

The authenticated thread port a managed harness child reaches over HTTP on a
host-selected interface. This package holds the authority (bindings, opaque tokens stored only as
hashes, the listener epoch, drain, readiness) and the HTTP handlers; the
listener itself (`http.service`, router, endpoints) belongs to the host
composition. The activation candidate binds native loopback port zero and reads
the assigned address through supervisor state. The production-listener fixture
passes real thread and credential checks on two runtimes. Candidate Agent
profiles declare `thread_read`, `thread_wait`, `thread_message`, and the
caller-owned Governance `workspace` tool. The host may admit any subset. The
workspace tool also carries a read-only `guide` operation stating this
destination's application authoring contract and one minimal example (derived
from the same rule tables preflight enforces). It can stage and freeze files but
cannot publish or activate them.
The HTTP MCP route keeps its 64 KiB request bound. Workspace calls through MCP
therefore accept at most 8 KiB of text or 48 KiB of canonical base64 per put;
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
