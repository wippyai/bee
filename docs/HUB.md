# Hub installation and package reads

Bee has an optional Hub component with a scoped public API and a Modules TUI
in development. Real install, update, uninstall and durable receipt restart
checks pass on the existing runtime. This backend milestone is installed globally.
The explicit interruption-recovery API and scrollable plan review are included
in global build `237d76a8`. Migration execution remains unfinished.

`bee.hub:call({operation, request?, expected_digest?})` returns
`{ok, value?, code?, message?, replayed}`. The facade checks the authenticated
caller's `bee.hub.read` or `bee.hub.manage` permission for the exact component
before calling its private backend. Catalog and installed inventory use the
`catalog` resource. Caller input cannot choose a registry URL, credential, actor,
execution scope or host filesystem path.

## Read an uninstalled package

Like Kickside's Hub artifact inspection, Bee opens the exact package, reads it
and closes the handle. No install plan is required. The native Hub reader may
download to its verified cache; these operations do not publish or start entries.

```lua
{operation = "state", request = {
    component = "userspace/docker", version = "0.5.12"
}}
```

The value contains `component`, `version`, `digest`, `metadata`, `entries`
(including entry data) and `resources`. These are the package's registry state
and resource descriptors. A package can have entries and no filesystem resources.

Use a resource ID from that result to read an embedded resource filesystem:

```lua
{operation = "files", request = {
    component = "bee/example", version = "1.0.0",
    resource = "example:assets", path = ".", offset = 0, limit = 100
}}
{operation = "read_file", request = {
    component = "bee/example", version = "1.0.0",
    resource = "example:assets", path = "images/logo.png", offset = 0, limit = 65536
}}
```

The example resource and path are illustrative. `files` returns names/types and
an optional `next_offset`; its offset counts directory entries. `read_file`
returns `content_base64`, byte `offset`, `size`, `eof` and, when more bytes remain,
`next_offset`. File chunks default to 64 KiB and have a 1 MiB maximum. Directory
pages default to 100 entries and have a 1,000-entry maximum. Paths are relative
to the package resource; traversal is rejected. An optional `expected_digest`
inside the request binds subsequent reads to the artifact already inspected.

The filesystem exposes assets embedded in the package. It does not reconstruct
original repository files. Future consumers of state and files are deliberately
left to their own workflows.

Other reads: `catalog` accepts independent `query`, `keyword` and `page` fields;
keyword defaults to `bee` and `keyword = ""` clears it. `details` accepts
`component` and `page` for module details, README and a version page. `inspect`
accepts an exact component/version and typed requirement parameters, returning
requirements, entries and digest. `installed` takes no request body and reports
native ownership, direct roots and dependency users.

## Manage dependencies

`plan` takes `{action, component, version?, parameters?, migration_policy?}`.
Install/update require an exact version; uninstall takes neither version nor
parameters. The planner preserves unrelated roots and refuses changes to
host-configured roots. Exact dependency pins open the artifact without listing
release history. Version ranges fetch pages only as needed; a large version
history is not itself an error.

`apply` takes the same request and the displayed plan's `expected_digest` at the
outer call level. A private worker serializes Bee Hub operations, replans and
checks the registry revision before publishing the native dependency root and
receipt. It verifies the resulting inventory against the plan. `status` takes
that digest and returns the calling actor's durable receipt. Receipts distinguish
`published`, `complete`, `failed` and `recovery_required`; callers must inspect
this state even when reading the receipt succeeds. An uncertain call must be
followed by status inspection rather than a blind retry.

Without `expected_digest`, `status` accepts `request = {page = 1}` and returns
`{operations, page, total, page_size = 25}`. It lists only the caller's receipts,
newest baseline revision first, from current registry state. It does not fetch
registry version history or change registry state. New receipts also retain the
normalized public request, verified against its request digest on read; old
receipts remain readable without that field.

Install/update default to migration policy `none`. The source supports `up`
under host-selected exact database and function grants in
`bee.hub:execution_scope`. Before publication it captures each selected migration's
ID, owner, target database, timestamp and definition digest. Already-applied IDs
must match their existing definitions. The dependency root and captured work are
published in one registry change. The worker verifies the installed definitions,
executes package functions and checks their ledger before recording completion.
Selected/default `target_db` requirements are projected for migration metadata at
`meta.target_db` or `.meta.target_db`, so the plan and receipt measure the target
the native linker will select. The artifact entries remain unchanged. Other
linker paths remain native-owned; conflicting database requirements refuse the
plan. No Keeper package or migration DSL is imported by Bee.

The internal binding uses the standard function contract (`database_id`,
`direction`, `id`). Package functions own schema and ledger transactions. An
interrupted install can be resumed with the original confirmed `apply` request:
root, module inventory, exact definitions and current permissions are rechecked;
committed ledger entries become idempotent skips. Partial results are retained
in the receipt's `migration_work.rows`; failures remain `recovery_required`.
Registry definitions are never restored after migration execution.

Uninstall defaults to `block`. Every removed module is checked, including
orphaned dependencies removed by an update. Applied migrations block publication;
an absent ledger permits removal without creating a ledger. Missing database
grants or unreadable ledgers refuse publication. Explicit `leave` permits removal
while retaining migration effects. `down` still refuses: executing rollback before
definition removal needs its own durable phase and recovery checks.

These changes are installed in global build `f276bc2b`, preserving Agent recovery
and optional machine login. SQLite library and
real-service acceptance cover up/replay, committed-schema interruption/restart,
partial failure/retry, changed-definition refusal after restart, removal block/leave,
absent ledgers, requirement-linked targets and denied database access.
PostgreSQL/MySQL and newly installed database resources need service acceptance.
Execution currently requires the target database resource to exist before
publication. Concurrent external registry writers and independent migration
runners are not serialized by the Hub worker. The public runner's discovery path
can initialize the ledger, so it must not be reused for read-only preview.

Owner serialization does not exclude unrelated registry writers. Automatic
baseline restoration is attempted only while the observed registry revision
still equals this operation's publication revision; this is not atomic compare
and swap. A crash after publication can leave a `published` receipt. New receipts
capture the expected module inventory in the same registry change as the root.
After checking `status`, an explicit `apply` with the original confirmed request
and digest verifies the current root and captured inventory without republishing.
It marks the receipt complete only when they agree. A later root edit is retained
and results in `recovery_required`; recovery does not restore the old registry.
Older published receipts without captured evidence return `UNCERTAIN`. Status
remains read-only. The source Modules application opens operation history with
Operations or O, selects receipts with arrows or the mouse, and pages with left
and right; PgUp/PgDn scrolls the selected receipt details. Recoverable receipts with a stored request offer a separate recovery
review and confirmation. The review scrolls through saved version, JSON values
and migration rows. Escape cancels without applying. Confirm sends the
original request and digest; no automatic retry is scheduled. Older receipts
without a request remain view-only. This history UI is not yet installed globally.

## Acceptance and remaining work

`make hub-unit-check` runs focused planner, catalog, inventory, migration adapter,
preview-boundary and Modules model/view tests in a disposable composition.
`make hub-migration-runner-check HUB_MIGRATION_PACK=...` opens the pinned public
`wippy/migration@0.3.17` artifact as test input. Its unchanged libraries and toy
migrations prove real SQLite up/repeat/down and excluded-ID behavior through
both the public runner and Bee's binding. Separate scopes prove missing database
and function grants refuse execution. Reading an absent ledger and these denied
attempts leave the target database without tables. The artifact's dependencies
and bootloader are not activated. This checks library compatibility, not installation
or production receipt recovery. Failed fixtures retain their databases and logs;
the repository lock is copied unchanged into each fixture.
`make hub-migration-service-check` serves disposable package artifacts through a
local Hub transport and calls the actual scoped facade and publication worker.
It verifies SQL effects, durable results, completed replay, orphan removal guards,
explicit leave, and an actual SIGKILL after schema commit followed by restart
reconciliation. A second migration deliberately fails after the first commits;
the partial receipt survives, and an explicit retry after its external prerequisite
is supplied skips the first migration and applies only the remaining work. A
separately authorized host edit after interruption changes a migration body through
the native registry API; replay refuses its changed digest without completing work.
Test transport helpers remain outside production and use the
repository's existing native dependencies with read-only Go module resolution.
`make hub-inspect-check` reads public `userspace/docker@0.5.12`, proves module and
publication permission denials, and verifies unchanged registry history. Its
state-preview check sees 96 entries and zero filesystem resources; this does
not prove a successful file read.

`make hub-manage-check` exercises the scoped facade and private worker against
real `wippy/test` install, update, uninstall, confirmation mismatch and permission
denials, then restarts and verifies durable receipts and continued removal.
`make modules-app-check` uses deterministic fixture Hub replies with the real
broker, app process and presenter from source and a pack. Keyword clearing,
independent search, multiline README reading, details, JSON parameter keyboard input, plan/review/cancel/
confirm, completed receipt, F12, resize and shutdown pass. Package details have README and Versions panes (H/V); arrow keys and the mouse
wheel scroll the README. Installed selection stays in its current list. Change
review lists changed packages before summarizing unchanged modules. The standalone Modules UI includes these changes.
The installed UI makes plan and confirmation effects scrollable with arrow
keys or the mouse wheel. It lists migration IDs and target databases, automatic
starts and declared capabilities individually. This follow-up passes 56 focused
cases and source/pack keyboard checks and is included in global `237d76a8`.
A published or missing
receipt state is not displayed as completion. The separate native lifecycle check covers confirmation/apply against live Hub.

`make hub-preview-check` reads public `keeper/keeper@0.5.83` as an uninstalled
test artifact. Root/nested resource listing, chunked file reads, EOF, traversal
and digest mismatch rejection pass with unchanged registry history. This package
is test data only; Bee does not install or depend on Keeper.

The bundled planner preserves resident modules outside the dependency-root
closure. A fresh embedded deployment has no persisted version resolution; the
first publication may populate that metadata. Verification requires each
retained module to remain present and checks every version captured by the plan.
`make native-modules-lifecycle-check BEE_BINARY=...` passes real installation,
historical-version update, removal, repeated-removal refusal and reopen against
the same registry state. All original bundled package bytes remain unchanged;
content-addressed cache aliases may be added.

`make hub-recovery-check` kills the real runtime immediately after publication,
then reopens the same registry SQLite state and reconciles the original request.
A second case edits the root before replay and verifies `recovery_required` with
the edit preserved. The fixture checks explicit success markers, root cardinality,
selected version, changed-request refusal and read-only status. Its interruption
hook exists only in a disposable source copy. Migration execution remains unfinished.

The component follows Keeper's application-level planning and replan-before-apply
flow without importing Keeper. Runtime changes are outside this lane; earlier
prototypes were withdrawn. Declarative module packaging remains in Bee's explicit
build composition. Hub installations use durable registry history. Authored
component overlays, application start confirmation and destination sharing
admission belong to their respective owners and are not granted by inspection.
