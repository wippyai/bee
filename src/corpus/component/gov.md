# Overlay authoring and preflight

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
and exposes local workspace-scoped operations. Migration-enabled activation now
captures exact work and runs it behind a prerequisite overlay before the full
application overlay becomes visible. The agent execution environment is separate.
Persistent target ledgers remain authoritative even for ephemeral definitions.

`bee.governance:workspace` now freezes trusted in-memory file records into a
deterministic binary-safe snapshot. It copies records, measures each file's bytes
and SHA-256, hashes a sorted length-framed manifest, and binds workspace identity
and revision. It rejects path traversal, drive/stream paths, duplicate paths,
file/directory collisions and quota overruns (256 files, 240-byte paths, 4 MiB per
file, 16 MiB total). It is not a filesystem server or an authorization boundary;
returned Lua values must be remeasured before execution, not treated as immutable
merely because the helper calls them snapshots.

The source now includes the `bee.governance:overlay_call` function and
`bee.governance:overlay_contract` binding through `overlay_local`, with the
`authoring_trait` agent description. This is private authoring, not activation.
The managed Agent gateway admits `bee.governance.overlay.read` (list/read) and
`bee.governance.overlay.write` (create/put/remove/freeze) only through this
facade. Every operation also checks the stored author against the authenticated
actor; an operation grant does not transfer an existing overlay's ownership.
The method's protected store policy does not grant callers direct database,
publication, approval, activation or registry/overlay access.

Public requests use `operation` and `overlay_id`; `guide` is the only operation
that carries no overlay identity, and `workspace_id` is rejected on this
surface. The private store translates the public identity to `workspace_id`.
Create uses expected revision zero;
other mutations use the revision returned by list. Mutations and freeze require
`expected_revision` and `idempotency_key`. Put replaces one entire relative file
using either `content` or canonical padded `content_base64`; read returns base64.
Remove deletes one file. Freeze copies the complete measured file set into owned
SQLite storage without changing the edit revision. Later edits cannot change the
stored frozen files. The same retry key and request return the original receipt,
even after subsequent edits or restart; changing the request conflicts. Replies
expose `overlay_id`; the private storage and execution boundary continues to use
its internal `workspace_id`.

For an application candidate, the author writes `entries.json` as a plain JSON
list of complete registry entries and freezes it with the other source files.
The publication preparation service parses that exact frozen file and uses
`bee.governance:artifact` to create the canonical measured envelope. It executes
no code and does not mutate the overlay or frozen snapshot.

The host links `target_db`; `BEE_GOVERNANCE_DB` selects the default SQLite path.
Checked migration 1 owns the private workspace rows, files, frozen copies and
receipt tables. Capacity is bounded to eight overlays per authenticated author
and 64 per node, 16 distinct snapshots and 512 mutation receipts per overlay,
in addition to the file bounds above. One Agent therefore cannot consume every
authoring overlay slot on the node. Exhaustion fails explicitly; there is no
eviction, garbage collection or ownership transfer yet. Frozen content and
receipts are durable; they do not imply activation,
approval, or automatic restoration of runtime definitions. This virtual file API
does not mount a host directory or execute WASM. Hive transfer, inbox requests,
plugin dispatch and new-database allocation remain unimplemented.

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
`bee.governance.registry:materializer` keeps the overlay owner outside transferred data,
copies and remeasures the desired artifact, and deletes definitions no longer in
that owner's complete desired set. Cleanup can reconcile and observe the exact
empty owner overlay without making an empty application artifact publishable. It
makes one generation-fenced apply attempt.
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
re-resolves and re-preflights immediately before owner-local apply, re-verifies
the composed base after the apply, and records uncertainty with a named
composed-base diagnostic when the base moved instead of claiming applied. It
relies on the overlay's owner/generation conflict check and does not create
registry history.
Entry measurements enumerate requested grants and runtime modules from actual
artifact content, including lifecycle/security declarations, not catalog claims.
Final-state reference checks name the references this candidate answers for: the
ones its own entries hold and the base ones whose targets it removes. A base
entry already pointing at a target the destination host supplies out of band
carries its own standing state and does not block an unrelated plan.
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
No direct registry writer or remote activation endpoint is exposed through the
agent facade.

Migrations 5-7 and `bee.governance.persist:activation_store` provide the internal
recovery ledger. An immutable intent binds the host-selected overlay owner and
exact plan, artifact, resolution, preflight and migration-work digests.
Approval/consumption and migration progress are stored separately, and the
workspace slot keeps authorized desired state separate from observed applied
state. Governance checksum facts are checked against the target SQL migration
ledger before they enter preflight; they are a recovery index, not a substitute
for database truth. This store performs no resolution, approval call or overlay
operation.

`bee.governance.binding:activation_owner` prepares and advances that ledger one durable
phase at a time. Before consumption it requires the same current accepted
selection and repeats local resolution/preflight. Once `consuming` is durable,
recovery reconciles the same approval effect because it may already have been
consumed. A verified receipt establishes the desired intent. Later recovery
remeasures that exact intent, restores its absent process-local overlay with
revision-fenced receipts, and never follows a newer plan selection. The
resolver, approval executor, overlay owner, apply and exact-observation functions
remain host-selected inputs; replicated content supplies none of them.

Migration work stays inside the same durable `applying` effect. For the current
accepted slice, migration functions target an existing host-admitted SQL
database, have no newly authored dependencies, and cannot auto-start consumers.
Governance temporarily reconciles only the captured pending function definitions
under a deterministic prerequisite owner, executes them through the shared Hub
runner with Governance's private policies removed, persists partial or complete
ledger-confirmed receipts, clears the prerequisites, and only then reconciles
the complete application overlay. A crash after SQL commit is resumed from the
frozen work and target ledger. Removing an overlay restores registry state; it
never claims to roll back committed schema effects. Applied definitions are
immutable and updates append migrations.

`bee.governance.registry:hub_resolver` now provides the destination resolution adapter.
It captures one atomic registry state, asks the runtime to plan a
host-selected Hub dependency root, reconstructs the complete selected closure
from the planned final state, and retains definitions absent from the plan
delta. It strips all `ns.dependency` directives before overlay activation.
Registry-owned metadata supplies package ownership. Destination configuration
supplies package, namespace, kind, grant, runtime-module and database ceilings
plus applied migration ledgers. The flattened artifact must equal the reviewed
bytes exactly.

The destination facade is split the way the authoring facade is: the public
`destination_call` authenticates the caller's exact delivery operation and then
enters `bee:destination_execution_scope` to call the private
`destination_backend_call`, which proves it is in that scope before opening any
store. The caller's own actor stays the recorded one. The facade returns an
owner fault as the application boundary names it, so a refusal carries its code
and reason to an application instead of the internal store result shape.

Beside `get`, the facade answers the read-only `changes` operation for one
staged plan: it decodes the reviewed candidate from its own measured bytes with
`preflight.decode_candidate`, resolves the composed base through the same
host-selected resolver activation uses, and returns the added, changed and
removed entries with both base digests. It records no decision, consumes no
approval and writes no overlay.

The resolver and destination service are implemented and covered through the
plan adapter. `activation_profiles` supplies host-selected roots, overlay
owners, approval policies and capability ceilings; it cannot be populated by a
remote artifact. The boot worker follows only an already-authorized desired
intent. Runtime PR #787 supplies the reviewed plan and bound apply contract
used for production resolution.

An activation profile may also carry `database_bindings`, a bounded list of
logical `target_db`, physical `database_id` and optional `table_prefix` values.
The logical target must be in the profile's database ceiling. The normalized
list is part of the activation policy digest. Destination resolution copies it
into preflight and includes each selected physical database in the composed-base
measurement. New immutable migration work uses
`bee.governance-migration-work@3` and freezes the logical target, physical
database, optional prefix and physical definition evidence. Execution derives
its database map from that work rather than rereading the profile. Stored `@2`
work remains strict and keeps its identity binding without rewriting its bytes.
Applied facts follow their originating intent, so an ordinary update cannot
retarget an established migration chain by changing the database or prefix.
When the list is present, a
migration whose logical target has no binding is refused. Artifact metadata and
Agent tools never select physical database resources or prefixes. The same
profile can name bounded `migration_policies`; these host-owned references add
the exact function and physical-database grants after Governance's private
overlay and approval policies are removed from the migration call scope.
`table_prefix` is passed to migration code as a naming convention; a database
grant is still authority over the physical SQL resource and is not table-level
confinement.

Host profiles now select `resolver: hub` or `resolver: overlay`; omitted legacy
values decode as `hub`. The private-overlay resolver consumes exact immutable
Sync artifact definitions and preserves their registry IDs. It assigns package
ownership from the selected local profile, rejects reserved remote `registry`
metadata, Hub dependency directives and namespace/entry collisions, and passes
only the host profile's capability ceilings to preflight. Existing definitions
from the selected destination overlay may be replaced; definitions outside it
remain collision inputs. Migration definitions are measured from the exact
artifact and admitted only through the activation barrier described above.
