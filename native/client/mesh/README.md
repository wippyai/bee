# Native mesh client join

`Joined(ctx, JoinConfig, callback)` is the one client join, gated by
`meshclient`. The launch route selects the owner's rendezvous directory, the
owner-seeded enrollment, the identity it enrolled for this client and the
owner's mesh credential (`hive/meshtls.Config`). The owner and its local clients
share that credential as one OS account; selected TLS never falls back to
plaintext. Native node identity stays with the pinned Ed25519 keys: the client
trusts only its own key and the descriptor's owner key.

The join reads the descriptor and accepts only loopback endpoints of one address
family, refuses an identity the enrollment does not list with this key, and
starts Wippy's native membership and internode stack on automatic loopback
ports. The callback runs only after the pinned owner key has authenticated and
the advertised endpoints match the descriptor; the descriptor endpoints and the
enrollment are then read again, and any change refuses the join. These checks
establish a transport connection; the supervisor still admits every operation.
The startup deadline is disarmed after connection while caller cancellation
remains attached to the transport lifetime. The join never starts an owner,
acquires its application lock, opens application databases or writes the
enrollment; enrolling and retiring the client belong to the launch route.
Clients do not enter Raft's voter set, and their loopback gossip cadence keeps
their departure prompt. A client advertises member metadata `bee.role=client`,
so the owner's Hive Manager marks it as a display client and replica
distribution skips it; the metadata describes the node and grants nothing.

TLS failure tests cover invalid, missing and plaintext-owner credentials; they
prove the callback is not entered and the enrollment is unchanged.

## Owner endpoint

`OpenEndpoint(ctx, host)` registers a native host inside a running node through
the runtime's owned-host registration and returns an endpoint with bounded JSON
send and receive, like the physical-client actor. The owner's join listener uses
it on `bee.hive:join_host` to redeem invites with its own supervisor, which
admits redemption only from that host on its own node.

## Native process and viewport composition

Inside `Joined`, `WithActor` starts the runtime's standard native process host and
PID generator, registers the process in topology, and gives the callback its sealed
process frame. That frame has an explicit empty security scope. The host uses one
scheduler worker for this physical client. `actor.go` owns bounded control-message
I/O, `host.go` owns runtime assembly, and `process.go` adapts the scheduler lifecycle.
No fabricated process identity or Lua bootstrap script is used.

A single TTY service shares the connection manager through the runtime's
`internode.NewSurfaceTransport`, also used by standard boot. Actor completion
cancels the callback and retires local viewport handles before releasing its frame.
The callback must finish physical presentation before returning; `WithActor` then
drains its host before `Joined` stops networking.

The control inbox retains at most 32 JSON messages of 16 KiB each. At its native
boundary it accepts explicit JSON objects and the Go maps Wippy normalizes from
Lua replies. Map traversal is bounded before encoding; unsupported native values,
cycles, excessive nesting and oversized encoded results are rejected. Conversion
does not authorize a reply; the Hive binding still checks its exact contract.
Remote packages carry the logical relay sender separately from `IngressNode`.
The pinned runtime sets `IngressNode` from the authenticated internode connection
and does not encode it on the wire. The actor accepts only packages whose ingress
is the enrolled owner node, then preserves the logical sender for the Hive
decoder's exact supervisor PID check. An integration test sends a different
logical sender through the owner transport to verify this boundary. No Lua
connection evidence API is required by Bee. Exact supervisor PID, operation,
execution and request validation still belong to the admission decoder. This is
an inbox bound, not a claim of a host-enforced limit on all upstream network queues.
`Actor.Send` requires cancellable runtime routing. The client runtime candidate
now includes that path from the runtime lane: cancellation stops queue admission,
errors preserve caller ownership, and unknown peers are refused. A discovered
peer may wait for transport registration within the caller deadline. A native
request/reply test verifies the actor sender and payload, and that a canceled
request is not delivered. This is transport acceptance, not supervisor admission.

`make native-client-check` runs the public client acceptance, builds the compiled
Hive client fixture and exercises its calls against a retained owner. The Lua
desktop-enrollment tests cover admission of the configured client host and
rejection of other hosts. The compiled fixture is disposable acceptance code;
it does not grant itself owner admission.

The same target runs `TestNativeRemoteMonitorMustObserveClientActorExit` with
`meshclient,meshmonitorproof`. That required release acceptance still fails
because the pinned runtime sends no remote EXIT after a client actor completes.
Keep remote release blocked until the runtime monitor protocol reports that
exit. Public remote process observation and reliable owner cleanup of departed
controllers therefore remain incomplete.

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
