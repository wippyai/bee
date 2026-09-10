# Local admission rendezvous

`client/local` provides local physical-client rendezvous and mutual TLS authentication
for a single runtime owner already holding its exclusive host application-state lock.

## Authority and Boundaries

- **Local Physical-Client Rendezvous Only**: This package authenticates physical clients
  connecting locally to a runtime owner over loopback TCP. It is **NOT** workspace actor admission,
  client capability grants, or cluster membership. Session authorization is granted later by a
  trusted supervisor.
- **OS User Authority**: Protection of the published descriptor relies on native OS user
  filesystem permissions (0700 directories, 0600 files via `internal/privatefile`). Processes
  under the same OS user account are trusted. No false untrusted-shell sandbox claims are made.
- **Prerequisite Host Lock**: Ownership of the runtime host application-state lock is an
  unconditional prerequisite before calling `Start`. This package never acquires, inspects, or
  releases the runtime lock, nor does it invent a second host lock.
- **Rotated Ephemeral Identity**: Each runtime invocation generates a fresh Ed25519 keypair and
  self-signed CA certificate (`localhost`, server+client auth usages). Standard TLS mutual auth
  uses this certificate as trust root and client credential. Stale descriptors from prior runs
  cannot authenticate to a replacement listener.

## Design Invariants

- **Listener Ownership**: `Start` binds `127.0.0.1:0` and retains the underlying `*net.TCPListener`.
  Setup timeout is bounded (5s) even without a caller context deadline. On publication error,
  the listener is closed immediately, preserving `privatefile.PublishedSyncError` uncertainty.
- **Descriptor Retention**: On `Listener.Close`, the descriptor file is intentionally left on disk.
  Unlinking would race a subsequent runtime owner, and stale presence never proves liveness.
- **Single Accept Contract**: `Accept` implements an explicit single-Accept contract guarded
  by an atomic check (`ErrAcceptInProgress`) to prevent global deadline races.
- **Slowloris & Rogue Client Protection**: Handshakes have bounded timeouts (5s) and execute
  concurrently with ongoing accepts up to a bounded cap. Malicious or slow clients cannot
  monopolize the listener.
- **Stop-and-Join Watchers**: Context cancellation unblocks pending accepts and in-flight handshakes
  promptly via `watchCancellation`.
- **Connection Handover**: Admitted connections transfer full ownership to the caller upon return
  from `Accept` and survive setup context cancellation or `Listener.Close`. No per-packet goroutines
  or packet routers exist.
- **Descriptor Validation**: `ParseDescriptor` enforces strict bounded parsing: maximum 16 KiB,
  valid UTF-8, no null bytes, strict JSON token validation (rejects duplicate, unknown, null, or
  missing fields, and trailing bytes), version 1 check, literal loopback endpoint validation,
  and Ed25519 cert/key validation with strict public key correspondence.
- **Zero Secret Leaks**: Errors and string formatters (`String`, `GoString`, `Format`) redact
  private key material.

Root review corrected temporary-queue cleanup, admission cancellation checks,
pre-spawn handshake capacity and the default Dial timeout. Only a connection
actually returned by Accept transfers to its caller; failed setup closes the
underlying transport without a graceful TLS write. Returned connections also
close the socket before TLS cleanup: detach does not wait for the peer to read
a TLS close notification. A real mutual-TLS test covers a peer that stops reading.
The per-run identity has a
ten-year certificate validity so a retained runtime does not stop admitting after
one day; restart rotates the identity. It does not renew certificates in place.

Public Bee does not call this package yet. Runtime lock ownership is a caller
prerequisite; the package does not prove or acquire it. Local OS-user authentication
must still be followed by supervisor-selected desktop/profile admission.
