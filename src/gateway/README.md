# bee.gateway

The authenticated thread port a managed harness child reaches over HTTP on a
host-selected interface. This package holds the authority (bindings, opaque tokens stored only as
hashes, the listener epoch, drain, readiness) and the HTTP handlers; the
listener itself (`http.service`, router, endpoints) belongs to the host
composition. The activation candidate binds native loopback port zero and reads
the assigned address through supervisor state. The production-listener fixture
passes real thread and credential checks on two runtimes. Candidate Agent
profiles declare `thread_read`, `thread_wait` and the explicitly admitted
`thread_message` write in all four default profiles. Claude/Codex also declare
lifecycle hooks. Standalone Claude/Codex fixture children pass authenticated
MCP reads, message append/replay and waits; real provider conversations remain
a separate gate. See `docs/GATEWAY.md`.

The default remains `127.0.0.1:0`. A host may explicitly select a loopback or
RFC1918 IPv4 interface for a local container, with its corresponding readiness
permission. The native listener chooses the port; discovery verifies both its
interface and execution identity. MCP and hook requests must name that exact
interface and port in Host. This does not grant network access, enroll another
node, or implement managed Docker execution.
