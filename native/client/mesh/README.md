# Local native mesh client startup

`Local(ctx, LocalConfig, callback)` is a compiled client startup path, gated by
`meshclient`. The native launcher selects the discovery directory and the runtime
TLS certificate/key/CA configuration. Selected TLS never falls back to plaintext.
`SameAccount(ctx, directory, callback)` loads protected execution-bound credentials
from `hive/localtls` after validating loopback discovery and before enrolling the
client. It bounds the client lifetime by credential expiry. Missing or invalid
credentials fail without enrollment, plaintext fallback or owner startup.
Certificate provisioning is available to the lock-held owner bootstrap; public
launcher selection remains unimplemented.
The zero TLS configuration is retained for local mechanism fixtures. It reads an
existing same-account discovery directory, enrolls a fresh random node/signing
identity, and starts Wippy's native membership and internode stack on automatic
loopback ports. It does not start an owner, acquire its application lock, open
application databases or create a Bee transport. A missing descriptor creates
no state. Private signing keys stay in the client process.

The callback runs only after the pinned owner key has authenticated and the
advertised endpoints match the descriptor. The protected descriptor and enrollment
execution are rechecked before the callback. These checks establish a transport
connection; the supervisor must still bind the execution to its admission response,
select a desktop and issue recipient-bound grants. A readable descriptor is not
admission. No application operation is retried by this layer.

This local path accepts only loopback endpoints of the same address family.
Remote invitations and LAN enrollment are separate work. Clients do not enter
Raft's voter set. The startup deadline is disarmed after connection while caller
cancellation remains attached to the transport lifetime. The callback must honor
that context and finish its actor/viewport cleanup before returning.

On every return, the client stops its native stack before removing its exact
execution/node/key enrollment. Cleanup uses a separately bounded context so caller
cancellation does not skip it. Startup, callback and cleanup errors remain visible.
Each client holds an OS-locked enrollment slot. After abrupt process death, the
next holder of that slot reclaims its stale row; live holders are never evicted.
This does not clean up application grants or replace remote process monitoring.

```
make -C native mesh-client-check MESH_RUNTIME=/absolute/reviewed/runtime
```

Race tests and vet cover a separate client OS process authenticating to a live
owner with a generated key, normal and failed-admission cleanup, unchanged owner
lock exclusion, missing-owner behavior, stale-endpoint refusal and transport
lifetime beyond the startup deadline. The subprocess is an acceptance harness,
not the public `bee` command. Production supervisor admission and Bee retained-desktop composition remain
the next integration step.

## Native process and viewport composition

Inside `Local`, `WithActor` starts the runtime's standard native process host and
PID generator, registers the process in topology, and gives the callback its sealed
process frame. That frame has an explicit empty security scope. The host uses one
scheduler worker for this physical client. `actor.go` owns bounded control-message
I/O, `host.go` owns runtime assembly, and `process.go` adapts the scheduler lifecycle.
No fabricated process identity or Lua bootstrap script is used.

A single TTY service shares the connection manager through the runtime's
`internode.NewSurfaceTransport`, also used by standard boot. Actor completion
cancels the callback and retires local viewport handles before releasing its frame.
The callback must finish physical presentation before returning; `WithActor` then
drains its host before `Local` stops networking.

The control inbox retains at most 32 JSON messages of 16 KiB each. At its native
boundary it accepts explicit JSON objects and the Go maps Wippy normalizes from
Lua replies. Map traversal is bounded before encoding; unsupported native values,
cycles, excessive nesting and oversized encoded results are rejected. Conversion
does not authorize a reply; the Hive binding still checks its exact contract. Messages carry
the runtime-established relay sender separately from their JSON body. The actor
accepts only a sender from the enrolled owner node. Production remote admission
requires the runtime to enforce source provenance; current main and the historical
`944736c999` candidate do not establish that guarantee. The earlier
`actor-provenance.patch` enforced it, and the cluster lane must resolve this
native routing boundary before release. No Lua ingress or connection evidence
API is required by Bee. Exact supervisor PID, operation,
execution and request validation still belong to the admission decoder. This is
an inbox bound, not a claim of a host-enforced limit on all upstream network queues.
`Actor.Send` requires cancellable runtime routing. The client runtime candidate
now includes that path from the runtime lane: cancellation stops queue admission,
errors preserve caller ownership, and unknown peers are refused. A discovered
peer may wait for transport registration within the caller deadline. A native
request/reply test verifies the actor sender and payload, and that a canceled
request is not delivered. This is transport acceptance, not supervisor admission.

The combined `mesh-client-check` includes real client actors, post-exit frame and
viewport denial, bounded inbox failure, and two separate OS clients under PTYs.
The physical clients select native mutual TLS, verify the owner-native sender,
render retained content, send a typed key, detach and reattach through
native sockets. Grant files are fixture coordination only; this is not production
supervisor admission or a Bee Terminal/application acceptance test.

The separate unresolved runtime gate is:

```
make -C native mesh-monitor-check MESH_RUNTIME=/absolute/reviewed/runtime
```

It currently fails: a remote monitor call is accepted, a FIFO barrier confirms
later delivery, and the target actor completes, but no EXIT reaches the watcher.
This gate must pass before claiming remote process observation or reliable owner
cleanup of departed controllers. Do not implement the missing monitor protocol
inside Bee. Public launch, supervisor admission, departed-controller cleanup and LAN
acceptance remain incomplete.

## Supervisor discovery

The client loads Wippy's standard EVENTUAL name component before membership
starts, so it participates in the initial native name exchange. Its lifecycle
ends before mesh shutdown; it opens no application registry or workspace store.
`Actor.OwnerSupervisor(ctx)` resolves the existing
`bee.hive.supervisor/<owner-node>` name and validates its node, protected host and
nonempty process identity. It returns an address only. Missing names do not start
an owner, and discovery does not grant admission or terminal rights. The actor's
lifetime and caller cancellation still fence lookups. Public launch is unchanged.

TLS startup failure tests cover invalid certificates and a plaintext owner.
They prove the callback is not entered and protected enrollment is unchanged.

The same-account loopback client sets the existing membership gossip interval to
50 ms so graceful leave does not wait for the default gossip tick. This increases
local gossip frequency; it does not change the owner's profile, failure-detection
contract or remote/LAN defaults. The real-owner composition checks retain normal
membership cleanup and bounded physical-client exit.
