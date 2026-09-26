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
`files`, `read_file`, `installed`, `installed_source` and effect-free `plan`; direct apply,
installation, update, removal and status calls are refused at that boundary.
Agents ask the person to install through the separate write tools described in
[Agent installation requests](#agent-installation-requests).

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
`inspect` and `state` open Hub artifacts; an installed local development version
may have no Hub artifact and returns `module not found`. To inspect the code
actually installed, use `installed` to find its exact version and then
`installed_source` with `{component, version}`. That returns a registry
`revision` and a manifest of Lua source entry IDs and byte counts. Read one
entry with `{component, version, entry_id, expected_revision, offset?, limit?}`;
the reply has `content`, `offset`, `bytes` and `eof`. Each read is at most
16,384 bytes; the revision fence rejects a changed installation. This read
exposes only the selected component's Lua source, not registry configuration,
policy data, other components or native package resources.

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

## Agent installation requests

An agent learns how to build on a package by reading it through `components`:
`catalog` and `details` to find it, `state`, `inspect`, `files` and `read_file`
for its entries, requirements, documentation and examples, and `plan` to see
what installing it would change. To use a package it does not have, the agent
asks the person:

```json
{"name": "install_request", "arguments": {"component": "acme/tool", "version": "1.2.0"}}
{"name": "uninstall_request", "arguments": {"component": "acme/tool"}}
{"name": "install_status", "arguments": {"request_id": "<request_id>"}}
```

`install_request` resolves the exact plan in the agent's own workspace: the
newest release that is not yanked when `version` is omitted, and an update when
the component already has a Hub dependency root. Install and update run the
package's migrations (`up`) under the host's migration grants; uninstall uses
`block`. The host files one approval, bound to the agent's thread and attempt,
under the approval policy the host configuration `bee:module_installation`
names (`module-installation`, decided in Approvals). The approval shows the
package, version, source, dependency changes, the security policies the change
adds, replaces or removes with their actions and resources, migrations and
auto-start entries; the plan digest binds all of them. Filing changes nothing
and returns `request_id` and `status: pending`. A retry for the same plan by the
same attempt replays the same request. A package whose plan needs requirement
values is refused with `INCOMPLETE`; the person installs it in Modules.

`install_status` reports `pending`, `refused` (with `DENIED`, `EXPIRED` or
`WITHDRAWN`), `approved`, `applied` or `failed` with the Hub code and message.
The agent never holds Hub management authority. On the first poll after the
person approves, the gateway consumes the decision once and applies exactly the
approved digest through the Hub facade with management authority added to that
one call; a changed registry base fails with `STALE` and needs a new request.
`approved` means the apply outcome is unknown; the next poll repeats the same
digest-bound apply, which replays its recorded receipt. The requesting attempt
applies the request: the approval notice wakes its `thread_wait`, and a request
whose attempt ended before polling stays unapplied.

The host grants these tools per launch policy (`gateway_tools`) and links their
MCP policy through the gateway's `target_tool_install_policy`; the shipped
policy admits filing and polling requests and never applying them. The shipped
agent launch policies include them. The configuration link
`target_install_configuration` fails closed when absent.

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
