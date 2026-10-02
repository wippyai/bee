# Hub module management

This optional Bee component uses the existing native Hub reader and registry
APIs. It has no Keeper dependency. The pinned runtime currently rejects a
deployment-root update that also changes its composed dependency-root versions.
`make hub-self-update-runtime-check` reproduces this conflict; completing a Bee
release-closure update requires a runtime correction in a new executable.

Hub now ships as an independently resolved component. Existing immutable
artifacts retain their recorded definition, receipt, migration, and policy
identities; upgrading an older assembled artifact to this component layout is
a reviewed installation change, not a compatibility alias or an automatic
registry rewrite.

The public `bee.hub.binding:call` function accepts `{operation, request?, expected_digest?}`
and returns `{ok, value?, code?, message?, replayed}`. The host grants
`bee.hub.read` or `bee.hub.manage` for ordinary package operations. Planning
also requires installed-catalog read authority. The host deployment root
`bee/bee` has a separate `bee.hub.self_update` grant, host-selected only for
the person-operated Modules app; agents and overlays receive no such grant.
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
See [the API and acceptance status](../../../docs/guides/hub.md) for request examples.

Management operations are `plan`, `apply` and `status`, plus publication
operations `publish_request` and `publish_apply` for person-approved Hub
uploads (see the publication section of the Hub guide).
Update Bee selects the core and every host-selected `bee.deps` Bee component
root together, independent or required, through one measured plan and receipt.
It preserves parameters, removed components and third-party root selections.
Retained components include a reason when a newer compatible release is unavailable;
native requirements and active Hub installer code constrain candidates.

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

Modules can install, update and remove optional Bee components through ordinary
review and confirmation. Unconverted hosts without the host selection refuse Bee
component management. Required roots and the installer dependency closure refuse
independent replacement or removal. Dependency constraints and entry collisions
still apply. Removal retains owned data and uses the existing migration policies;
service drain/revocation handoff remains a separate proposal. A first removal
with migration rollback requires root conversion through an update first.

A host that selects component management updates `bee/bee` using a core artifact
that contains no Bee-component dependency declarations. The plan selects the
newest compatible version for each explicit component root and retains its
requirement parameters alongside the core update.
A candidate that declares Bee-component dependencies is refused with its entry ID:
it would reclaim host selection, collide with host-owned roots or reinstall a
removed component. This applies to the initial self-update conversion as well as
later updates. Legacy full-composition artifacts remain installation bundle
inputs; independently updatable core artifacts require separate release identities.
`make native-pack BEE_VERSION=VERSION` seals the full executable baseline and
the dependency-free Hub core in one generation. The local boot root has a
distinct `-0.boot` prerelease identity; Hub publishes the core at `VERSION`.
The generated `dist/portable-deployment/hub/src/deps/_index.yaml` selects the
same components and requirement parameters as host-owned roots. Namespace
definitions, native identity, resources and core code remain in the core artifact.
`make hub-core-artifact-check` verifies the baseline pack list, exact host
parameters, core contents and every requirement target. Publication refuses a
core WAPP containing dependencies. Packing does not publish artifacts.
The standalone acceptance converts a legacy authored closure on its first core
update, applies a second core update and restarts the selected graph offline.
Hosts with an already authored legacy `bee/bee` selection must first convert using
a core self-update; its old manifest constraints remain effective until then.
Self-update also refuses a candidate that changes the active Hub installer code.
Both paths preserve deployment parameters and third-party roots.
A pack can declare native needs in `ns.definition.meta.native_requirements`
as `{package = "native/module", version = "1.2.3"}` rows. The planner compares
those semantic versions against the executable's Go module build list, exposed
only through the native launch host's read-only environment facts. The release
source builder adds a `bee.binary_identity` entry to the target root pack from
the build manifest; planning checks its native components and runtime commit
against those executable facts. A target that needs an unavailable native
version or another runtime commit is refused with `needs a newer Bee binary`
before apply. Select an earlier `bee/bee` version in its version history to plan
a rollback as another root update. Governed overlay restoration remains on its
separate path. The About page reads the native module version and runtime commit
from those same executable facts, while showing current and available pack
versions from Hub inventory.
Apply replans in a private worker before publishing the dependency-root change
and an operation receipt to durable registry history. Registry history retains
the selected pack graph for an owner restart; a newer executable baseline is
reconciled by the runtime's dependency resolver. Status reads one receipt
by digest or pages through the caller's operation history with `{page = 1}`.
Modules opens that history with Operations (O); recovery reviews the stored
request and digest before a separate confirmation. The worker serializes Bee
Hub operations, not all registry writers.

Real install/update/uninstall, receipt persistence across restart and uninstalled
resource filesystem reads pass on the existing runtime. Modules confirmation,
input, F12 and resize have source/pack and executable acceptance. Publication
recovery verifies the original root and inventory. Migration `up` captures exact
definitions and verifies SQL ledger evidence across restart. Removal checks all
departing owners, including orphaned dependencies. Explicit `down` records its
work before reverting migrations, retains the root on partial failure, and
commits root removal with its receipt. Recovery checks the original definitions
and skips ledger work already committed. Database and function access require
exact host-selected grants. A target may be an existing host resource or a SQL
database supplied by this installation. Newly supplied database definitions are
measured and verified after publication; an empty-ledger checkpoint is saved
before any migration runs. Existing matching ledger IDs refuse migration until
reviewed. Recovery verifies both migration and database definitions and skips
work committed after that checkpoint. SQL resource fields such as .file and .dsn
can use selected/default requirement values. SQLite acceptance covers new
databases, ledger collisions, partial failure, retry and crashes around the
checkpoint, schema commit and root removal.

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

`make hub-self-update-standalone-check` builds local sealed baseline and core artifacts and
serves their artifacts through a disposable fixture Hub. `BEE_RUNTIME` selects
the proof executable without changing the repository runtime pin. The acceptance
checks an independent Files update, optional telemetry install/removal, protected Hub
removal refusal, a core self-update, another independent Files update, the older
wildcard dependency, exact digest approval, completed receipts, unchanged runtime
owner PID, live Settings About rendering, and restart
with the same history/cache in an isolated network namespace. To reuse already
built fixtures, set `BEE_DEPLOYMENT` and `BEE_SELF_UPDATE_TARGET_DEPLOYMENT`.
