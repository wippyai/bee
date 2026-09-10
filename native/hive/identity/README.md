# Machine identity

This package persists an Ed25519 key pair and derives a stable machine ID.
It is a native enrollment prerequisite; public Bee startup does not use it yet.
Machine identity is distinct from runtime node, Hive and workspace identity.
Protection relies on the OS account; other processes under that account can
access its files.

`OpenOrCreate` delegates cross-process locking, directory/file security validation,
and atomic file publication to `internal/privatefile`. It validates a versioned, bounded
identity document under a stable file lock. Corrupt or insecure existing identities are
refused without key replacement. Cancellation releases lock resources. Private keys are
excluded from normal formatting and JSON output.

On Unix, identity directories must have owner-only permissions. Existing broad
permissions are refused without changing them; the package does not change the
process umask. Files must be regular and owner-only. Lock opens use `O_NOFOLLOW`
and the lock inode is retained. Creation syncs the temporary file before atomic
publication and checks directory sync afterward. A post-publication sync error
reports uncertainty and leaves the published identity intact.

Linux package race tests and vet pass. Windows code has been cross-compiled but
has not been executed on Windows. New directories and locks receive protected
ACLs at creation; existing objects are validated without permission repair.
ACL validation rejects unsupported ACE layouts and foreign principals, and
path checks reject reparse points. Windows tests cover secure creation/reopen
and refusal without ACL repair, but have only been compiled here. Publication
durability still needs platform verification: directory sync is currently a
no-op on Windows. A successful build does not prove execution guarantees.

The package is not yet selected in the public enrollment/launch path. See
[the shared journal](../../../docs/handoffs/JOURNAL.md) for ownership and gates.
