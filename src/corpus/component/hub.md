# Hub module management

This optional Bee component uses the existing native Hub reader and registry
APIs. It has no Keeper dependency and requires no runtime changes.

The public `bee.hub:call` function accepts `{operation, request?, expected_digest?}`
and returns `{ok, value?, code?, message?, replayed}`. The host grants
`bee.hub.read` or `bee.hub.manage` for the requested component; effect-free
planning also requires installed-catalog read authority, while apply alone
requires management authority. The facade
validates and authorizes the operation before entering its fixed private scope.
Requests cannot select credentials, a registry URL, an actor or a host path.

Read operations are `catalog`, `details`, `inspect`, `state`, `files`, `read_file`
and `installed`. Catalog keyword defaults to `bee`; an empty keyword clears it.
`state` returns an exact uninstalled artifact's metadata, entries and resources.
`files` and `read_file` read its embedded resource filesystem. These operations
may populate the native verified cache but do not publish or start the package.
They expose packaged assets, not a reconstruction of its source repository.
See [the API and acceptance status](../../docs/guides/hub.md) for request examples.

Management operations are `plan`, `apply` and `status`. Planning preserves other
roots, resolves dependencies and measures the request, registry revision and
artifacts. Exact dependency pins do not list release history; ranges page lazily.
Apply replans in a private worker before publishing the dependency-root change
and an operation receipt to durable registry history. Status reads one receipt
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
