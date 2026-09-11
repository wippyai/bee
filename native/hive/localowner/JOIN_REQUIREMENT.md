# Local Hive joining runtime requirement

Bee's required behavior is a project node that starts locally when no peer can
be reached, remains usable, and joins the Hive when a valid peer is discovered.
The display and workspace must not wait for network convergence. The native
runtime should own join/rejoin, cancellation and transport cleanup.

## Reproduction

Reviewed runtime `674b58a1a117fa79398f723c4311201cca8472e1` calls
`joinWithRetry(s.ctx, ml)` synchronously in membership `Service.Start` when
`JoinAddrs` is nonempty. The loop retries until a seed responds or the entire
service context expires. The checkout HEAD `1c071948fb` in `~/wippy/wippy`
contains the same code. The public `api/cluster.Membership` exposes inspection
and metadata updates, with no live join/seed-update operation.

A direct Go probe, using real native membership and an unused loopback TCP port,
produced:

```text
seed="" elapsed=31.944503ms context=<nil> start=<nil>
seed="127.0.0.1:38013" elapsed=301.098493ms context=context deadline exceeded
start=failed to join cluster: ... connect: connection refused
```

Source `/tmp/bee-seed-boot-probe-20260911.go`; output
`/tmp/bee-seed-boot-probe-20260911.log`. A 300 ms context deliberately bounds the
probe; it does not represent Bee's proposed node timeout. No runtime code was
changed. Successful local boot and failed seeded boot were both stopped cleanly.

## Needed native behavior

- A host-selected local-first mode must start a usable node without awaiting
  unavailable seeds. Existing deployments may require synchronous joins, so
  their policy must remain explicit.
- Trusted native composition must be able to supply or refresh seed addresses
  after startup. Concurrent local projects have automatically assigned ports;
  neither static addresses nor cached descriptors prove a peer remains live.
- Join attempts and rejoin work must honor cancellation, avoid blocking process
  dispatch or rendering, and release their resources on stop.
- Membership/readiness must remain observable independently of local startup.
  Transport membership must not grant Bee workspace or desktop permissions.

These are required behaviors for the cluster owner to map to native APIs, not
proposed callable method names. Bee should consume that capability rather than
add a second memberlist, a runtime reflection hook, or its own reconnect loop.
Shared same-account TLS and enrollment are implemented separately in Bee;
project-node discovery/activation and full executable acceptance remain pending.
