# Governance authoring and preflight

`bee.governance:preflight` is an internal typed check over a
destination-host-resolved package closure. It has no publication, SQL, network,
approval or process permissions. It is not a package resolver or an
install/update API.

The separate `workspace_call` function is a protected authoring boundary.
It stages caller-owned virtual files and frozen snapshots only. Its
private storage scope is not an agent grant, and the default host supplies no
authoring operation grants, registry publication, or overlay authority.

The ordinary application boundary denies direct access to this store and scope
creation. After checking the caller's exact workspace operation, `workspace_call`
uses the existing named scope `workspace_execution_scope` to call the fixed
`workspace_backend_call` function. That function requires private execution
permission and retains the authenticated actor for ownership checks. Both
requests and replies are decoded. Callers cannot choose the target or scope;
they receive neither storage nor scope-management authority. No new process or
service is involved.

The primary planned consumer activates internal packs/changes in service-owned
ephemeral overlays, without durable registry publication. Agents call a scoped
headless governance trait; they do not receive the owner's writer permissions.
The overlay adapter and agent execution environment are not implemented yet.
Persistent migration ledgers remain required even for ephemeral definitions.

`bee.governance:workspace` now freezes trusted in-memory file records into a
deterministic binary-safe snapshot. It copies records, measures each file's bytes
and SHA-256, hashes a sorted length-framed manifest, and binds workspace identity
and revision. It rejects path traversal, drive/stream paths, duplicate paths,
file/directory collisions and quota overruns (256 files, 240-byte paths, 4 MiB per
file, 16 MiB total). It is not a filesystem server or an authorization boundary;
returned Lua values must be remeasured before execution, not treated as immutable
merely because the helper calls them snapshots.

The source now includes the `bee.governance:workspace_call` function and
`bee.governance:workspace_contract` binding through `workspace_local`, with the
`authoring_trait` agent description. This is private authoring, not activation.
The host admits `bee.governance.workspace.read` (list/read) and
`bee.governance.workspace.write` (create/put/remove/freeze) on exact workspace
IDs. Every operation also checks the stored author against the authenticated
actor; an operation grant does not transfer an existing workspace's ownership.
There are no default authoring grants. The method's protected store policy does
not grant callers direct database or registry/overlay access.
Stored ownership never replaces the current operation grant: a read-only author
cannot write, and a grant for one workspace cannot read another workspace even
when the same actor created both. Requests cannot select an actor, security
scope, store or host path. Service, user and agent scopes are selected by host
admission; loading a trait or restoring saved app data cannot raise that scope.

Requests use `operation` and `workspace_id`. Create uses expected revision zero;
other mutations use the revision returned by list. Mutations and freeze require
`expected_revision` and `idempotency_key`. Put replaces one entire relative file
using either `content` or canonical padded `content_base64`; read returns base64.
Remove deletes one file. Freeze copies the complete measured file set into owned
SQLite storage without changing the edit revision. Later edits cannot change the
stored frozen files. The same retry key and request return the original receipt,
even after subsequent edits or restart; changing the request conflicts.

The host links `target_db`; `BEE_GOVERNANCE_DB` selects the default SQLite path.
Checked migration 1 owns the workspace, files, frozen copies and receipt tables.
Capacity is bounded to eight workspaces per node, two distinct snapshots and 512
mutation receipts per workspace, in addition to the file bounds above. Exhaustion
fails explicitly; there is no eviction, garbage collection or ownership transfer
yet. Frozen content and receipts are durable; they do not imply activation,
approval, or automatic restoration of runtime definitions. This virtual file API
does not mount a host directory or execute WASM. Hive transfer, inbox requests,
plugin dispatch and application migration execution remain unimplemented.

The focused governance Lua suite covers request decoding, bounded binary-safe
snapshots, closed preflight diagnostics, and the protected staging function's
CAS, replay, frozen-copy and author-ownership behavior. It also proves that the
ordinary app store and scope-creation denials are retained while an admitted
app can use the public function; direct private-backend calls refuse.
These checks do not establish restart durability, Hive transfer,
destination approval, application installation, overlays or WASM execution.
The full 16 MiB file-tree boundary is accepted with independent base64 padding
per file; adding another byte refuses without advancing the edit revision.

`make governance-workspace-check WIPPY=/path/to/runtime` runs a
bounded Go acceptance proof against two actual boots of one disposable
`BEE_GOVERNANCE_DB`. It creates, writes and freezes binary content before a
mutable edit; the restart proves the copied frozen bytes and create/write/freeze
receipt replays remain intact, while a separately authorized actor is denied
the exact owner workspace. The same caller keeps its database and scope-creation
denials and cannot invoke the private backend before or after either boot's
public calls. The runner also compares the complete migration
ledger row before and after restart. It does not establish Hive transfer,
destination approval, application installation, overlays or WASM execution.

The host adapter must supply exact artifact/entry/migration measurements,
resolved dependencies and references, final requirement bindings, a coherent
registry/policy snapshot, and the applied migration ledgers for updated packages.
The registry content digest covers the composed state including overlays, not
just the durable history version. The runtime must atomically fence both.
Entry measurements enumerate requested grants and runtime modules from actual
artifact content, including lifecycle/security declarations, not catalog claims.
Each artifact enumerates its exact owned namespaces, including children. A host
namespace allowlist is a ceiling, not evidence that the package owns a namespace.
Remote package descriptions cannot supply this trusted context. Materialized
entry digests cover complete entry content; migration checksums cover the
immutable migration identity/body according to the selected migration adapter.

Diagnostics include remediation guidance, never auto-applied patches. A repair
changes the candidate and requires a new plan/approval. The plan digest binds
destination, base revision, complete candidate and host policy measurement.
Sharing content over Hive does not share a decision or destination authority.

The current runtime fails the durable guarded-publication acceptance gate; this
does not substitute for testing the distinct owner/generation-fenced overlay API.
No production
adapter may claim `guarded_publication` or `exact_expansion` from metadata alone.
No installer, execution worker, activation trait, application migrations runner or remote activation
endpoint is exposed until that boundary is implemented and accepted.
