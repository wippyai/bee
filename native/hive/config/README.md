# Machine configuration

This native store persists remembered workspace locations and a typed Hive
profile in protected `config.json`, using the stable `.config.lock` companion.
The host supplies the directory. The public launcher reads this profile before
native cluster assembly. A missing document keeps the local-only launch path;
malformed saved configuration fails visibly and is never replaced.

`New` creates no files. `Read` returns a validated document; missing configuration
returns `os.ErrNotExist` without creating anything. `Update` checks an expected
revision while holding the private-file lock. A concurrent stale writer receives
`ErrConflict` and must read again before deciding how to retry. The callback may
change content, but the store owns schema version and revision. Callback errors
and publication uncertainty propagate to the caller.

Version 1 stores `version`, `revision`, `hive` and `workspaces`. A Hive profile is
either `{"mode":"local"}` or a joined profile. Joined profiles contain stable
Hive and runtime node IDs, up to 16 seed host/port addresses, a 32-byte
base64-encoded membership secret, a base64-encoded Ed25519 private key, and an
authoritative map of peer IDs to base64-encoded Ed25519 public keys. The peer map
must include the local node and its key must match the private identity. TLS
certificate, key and CA paths must be absolute, clean paths.

Membership and internode bind hosts and ports are explicit; bind port zero is
allowed for automatic selection. Optional advertise host/port pairs must be
complete, use a nonzero port, and match an explicitly selected bind port. Seed
addresses require a concrete host and nonzero port. Unknown, duplicate, missing,
null and case-aliased JSON fields are rejected. Existing corrupt state is left
unchanged. Joined credentials are held in the owner-only private config and are
redacted when Go values are formatted; same-account processes share OS-user
authority, so this is not an application sandbox.

Each workspace location has `workspace_id`, `project_dir` and
`runtime_state_dir`. Several project directories may select one workspace, and
several workspace IDs may share a runtime state directory. That directory locates
registry/deployment storage; it is not a workspace database binding or
permission. Paths must be absolute and cleaned. Reading the index does not
require remembered directories to be available.

Documents are bounded to 4 MiB and 4,096 location entries. Run
`make -C native hive-config-check` for this package's race tests and vet.
Configuration tests cover concurrent revision conflicts, corruption preservation,
local/joined profile validation, bounds, reopened state, independent snapshots
and multiple workspaces sharing a runtime.
OS-user protection and directory-sync limitations are those of
[`privatefile`](../../internal/privatefile/README.md).

Joined startup retains the saved runtime node ID, signing key, membership secret,
peer keys, seed addresses and bind/advertise settings. Seed joining retries under
the runtime membership lifecycle, so an unavailable seed does not delay local
startup. The owner snapshots its selected TLS files into the execution-specific
rendezvous directory and publishes loopback aliases for same-machine physical
clients; those clients still need supervisor admission. Tests boot two ordinary
owner subprocesses from saved profiles, start the seed late, prove membership and
internode name propagation, restart the joiner without changing its identity, and
attach a separate local display through the same native mesh.

There is no public invitation or profile-writing command yet. Version 1 also has
one runtime node identity per saved machine profile, so it does not yet model
several simultaneous joined project runtimes on one machine.
