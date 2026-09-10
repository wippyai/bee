# Same-account native TLS credentials

`Prepare(ctx, directory, execution, expires)` provisions the local owner's native
mesh TLS credential. Call it under the real application-state lock, before stack
assembly, enrollment initialization and rendezvous publication. It creates no
listener and adds no transport. The public launcher is not wired to it yet.

One protected PEM bundle holds a fresh self-signed certificate and independent
Ed25519 TLS key. The runtime uses that same file for its certificate, key and
trust anchor. The certificate permits client/server TLS on `127.0.0.1` and `::1`.
It is directly trusted, does not sign other certificates, and is not a LAN
credential. Its key is separate from the native node signing key.

The owner and thin clients share this credential because they run under the
same OS account. This establishes possession of an owner-only local credential;
it does not identify individual Bee actors. Native signed-node enrollment still
pins each peer's separate identity. Destination supervisor admission still selects
desktops, permissions and recipient-bound grants. No TLS subject grants authority.

Files are named by the exact owner execution, published atomically with the
existing private-file primitive, and never overwritten for a different execution.
Same-execution retries preserve the original key and expiry. Missing reads create
no state; insecure, malformed, copied-to-another-execution and expired credentials
fail without repair. Old files are retained; garbage collection is not implemented.
No absolute paths or private keys are added to the discovery descriptor.

`Load(ctx, directory, execution)` returns `Credentials{TLS, ExpiresAt}` after a
protected read and validation. `mesh.SameAccount` calls it only after validating
loopback discovery and before mutating client enrollment. The native runtime still
loads the selected files itself; immutable execution filenames avoid owner-restart
replacement races. Same-account native programs retain ordinary OS-user authority.

Expiry is host-selected, finite, and at most 30 days away. Prepare returns the
actual retained expiry on retry. The owner must stop its mesh by `ExpiresAt` and
start a fresh execution for renewal; that public owner lifecycle is not implemented.
Certificate expiration alone does not revoke established connections.
`mesh.SameAccount` bounds the client context by the credential expiry. It has no
plaintext fallback and does not generate credentials or start an owner.

```
make -C native local-tls-check MESH_RUNTIME=/absolute/reviewed/runtime
make -C native mesh-client-check MESH_RUNTIME=/absolute/reviewed/runtime
```

The first checks storage, expiry, execution isolation and certificate validation.
The package requires the `meshclient` build tag and an explicit runtime checkout.
Public owner startup and automatic attachment remain unwired. The native mesh
checks are component proofs, not evidence of public Hive activation.
