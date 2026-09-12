# Hub installation and package reads

Bee has an optional Hub component with a scoped public API and a Modules TUI
in development. Real install, update, uninstall and durable receipt restart
checks pass on the existing runtime. Migration execution and complete recovery
remain unfinished. This backend milestone is installed globally.

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

Install/update default to migration policy `none`. An `up` request with migration
work refuses publication until a migration runner is bound. Uninstall defaults
to `block`; checking or reverting migrations is not wired yet. Explicit `leave`
permits removal while retaining migration effects. The current migration adapter
alone does not establish production migration execution.

Owner serialization does not exclude unrelated registry writers. Automatic
baseline restoration is attempted only while the observed registry revision
still equals this operation's publication revision; this is not atomic compare
and swap. A crash after publication can leave a `published` receipt and needs
explicit reconciliation, which is not implemented yet.

## Acceptance and remaining work

`make hub-unit-check` runs focused planner, catalog, inventory, migration adapter,
preview-boundary and Modules model/view tests in a disposable composition.
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
The next source UI makes plan and confirmation effects scrollable with arrow
keys or the mouse wheel. It lists migration IDs and target databases, automatic
starts and declared capabilities individually. This follow-up passes 56 focused
cases and source/pack keyboard checks; it is not in the installed executable yet.
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
content-addressed cache aliases may be added. Migration execution and interrupted
publication recovery remain unfinished.

The component follows Keeper's application-level planning and replan-before-apply
flow without importing Keeper. Runtime changes are outside this lane; earlier
prototypes were withdrawn. Declarative module packaging remains in Bee's explicit
build composition. Hub installations use durable registry history. Authored
component overlays, application start confirmation and destination sharing
admission belong to their respective owners and are not granted by inspection.
