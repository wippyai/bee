# bee.gateway

The authenticated thread port a managed harness child reaches over loopback
HTTP. This package holds the authority (bindings, opaque tokens stored only as
hashes, the listener epoch, drain, readiness) and the HTTP handlers; the
listener itself (`http.service`, router, endpoints) belongs to the host
composition. The activation candidate binds native loopback port zero and reads
the assigned address through supervisor state. The production-listener fixture
passes real thread and credential checks on two runtimes. Candidate Agent
profiles declare the two thread-read tools; Claude/Codex also declare lifecycle
hooks. Standalone Claude/Codex fixture children pass authenticated MCP reads and
waits; real provider conversations remain a separate gate. See `docs/GATEWAY.md`.
