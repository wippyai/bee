# Governance authoring and preflight

Internal typed checks over a destination-host-resolved package closure. The
`hub_resolver` module supplies the internal destination resolution adapter; this
library has no publication, SQL, network, approval or process permissions. It
is not a public install/update API.

The primary planned consumer activates internal packs/changes in service-owned
ephemeral overlays, without durable registry publication. Agents call a scoped
headless governance trait; they do not receive the owner's writer permissions.
The internal overlay materializer now replaces one complete owner-local overlay
from exact decoded artifact entries. `activation_owner` binds the selected plan,
destination-local measurement, local approval, activation ledger and a
host-supplied overlay adapter into a resumable state machine. The destination
service supplies the Hub resolver, fixed approval consumer and boot recovery,
and exposes local workspace-scoped operations. Its application UI and migration
runner are still absent. The agent execution environment is separate.
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

`make governance-workspace-check` proves the public route with distinct actors
and two boots of the same database: binary round trips, denied caller/foreign
ownership, stale and simultaneous CAS writes, exact retry replay, frozen copies
surviving edits/removal, snapshot-capacity refusal and migration persistence.
The focused governance Lua suite passes 16 checks; these tests do not establish
Hive transfer, destination approval or application installation.

`make governance-overlay-check` independently proves ephemeral owner-generation
conflicts, entry ownership and scoped permissions, explicit deletion and unchanged
durable history on the candidate executable. Logical overlay ownership is not
automatic process-exit cleanup. Expanded packages, service readiness and migration
ordering remain unproved by this registry-entry-only fixture.
`bee.governance:materializer` keeps the overlay owner outside transferred data,
copies and remeasures the desired artifact, and deletes definitions no longer in
that owner's complete desired set. It makes one generation-fenced apply attempt.
A conflict returns to the destination owner, which must rebuild its trusted
context and rerun preflight before another attempt. It has no durable registry
publication path. The later destination owner supplies the host-selected owner
identity and approval; callers do not.
The separate `governance-wasm-check` currently fails: the real guest can read a
synthetic outside file through a symlink in a read-only host-directory mount.
Admitted reads, write refusal and parent-traversal refusal alone are insufficient.
Do not enable untrusted host-directory WASM access until this gate passes.

The host adapter must supply exact artifact/entry/migration measurements,
resolved dependencies and references, final requirement bindings, a coherent
registry/policy snapshot, and the applied migration ledgers for updated packages.
Durable publication and overlay activation use distinct conflict boundaries.
Durable publication still needs an atomic composed-base CAS. Overlay activation
may re-resolve and re-preflight immediately before owner-local apply, then rely on
the overlay's owner/generation conflict check; it does not create registry history.
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

The current runtime fails the durable guarded-publication acceptance gate. That
blocks the durable publication adapter, not the distinct owner/generation-fenced
overlay adapter.
No production
adapter may claim `guarded_publication` or `exact_expansion` from metadata alone.
No installer, execution worker, activation trait, application migrations runner or remote activation
endpoint is exposed until that boundary is implemented and accepted.

Migration 5 and `bee.governance:activation_store` provide the internal recovery
ledger only. An immutable intent binds the host-selected overlay owner and exact
plan, artifact, resolution and preflight digests. Approval/consumption progress
is stored separately, and the workspace slot keeps authorized desired state
separate from observed applied state. This store performs no resolution,
approval call or overlay operation.

`bee.governance:activation_owner` prepares and advances that ledger one durable
phase at a time. Before consumption it requires the same current accepted
selection and repeats local resolution/preflight. Once `consuming` is durable,
recovery reconciles the same approval effect because it may already have been
consumed. A verified receipt establishes the desired intent. Later recovery
remeasures that exact intent, restores its absent process-local overlay with
revision-fenced receipts, and never follows a newer plan selection. The
resolver, approval executor, overlay owner, apply and exact-observation functions
remain host-selected inputs; replicated content supplies none of them.

`bee.governance:hub_resolver` now provides the destination resolution adapter.
It captures one atomic registry state, asks the runtime to preview a
host-selected Hub dependency root, reconstructs the complete selected closure
from the previewed final state, and retains definitions absent from the preview
delta. It strips all `ns.dependency` directives before overlay activation.
Registry-owned metadata supplies package ownership. Destination configuration
supplies package, namespace, kind, grant, runtime-module and database ceilings
plus applied migration ledgers. The flattened artifact must equal the reviewed
bytes exactly.

The resolver and destination service are implemented and covered through the
preview adapter. `activation_profiles` supplies host-selected roots, overlay
owners, approval policies and capability ceilings; it cannot be populated by a
remote artifact. The boot worker follows only an already-authorized desired
intent. The preview-capable runtime in runtime PR #752 remains required for
production resolution. Older runtimes can load the pure tests at the dynamic
native seam, but cannot perform production resolution.

Host profiles now select `resolver: hub` or `resolver: overlay`; omitted legacy
values decode as `hub`. The private-overlay resolver consumes exact immutable
Sync artifact definitions and preserves their registry IDs. It assigns package
ownership from the selected local profile, rejects reserved remote `registry`
metadata, Hub dependency directives, namespace/entry collisions and migration
definitions, and passes only the host profile's capability ceilings to
preflight. Existing definitions from the selected destination overlay may be
replaced; definitions outside it remain collision inputs. This mode has no Hub
package provenance and currently supports migration-free applications only.
