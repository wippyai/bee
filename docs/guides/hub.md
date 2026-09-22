# Hub installation and package reads

Bee's Hub component provides scoped package inspection and host-authorized local
installation. Modules is the corresponding terminal application. Hub inspection
never grants package capabilities, writes registry history, starts code or
creates an application overlay.

The public facade is:

```lua
bee.hub.binding:call({operation, request?, expected_digest?})
```

It returns `{ok, value?, code?, message?, replayed}`. The facade authenticates
the caller and requires `bee.hub.read` or `bee.hub.manage` for the exact
component before reaching the private backend. A caller cannot choose a registry
URL, credential, actor, execution scope or host filesystem path.

Managed agents receive the narrower read-only MCP `components` tool when their
launch policy admits it. It supports `catalog`, `details`, `inspect`, `state`,
`files`, `read_file`, `installed` and effect-free `plan`; direct apply,
installation, update, removal and status calls are refused at that boundary.

## Inspect a package

Hub reads an exact package without installing it. The native reader may put
verified bytes in its immutable cache; that has no registry or lifecycle effect.

```lua
{operation = "state", request = {
  component = "userspace/docker", version = "0.5.12"
}}
```

`state` returns the package component, version, digest, metadata, entries and
resource descriptors. Use a resource ID from that value to browse embedded
package resources:

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

The component, version, resource and path are illustrative. `files` returns a
directory page and optional `next_offset`; `read_file` returns base64 content,
byte offset, size, `eof` and optional `next_offset`. File reads default to 64
KiB and are limited to 1 MiB. Directory reads default to 100 entries and are
limited to 1,000. Paths are relative to the declared resource and traversal is
refused. Pass the inspected `expected_digest` to bind later reads to that exact
artifact.

`catalog` accepts `query`, `keyword` and `page`; an empty keyword clears the
keyword. `details` reads package details, README and version pages. `inspect`
reads one exact component/version with typed requirement parameters. `installed`
reports native ownership, direct roots and dependency users.

## Plan, review and apply

A management plan has this request shape:

```lua
{action, component, version?, parameters?, migration_policy?}
```

Install and update require an exact version. Uninstall accepts neither version
nor parameters. Planning resolves the dependency closure against the current
installed base, preserves unrelated roots and refuses changes to host-configured
roots. It reports requirements, migrations, automatic starts and declared
capabilities. A capability declaration does not grant the capability.

Planning is read-only. It may fetch and verify package artifacts into the local
cache, but does not publish registry state or execute a migration. `ready` means
requirement bindings are complete; service readiness needs separate lifecycle
evidence.

Apply requires management authority and the displayed `expected_digest`. The
private worker serializes Bee Hub operations, replans against the current base
and records a durable receipt. A changed plan or registry base requires another
review. Receipts distinguish `published`, `complete`, `failed` and
`recovery_required`; after an uncertain call, inspect its receipt rather than
retrying blindly. `status` with a digest reads that receipt. Without one,
`status` pages the authenticated caller's own receipt history.

Apply records lifecycle intent but does not claim that an automatic service has
become healthy. Package functions run only under host-selected exact database
and function grants. They do not receive Bee's private publication, receipt,
worker or scope-editing policies. Registry definitions are never restored after
migration execution.

## Migration and removal policy

Install and update default to migration policy `none`; `up` requires the
necessary host grants. The worker records selected migration identity and
measured definitions before execution. Recovery rechecks the original request,
installed inventory, definitions and current grants. Completed ledger entries
can be idempotent; changed definitions, missing grants or incomplete work remain
`recovery_required`.

Uninstall defaults to `block` when an applied migration would be removed.
`leave` permits removal while retaining schema effects. `down` is explicit and
requires the same measured definitions and host grants. Partial migration or
rollback results stay in the receipt for review and recovery; no automatic
retry is scheduled.

Modules presents the same read, plan, review, confirmation and receipt flow.
Its package contents browser is read-only and binds resource reads to the
selected artifact digest.

## Limits and checks

Hub installation is local and host-authorized. It is separate from authored
application overlays, application start confirmation and Hive delivery. Public
Hive enrollment, remote workspace composition and destination-to-destination
Hub transfer/install are not Hub operations.

```sh
make hub-unit-check
make hub-inspect-check
make hub-manage-check
make hub-recovery-check
```

See [package boundaries](../development/package-boundaries.md),
[distributed overlay delivery](overlays.md) and
[MCP configuration](agents/mcp.md).
