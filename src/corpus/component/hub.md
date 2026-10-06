# Hub module management

Hub is the module manager: it reads the native Hub and the live registry,
plans, applies and removes package installs, runs package migrations, and
publishes packages. It has no Keeper dependency. Update Bee updates the
`bee/bee` core artifact and host-selected component roots in the existing
publication transaction.

The public `bee.hub.binding:call` function accepts `{operation, request?, expected_digest?}`
and returns `{ok, value?, code?, message?, replayed}`. The host grants
`bee.hub.read` or `bee.hub.manage` for ordinary package operations. Planning
also requires installed-catalog read authority. The host deployment root
`bee/bee` has a separate `bee.hub.self_update` grant, host-selected only for
the person-operated Library app; agents and overlays receive no such grant.
The app presents an exact plan and requires the person to confirm each update. Apply
uses the same durable receipt and migration path as other Hub root changes. The facade
validates and authorizes the operation before entering its fixed private scope.
Requests cannot select credentials, a registry URL, an actor or a host path.
Resolver rejection returns `FAILED` with the original diagnostic bounded to
4,096 bytes and an explicit `[truncated]` marker when needed. It records a
`failed` receipt with the same code and message; replay returns that failure.
A malformed diagnostic does not turn a definite failure into `UNCERTAIN`.
Uncertain worker delivery still requires a receipt lookup.
Completed-operation replay validates the caller and request through the same
receipt path without acquiring the publication lock. Pending effects and
recovery retain that lock.

Read operations are `catalog`, `details`, `inspect`, `state`, `files`, `read_file`,
`installed`, `installed_source` and `updates`. `updates` returns installed Bee
pack versions, each available Hub version, update availability and whether the
latest `bee/bee` closure needs a newer native binary. It reads the host-owned
binary identity and the live registry inventory. Its catalog scan is bounded
to 16 pages of 50 items; it returns the versions read so far with a catalog
status error if the Hub search exceeds that bound. Catalog keyword defaults to
`bee`; an empty keyword clears it.
`inspect` and `state` return entry summaries first, at most 32 per page with a
`next_offset` cursor, and entry source only on explicit `include_data`; read
selected source through `files` and `read_file` windows.
`state` returns an exact uninstalled artifact's metadata, entry summaries and resources.
`files` and `read_file` read its embedded resource filesystem. These operations
may populate the native verified cache but do not publish or start the package.
They expose packaged assets, not a reconstruction of its source repository.
`installed_source` lists and pages only Lua source entries owned by an exact
installed component version. The list gives a registry revision; reads require
that revision and return at most 16,384 bytes. It does not expose registry
configuration, other owners or package resources. This covers local development
versions that have no matching Hub artifact.

Management operations are `plan`, `apply` and `status`, plus publication
operations `publish_request` and `publish_apply` for person-approved Hub
uploads.
Update Bee selects the core and every host-selected `bee.deps` Bee component
root together, independent or required, through one measured plan and receipt.
It preserves parameters, removed components and third-party root selections.
Retained components include a reason when a newer compatible release is unavailable;
native requirements and active Hub installer code constrain candidates.
Changed component services use the same owner drain and readiness evidence as
independent updates; the core retains its existing process lifecycles.

Ordinary component planning preserves other
roots, resolves dependencies and measures the request, registry revision and
artifacts. The planner uses the runtime selection rule: preserve a live installed
version's captured definitions when that component is unchanged; inspect the
requested component and changed versions as candidate artifacts. This also keeps
unrelated package planning independent of local development artifact publication.
The version solver ordinarily preserves a live installed
version, including a selected prerelease, when every incoming constraint permits
it; otherwise it chooses the highest
compatible stable release (or a compatible prerelease when no stable release
matches and the range explicitly admits that prerelease). Update Bee instead
selects the newest compatible host-root releases; an explicitly admitted newer
prerelease can take precedence over an older stable release.
Changed selections retract their old dependencies and re-evaluate
intersections; a parent is never downgraded to satisfy its children. Exact pins
and ordinary compatible installed selections do not list release history; other ranges
inspect the complete bounded catalog, whose pages are ordered by publication time.
Standalone inventory identifies the deployment root from
`snapshot:state().resolution.lock.root_module`, under the Hub execution scope's
exact `registry.resolution.get` grant. The live `resolution.modules` supplies
installed versions; `resolution.lock.modules` supplies the unchanged shipped
pins shown separately in About. Inventory roots contain only resident registry
entries; the lock-selected deployment is reported separately. The first standalone
update creates a history-owned `ns.dependency` at the normal `bee.hub.deps` ID.
Later updates change that resident selection; an existing host root retains its ID
and parameters. The plan digest covers the root ID and create/update operation.

The host selects independently managed components with `meta.independent: true`
on its existing `bee.deps` dependency entries. Installed roots and versions come
from those dependencies and the live resolution/lock; there is no second list.
The first operation transfers package-owned Bee dependency roots to host
ownership in the same Registry transaction as its existing operation receipt,
without changing dependency IDs or requirement values. Converted roots pin the
planned version and retain their metadata. Third-party roots remain unchanged.
Inventory derives `managed`; the plan and operation receipt's optional
`conversion` (version 1, roots with `id` and `component`) records only the
conversion effect for confirmation and interrupted-operation verification.
It is not used to discover installed roots. No SQL or application-state migration
is involved. Required host roots and the Hub dependency graph derive protection
at plan time; refusal identifies the dependent.

The Library can install, update and remove optional Bee components through ordinary
review and confirmation. Unconverted hosts without the host selection refuse Bee
component management. Required roots and the installer dependency closure refuse
independent replacement or removal. Dependency constraints and entry collisions
still apply. Removal retains owned data and uses the existing migration policies;
service transitions follow the owner lifecycle described below. A first removal
with migration rollback requires root conversion through an update first.


Independent component service transitions use the runtime's existing supervisor.
An unchanged registration, process and retained library imports need no service
transition when only the package version advances. Changed code or registration
still requires owner drain and readiness evidence. Candidate service definitions
come from the native registry plan for the exact dependency-root transaction,
including the preserved host requirement parameters. Unlinked artifact entries
are not compared with installed, linked definitions.
Each changed `process.service` names an owner `function.lua` in
`meta.component_lifecycle`; the host grants Hub the exact call through
`bee.hub.security:lifecycle_owner_policy`, which admits no owner function yet, so a
change to a service-bearing component is refused. Metadata grants no permission.
Services without that owner protocol, changed service/process identities,
and process hosts or HTTP services without supported drain evidence are refused.
Hub itself remains protected; its code replacement uses the existing `bee/bee`
self-update path.

Before effects, the existing operation receipt records `prepared` plus optional
`effect_digest` and version-one `lifecycle_work` (phases `prepared`, `quiesced`,
`published`, `ready`). The owner derives its admission fence from that receipt,
drains accepted obligations and acknowledges retained data, revoked grants and
closed resources. Hub then stops the service through the runtime supervisor,
rechecks captured process/handler fingerprints and the registry revision, and
publishes the dependency change with its receipt. Update/install starts the
selected service through that same supervisor and requires the owner's exact
boot-definition readiness acknowledgement before `complete`. A lost reply or
crash leaves recoverable intent; recovery uses the original request/digest and
rechecks candidate definitions, current grants and installed versions.
Unfinished lifecycle intent blocks another Hub operation.

The current retention policy is `retain`: files and database rows stay at their
host-owned locations, queued work stays in its owner journal, and removal never
runs migration `down` for a service-bearing component. No data export or data
rollback is claimed.

Open applications continue their existing definition-change replacement on
update. Removal withdraws their catalog bindings immediately and refuses while
any departing process remains alive. The person closes those applications and
recovers the same receipt before their definitions are removed; normal broker
stop closes resources and revokes execution grants.

A host that selects component management updates `bee/bee` using a core artifact
that contains no Bee-component dependency declarations. The plan selects the
newest compatible version for each explicit component root and retains its
requirement parameters alongside the core update.
A candidate that declares Bee-component dependencies is refused with its entry ID:
it would reclaim host selection, collide with host-owned roots or reinstall a
removed component. Self-update also refuses a candidate that changes the active Hub
installer code. Both paths preserve deployment parameters and third-party roots.
A pack can declare native needs in `ns.definition.meta.native_requirements`
as `{package = "native/module", version = "1.2.3"}` rows. The planner compares
those semantic versions against the executable's Go module build list, exposed
only through the native launch host's read-only environment facts. The release
source builder adds a `bee.binary_identity` entry to the target root pack from
the build manifest; planning checks its native components and runtime commit
against those executable facts. A target that needs an unavailable native
version or another runtime commit is refused with `needs a newer Bee binary`
before apply. Select an earlier `bee/bee` version in its version history to plan
a rollback as another root update. The About page reads the native module version and runtime commit
from those same executable facts, while showing current and available pack
versions from Hub inventory.
Apply replans in a private worker before publishing the dependency-root change
and an operation receipt to durable registry history. Registry history retains
the selected pack graph for an owner restart; a newer executable baseline is
reconciled by the runtime's dependency resolver. Status reads one receipt
by digest or pages through the caller's operation history with `{page = 1}`.
The Library lists that history under History; recovery reviews the stored
request and digest before a separate confirmation. The worker serializes Bee
Hub operations, not all registry writers.

Migration `up` captures exact definitions and verifies SQL ledger evidence across
restart. Removal checks all departing owners, including orphaned dependencies.
Explicit `down` records its work before reverting migrations, retains the root on
partial failure, and commits root removal with its receipt. Recovery checks the
original definitions and skips ledger work already committed. Database and function
access require exact host-selected grants. A target may be an existing host resource
or a SQL database supplied by this installation. Newly supplied database definitions
are measured and verified after publication; an empty-ledger checkpoint is saved
before any migration runs. Existing matching ledger IDs refuse migration until
reviewed. SQL resource fields such as .file and .dsn can use selected/default
requirement values.

Authored component overlays and application launch/sharing admission remain separate responsibilities.

Package migrations retain host-supplied permissions and registry reads, with
Hub's private publication, receipt, worker and scope-editing policies removed
from their call scope. The runner also accepts a trusted owner's explicit
private-policy list so another owner can reuse the execution primitive without
passing its own authority into component code. Only those named policies are
removed; host database and function grants remain required.

The runner accepts an optional host-owned database binding map. Migration
metadata continues to name a logical `target_db`; a binding selects the physical
database registry ID used for grants and ledger access and may add a bounded
table prefix to the migration call. Once a map is supplied, every selected
logical target must have a valid binding. Packages cannot choose either the
physical database or its prefix. Callers that omit the map keep the existing
identity mapping where the logical target is the physical registry ID.

A reusable owner may also supply a bounded list of host policy IDs for the
migration call. The runner copies that list, removes the owner's named private
policies from the current scope, then adds only those selected execution
policies. This lets package code receive exact function and physical-database
grants without inheriting Hub or Governance publication authority. Policy
selection remains the invoking host owner's responsibility.

Plans also list `policy_changes`: each security policy the change adds, replaces
with a new package version or removes with a departing package, with its
actions, resources and whether an expression limits it. `installation` is the
pure value library for agent installation requests: it decodes a request,
selects install or update and the newest release, renders one approval body
from a ready plan bound to the asking gateway binding, verifies a recorded
request belongs to that binding and attempt, and maps an apply reply to the
agent's status. The gateway performs the calls.
