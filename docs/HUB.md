# Hub installation and package reads

Bee has an optional Hub component with a scoped public API and a Modules TUI
in development. Real install, update, uninstall and durable receipt restart
checks pass on the existing runtime. Migration execution and complete recovery
remain unfinished; the new component is not globally installed yet.

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
independent search, details, JSON parameter keyboard input, F12, resize and
shutdown pass. It does not prove the entire confirmation/apply UI against live
Hub; the real mutation API is covered separately above.

Complete resource-file, confirmation/apply UI, migration/recovery and distribution
acceptance remain release work.

The component follows Keeper's application-level planning and replan-before-apply
flow without importing Keeper. Runtime changes are outside this lane; earlier
prototypes were withdrawn. Declarative module packaging remains in Bee's explicit
build composition. Hub installations use durable registry history. Authored
component overlays, application start confirmation and destination sharing
admission belong to their respective owners and are not granted by inspection.
