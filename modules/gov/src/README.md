# Overlay authoring and preflight

Internal typed checks over a destination-host-resolved package closure. The
`hub_resolver` module supplies the internal destination resolution adapter; this
library has no publication, SQL, network, approval or process permissions. It
is not a public install/update API.

`bee.gov.delivery:resolver` owns the shared `Resolver` interface for staging and
activation: `resolve` returns the measured candidate and destination context,
and optional `revision` observes the current registry revision. Hub and overlay
resolvers implement this interface with the same method receiver type.

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

`bee.gov.workspace:workspace` now freezes trusted in-memory file records into a
deterministic binary-safe snapshot. It copies records, measures each file's bytes
and SHA-256, hashes a sorted length-framed manifest, and binds workspace identity
and revision. It rejects path traversal, drive/stream paths, duplicate paths,
file/directory collisions and quota overruns (256 files, 240-byte paths, 4 MiB per
file, 16 MiB total). It is not a filesystem server or an authorization boundary;
returned Lua values must be remeasured before execution, not treated as immutable
merely because the helper calls them snapshots.

The source now includes the `bee.gov.binding:overlay_call` function and
`bee.gov:overlay_contract` binding through `overlay_local`, with the
`authoring_trait` agent description. This is private authoring, not activation.
The managed Agent gateway admits `bee.gov.overlay.read` (list/read) and
`bee.gov.overlay.write` (create/put/append/remove/freeze) only through this
facade. Every operation also checks the stored author against the authenticated
actor; an operation grant does not transfer an existing overlay's ownership.
The method's protected store policy does not grant callers direct database,
publication, approval, activation or registry/overlay access.

Public requests use `operation` and `overlay_id`; `guide` and caller-owned
overlay listing carry no overlay identity, and `workspace_id` is rejected on
this surface. `list` without `overlay_id` returns up to eight overlays owned
by the authenticated caller; with an ID it lists that overlay's files. The
private store translates the public identity to `workspace_id`.
Create uses expected revision zero;
other mutations use the revision returned by list. Mutations and freeze require
`expected_revision` and `idempotency_key`. Put replaces one entire relative file
using either `content` or canonical padded `content_base64`; read returns a
base64 window of at most 16,384 bytes with `offset`, `chunk_bytes` and `eof`.
The MCP boundary accepts at most 65,536 decoded bytes per put or append call.
Append requires the current byte `offset`. An optional lowercase SHA-256
`result_digest` asserts the assembled file. It checks the offset and any
asserted digest before changing storage. This allows an
`entries.json` larger than one MCP request while retaining the 4 MiB file and
16 MiB overlay ceilings, compare-and-set revisions and idempotent retries.
Remove deletes one file. Freeze copies the complete measured file set into owned
SQLite storage without changing the edit revision. Later edits cannot change the
stored frozen files. The same retry key and request return the original receipt,
even after subsequent edits or restart; changing the request conflicts. Replies
expose `overlay_id`; the private storage and execution boundary continues to use
its internal `workspace_id`.

For an application candidate, the author writes `entries.json` as a plain JSON
list of complete registry entries and freezes it with the other source files.
The publication preparation service parses that exact frozen file and uses
`bee.gov.delivery:artifact` to create the canonical measured envelope. It executes
no code and does not mutate the overlay or frozen snapshot.
`bee.gov.binding:publication_call` checks `bee.gov.delivery.manage` for prepare
or `bee.gov.delivery.publish` for publish against the caller's exact workspace
before entering `bee.gov.security:publication_execution_scope`. Its private
backend requires that scope's execution marker. The caller's actor remains the
recorded identity, while ordinary applications retain their direct-store deny.
Publication still verifies the host profile and exact applied artifact.

The host links `target_db`; `BEE_GOVERNANCE_DB` selects the default SQLite path.
Checked migration 1 owns the private workspace rows, files, frozen copies and
receipt tables. Capacity is bounded to eight overlays per authenticated author
and 64 per node, 16 distinct snapshots and 512 mutation receipts per overlay,
in addition to the file bounds above. One Agent therefore cannot consume every
authoring overlay slot on the node. Exhaustion fails explicitly; there is no
eviction, garbage collection or ownership transfer yet. Frozen content and
receipts are durable; they do not imply activation,
approval, or automatic restoration of runtime definitions. This virtual file API
does not mount a host directory or execute WASM. Hive transfer, inbox requests
and plugin dispatch remain unimplemented.

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
`bee.gov.delivery:materializer` keeps the overlay owner outside transferred data,
copies and remeasures the desired artifact, and deletes definitions no longer in
that owner's complete desired set. Cleanup can reconcile and observe the exact
empty owner overlay without making an empty application artifact publishable. It
makes one generation-fenced apply attempt.
For an approved replacement of a durable entry, it selects an overlay update
from the pinned composed registry rather than creating a colliding ID. Removing
the overlay restores the durable entry. The destination's existing namespace,
kind, protected-kernel, capability and exact-approval checks still decide which
replacements it may apply; this operation does not admit an artifact itself.
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

Migrations 5-7 and `bee.gov.persist:activation_store` provide the internal
recovery ledger. An immutable intent binds the host-selected overlay owner and
exact plan, artifact, resolution, preflight and migration-work digests.
Approval/consumption and migration progress are stored separately, and the
workspace slot keeps authorized desired state separate from observed applied
state. Governance checksum facts are checked against the target SQL migration
ledger before they enter preflight; they are a recovery index, not a substitute
for database truth. This store performs no resolution, approval call or overlay
operation.

`bee.gov.binding:activation_owner` prepares and advances that ledger one durable
phase at a time. Before consumption it requires the same current accepted
selection and repeats local resolution/preflight. Once `consuming` is durable,
recovery reconciles the same approval effect because it may already have been
consumed. A verified receipt establishes the desired intent. Later recovery
remeasures that exact intent, restores its absent process-local overlay with
revision-fenced receipts, and never follows a newer plan selection. The
settled intent's measured application admission includes the exact generated
policy bodies. Cold recovery regenerates absent capability records from that
unchanged admission and the recorded approval; a conflicting live grant still
blocks restoration.
The resolver, approval executor, overlay owner, apply and exact-observation functions
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

A settled `applied` observation retains the previous complete applied
generation as its slot baseline. `activation_store` exposes that baseline
and performs one-step, generation-checked `revert_activation`: it repoints the
desired pointer at the retained baseline, records the caller's compensating
migration receipt, and clears the observed pointer so boot recovery reapplies
the baseline. `migration_work.forward_only` is the pure guard that refuses a
compensation which re-runs, renumbers or moves backward an applied migration.
The store never edits an applied intent, migration ledger row or epoch; boot
failure falls back to this last good generation, and a committed migration
whose compensation cannot complete stops in recovery rather than booting
incompatible code against newer data.

`bee.gov.delivery:hub_resolver` now provides the destination resolution adapter.
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
enters `bee.gov.security:destination_execution_scope` to call the private
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

The activation configuration may carry one `workspace_applications` rule
beside its explicit rows, and the publication configuration a matching
`workspace_applications: true`. `activation_profiles.select` returns an
explicit row for a source, or else instantiates the rule for an overlay whose
name `workspace_applications` accepts, authored on this node or, while the
rule's `hive` flag is set, received over Hive; a name stays with the source
node whose desired activation holds its slot. The instance has component and
namespace `app.<overlay_id>`, the application `app.<overlay_id>:app`, the
rule's approval policy, kinds, modules, base admission policies and thread access,
and a private overlay owner per destination workspace. The instance is
measured into the policy digest exactly like an explicit row. A live host grant
record adds generated policy IDs to `allow.grants` and the application's
admission binding; its recorded thread access also selects the application
binding. Activation writes the generated policies, requirement defaults, grant
record and admission in one registry overlay transaction. It reuses a contained
live grant after measuring and checking a later artifact, while widening
requests a new permission approval. File grants root in the destination
workspace's folder from the node catalog; contract and HTTP grants authorize
only the capability gateway (`bee.gov.binding:contract_call`,
`bee.gov.binding:http_request`), which checks the caller's own live record.
An approved contract call retains the original application actor and enters the
private `bee.gov.security:gateway_callee_scope`, whose policy grants nothing.
Only the callee's declared policies apply; caller and gateway permissions do not
flow into it, and the application retains its custom-scope creation denial.
Preflight also refuses edits to the host `bee.security.gov:protected_kernel` trust map, its
transitive code dependencies and requirement selectors aimed at it. That map
names every shipped namespace a host-selected scope lives in or is reached from
(the governance, security, approvals, admission and launch namespaces plus
`bee.gateway`, `bee.harness`, `bee.credentials`, `bee.placement`,
`bee.placement.native`, `bee.resources`, `bee.threads`, `bee.hive`, `bee.env`,
`bee.sync`, `bee.host`, `bee.client`, `bee.desktop`,
`bee.terminal`, `bee.node` and `bee.workspace`), and its `super_edit` list is
the host's explicit carve-out of protected namespaces, empty in the shipped
composition. A super-edit profile row carries `expires_at`; it is admitted only
while unexpired, must set `allow.auto_start: false`, must name a dedicated
`super-edit`-prefixed approver policy declared with `confirm: explicit`, and may
not carry `allow.grants` for `security.*`, `funcs.security`, `process.security`
or a registry apply action. The instance
sets `allow.auto_start: false`, and preflight refuses any entry declaring
`lifecycle.auto_start` under such a policy (`AUTO_START_DENIED`); an explicit
row admits auto start unless it sets that field to `false`. Availability
lists this node's versions the selected profile publishes, boot recovery
follows every desired slot whose source the host still selects for that owner,
and the application catalog admits a governed admission record only while its
source's selected profile names the same owner and bindings.

Bee Settings is the only caller of the protected profile writer: the local
person enters the exact namespace list and duration and confirms the same
values before the host adds one profile per namespace. Settings can remove the
current workspace's super-edit rows and their overlay entries. A failed local
host readiness check removes expiring rows and their overlays before one
startup retry. `bee gov revert OWNER` uses the fixed recovery actor to restore
one retained activation baseline without the desktop; it refuses an owner with
applied migration facts until a forward-only compensation plan exists.

The configuration may also carry one `packages` rule with the wider ceiling
for installed package delivery (`security.policy`, `registry.entry`,
`contract.binding` and `env.variable` beside the workspace-application kinds).
It names one application entry per host-composed package: the component,
application definition, capability IDs, base admission policies, runtime
binding flags and thread access. `activation_profiles.select` instantiates the
entry whose component matches a package source this node composes, under the
private owner `bee.packages:<workspace_id>.<component>`; a live host grant
record adds its capability-derived policy IDs beside the entry's base
admission. `activation_profiles.package_admissions` measures the same record
shape from the composed registry. `application_admissions` selects those
package records and the currently projected governed records for the core
catalog; package projection is memoized by registry revision, workspace and
node.

Host profiles now select `resolver: hub` or `resolver: overlay`; omitted legacy
values decode as `hub`. The private-overlay resolver consumes exact immutable
Sync artifact definitions and preserves their registry IDs. It assigns package
ownership from the selected local profile, rejects reserved remote `registry`
metadata, Hub dependency directives and namespace/entry collisions, and passes
only the host profile's capability ceilings to preflight. Existing definitions
from the selected destination overlay may be replaced; definitions outside it
remain collision inputs. Migration definitions are measured from the exact
artifact and admitted only through the activation barrier described above.

Activation and selected-plan storage failures include the failing SQL operation
and native SQLite message. The activation owner propagates
these failures before applying an overlay; a failed commit never reports a
prepared or authorized activation.

## Workspace CLI drivers

A host may select `workspace_drivers` in its existing activation and publication
profile configuration. Local `driver.<name>` overlays own `bee.driver.<name>`
child namespaces; they do not create application admission records. The same
freeze, delivery, review, exact approval and activation ledger applies. A driver
requirement may append its own `harness.driver` binding to
`bee.harness.launch:harness_activation` at `.bindings +=`; other host targets
are refused. Raw overlay requirements remain declarations. The host selects
`bee.gov.binding:driver_bindings` as the activation declaration's admission
reader. The shared driver resolver combines the original host selection with
bindings derived from consumed desired artifacts in the existing activation
store whose exact code overlays are present. It adds no stored record or second
catalog; boot recovery restores approved code before it becomes selectable.
Preflight measures the exact owned append declaration with the same decoder used
by recovery. Activation retains this measurement when normalizing the registry
revision for durable approval evidence. That host evidence admits the
declaration's protected target; replacement requirements and edits to the
protected host entry remain refused. Descriptor policies grant only registry
reads. Launch definitions,
policies and executable mappings are part of the reviewed artifact; metadata
alone never activates a driver.

The overlay `source` operation reads a bounded window of a non-private file in
the authenticated workspace folder. It names no overlay or workspace; the caller
needs `bee.gov.overlay.source` on its actor-metadata workspace. The backend uses
the host-selected workspace folder catalog operation and filesystem root. Paths
are relative or absolute within that root; hidden/credential paths and shared-root
workspace subfolders are refused. Each read returns canonical base64,
`window_digest`, `next_offset` and `eof`, with a 16,384-byte limit. It neither
executes nor writes source and does not open the staging store.
