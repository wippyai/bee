# bee.gateway

The authenticated thread port a managed harness child reaches over loopback
HTTP. This package holds the authority (bindings, opaque tokens stored only as
hashes, the listener epoch, drain, readiness) and the HTTP handlers; the
listener itself (`http.service`, router, endpoints) belongs to a managed host
composition and is absent from the default desktop. See `docs/GATEWAY.md`.
