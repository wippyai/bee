# Mesh owner rendezvous

This package publishes public discovery data for a running Bee owner. It reuses
native mesh endpoints; it does not open a listener. The public launcher selects
it for each retained owner.

`Publisher(directory, execution, launch, localAlias)` creates a compiled boot component that depends
on the native cluster. Select it only for the owner launch holding the runtime
application-state lock. After cluster startup it captures the local membership
address, retained internode endpoint, node ID and public key, and writes
`mesh-owner.json` in a private discovery directory. The execution ID must be a
fresh 16-byte value encoded as 32 hexadecimal characters for each owner run.

`New(directory).Read(ctx)` reads the descriptor without creating directories,
taking the application-state lock, or opening registry/workspace databases. The
4 KiB boundary rejects unknown, duplicate, case-aliased, missing and null fields.
Endpoints must be literal unicast or loopback IP addresses with nonzero ports;
DNS-only advertisements and scoped IPv6 addresses are currently unsupported.
The public key is an Ed25519 key, not an enrollment credential.

Publication uses the existing private-file lock, atomic rename and sync behavior.
Only the owner holding the application-state lock may call `Publish`. Existing
bounded discovery data may be replaced on a new run, even if its contents are
corrupt: it is ephemeral discovery state, not an application migration ledger.
Filesystem permission errors and uncertain publication propagate unchanged.

Shutdown leaves the descriptor in place. A stale descriptor proves no liveness;
deleting it could race a replacement owner. Clients must authenticate the live
peer, check the execution through owner admission, and obtain fresh desktop
grants. Discovery never authorizes cluster membership, desktop control or a
workspace operation. Enrollment secrets and private signing keys are kept out
of the descriptor. Protection relies on OS-user file authority.

Run `make -C native rendezvous-check RENDEZVOUS_RUNTIME=/path/to/runtime` against
the runtime client integration branch. It tests strict decoding, atomic reads,
failure preservation, and publication from a real native mesh stack while the
runtime application-state lock is held. It proves the published port is retained
and later released, and that client reads preserve owner exclusion. Dependencies
are resolved through a temporary module file. This is not yet a separate-process
desktop attachment or remote enrollment acceptance check.

## Local bootstrap enrollment

`NewEnrollment(directory)` opens a separate protected `local-enrollment.json`
store. The native owner calls `Initialize(ctx, execution, secret)` while holding
the runtime application lock, before publishing discovery. This stores the
current execution's 32-byte gossip key and an initially empty set of approved
client public keys. A retry with the same execution and key preserves approvals;
a different key under the same execution is rejected. A fresh execution replaces
the old bootstrap record. Private signing keys never enter this file.

Local clients have the same OS-user file authority as the owner. They generate a
fresh runtime node ID and signing key for each client process, then call
`Register` with the execution read from discovery. An identical retry succeeds;
a different key for the same node conflicts. The returned snapshot supplies a
copied gossip key. Snapshots redact secrets under formatting. `Remove` requires
the matching execution, node and public key, so delayed cleanup cannot remove
a replacement owner's record or a different client's key.

The owner supplies `Resolve(ctx, execution, node)` to the native runtime peer-key
source. It re-reads and validates the bounded local record for each new handshake,
failing closed on missing, corrupt or replaced state. This performs local file
I/O during authentication; there is no idle polling, watcher-based authority,
network request or per-packet file lookup. OS filesystem calls are not claimed
to be preemptible by the context. Existing authenticated connections and desktop
grants need separate owner retirement when a client ends.

Enrollment is bounded to 128 local client identities and a 64 KiB record.
Native clients use `RegisterHeld` and retain its lease until transport shutdown.
Each lease holds one of at most 128 stable OS lock files. Process death releases
the lock; the next holder removes only the stale row assigned to that slot.
Live slots and unmanaged `Register` entries are never evicted. Version 2 adds
slot metadata; version 1 records remain readable and upgrade on mutation while
preserving their unmanaged keys. A killed-subprocess test proves reclamation
preserves live and unmanaged peers. Application-grant cleanup and public client
lifecycle integration remain required before activation. This mechanism applies to
same-account local bootstrap only. Remote invitations and persistent machine
enrollment are separate, and transport enrollment never grants terminal access.

The live integration test starts two native stacks with the same gossip secret,
proves that the unregistered key is denied, registers it through this store, and
observes authenticated connection without owner restart. Removal denies the next
key lookup. It does not claim that removal closes the established connection.

## Shared local Hive enrollment candidate

`EnsureShared` creates one protected enrollment epoch and gossip key for the
local Hive. Subsequent calls preserve the epoch, key and all peer registrations;
malformed existing state refuses rather than resetting other nodes. This is
same-account bootstrap authority, not a live topology or workspace permission.
The current project-node launcher has not yet wired this shared enrollment.

The existing held-slot registration also supports a stable project node name
after process death. It first tries that name's recorded slot and can replace
its stale row only after acquiring the released OS lock. A live holder still
refuses replacement, and exact key/slot cleanup fences a previous holder from
removing the replacement. This reuses the existing bounded lease mechanism.
Concurrent initialization, peer preservation, malformed records, live-node
refusal, released-slot reuse and stale cleanup are covered by the rendezvous
race suite alongside the existing subprocess-death tests.
