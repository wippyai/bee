# Development conventions

Bee is a typed Lua terminal desktop. Keep package ownership explicit and
preserve the authority boundaries described in
[application contracts](../reference/applications.md),
[package boundaries](package-boundaries.md) and [the system map](ownership.md).
Bee-owned code and artwork are MIT; Wippy and other dependencies retain their
upstream licenses.

## Placement and ownership

Folder nesting mirrors namespace nesting: each folder holding an
`_index.yaml` file is one namespace, so `src/a/b` is `<root>.a.b`, and no
folder re-declares its parent's namespace. There are no `host/` folders;
host wiring lives in the app root or beside its component. The host component
`src/host` is the documented desktop-owner namespace, not an installable
component wiring subfolder. Module source roots map hyphen-separated package
names to dotted namespaces (`git-worktree` → `bee.git.worktree`). The only
package-root spelling exception is `modules/application/src` → `bee.app`, the
public SDK. Namespace segments and mapped folders contain no underscores.
No child production `src/` path diverges from its namespace.

Each entry lives in the namespace of the component that owns its concept,
in the appropriate child such as `service`, `binding`, `persist`, `types`,
`security` or `app`. The root `bee` namespace holds only the host composition
and process wiring described below. Reuse existing dependency entries,
resolution locks, requirement parameters and owner stores instead of adding
parallel registry records or stored state for the same information.

`make lint` runs `build/layout_check.py` before typed Lua lint. It checks namespace
paths, component roots, local sources, application entries, process placement,
host-free requirement defaults, duplicate Lua sources, orphan files and
requirement/import and named approver definition targets. Domain ownership, dynamic registry discovery and
public API reachability also require review.

The generated [component inventory](component-inventory.json) records current
namespace and entry IDs, requirement targets, topics, owner resources and
tables, native-known IDs and process handoff evidence. Run
`make component-inventory-check` to verify the source-derived snapshot and the
persisted identity baseline. A persisted ID, topic or schema change must name an
M0–M7 migration in `build/component-inventory-migrations.json`.

| Location | Owns |
|---|---|
| `src/_index.yaml` | Root composition only: `bee:definition`, `bee:workers` and `bee:terminal` |
| `src/deps` | One `bee.deps:<module>` dependency per composed module with the host-selected requirement parameters |
| `src/security`, `src/security/<area>` | Host-selected app policies as `bee.security` and `bee.security.<area>` |
| `src/env` | Host environment and selected resources as `bee.env` |
| `src/hive/service`, `src/hive/api`, `src/hive/security` | App-owned Hive supervisor, open workspaces operation and its policy |
| `src/hive/supervisor`, `src/hive/desktop` | Generic Hive routing, host-selected adapter table, supervisor lifecycle and desktop bridge |
| `modules/hive-manager/src` | Hive management app as an installable package |
| `modules/workspace/src` | Workspace catalog contracts, authorized bindings, SQL repositories, immutable migrations and checkpoint/selection values as `bee.workspace` and its `.catalog`, `.binding`, `.persist`, `.migrations` and `.types` children |
| `src/host` | TTY-free host, client admission, renderer grants and live inventory |
| `src/launch` | Local startup, presenter selection, coordinated exit and the node host manager |
| `src/client` | Desktop client, public commands, qualified layout and client store |
| `src/interaction` | Bounded host/client questions and delivery state |
| `src/apps` | Admission, application lifecycle, producer capabilities and routing as `bee.apps` |
| `modules/desktop/src` | Pure scene, reducer and layout values as `bee.desktop`; shared decoders in `.types`, committed projection and status observation in `.service` |
| `src/protocol` | Private core message decoders |
| `src/terminal` | Replaceable presenter, input and composition |
| `modules/values/src` | Shared bounds, canonical JSON, clock conversions and reply decoding as `bee.values` |
| `modules/application/src` | Public SDK namespace `bee.app`: application client, owner clients and presentation kits |
| `modules/ui/src` | Shared frame, appearance and bounded text helpers as `bee.ui` |
| `modules/console/src/app`, `modules/settings/src/app` | Terminal and Settings/About UI as `bee.console.app` and `bee.settings.app` |
| `src/console` | Host-selected native Terminal executor, OS environment and grants |
| `modules/approvals-inbox/src` | Approvals inbox app as an installable package |
| `modules/threads-timeline/src` | Thread timeline viewer as an installable package |
| `modules/workspace-manager/src` | Workspace manager as an installable package |
| `modules/host-processes/src` | Host process inspection app as an installable package |
| `modules/hub-modules/src` | Hub Modules package policies and dependencies; UI in `src/app` as `bee.hub.modules.app` |
| `modules/gov-overlays/src` | Governance Overlays app as an installable package |
| `modules/hive/src` | Cross-node protocol envelopes, client, exposure catalog, shared principal identity and the `hive.invoke` check |
| `modules/threads/src` | Durable records, authority, subscriptions, delivery and carrier store |
| `modules/docs/src` | Offline documentation protocol, corpus reader and read-only gateway facade |
| `modules/resources/src` | Resource associations, scoped grants and owner-local ledger |
| `modules/driver/src` | Driver contracts and shared types at the root; configuration, option rendering, quoting and TOML helpers in `.binding`, observations and normalization in `.codec`, and framing in `.transport` |
| `modules/placement/src` | Shared placement contract, launch values, transition rules and binding resolution |
| `modules/sync/src` | Owner-local projection, event and receipt ledger |
| `modules/approvals/src` | Durable approval owner, inbox feed and outbox worker |
| `modules/placement-native/src` | Native launch attempts, executor boundary, evidence and cleanup state |
| `modules/node/src` | Authorized native-node descriptions and metadata |

Bee's root index owns host composition and root process wiring. Module-owned
application entries and their UI live in `modules/<module>/src/app` as
`<module namespace>.app`. The host selects module entries through `bee.deps`
requirement parameters. Module requirement defaults never point at host app
IDs. Module `process.service` entries take their host and policy grants through
requirements (`process_host`, per-service policy lists); their entries keep
empty underlays the host fills.

Every entry belongs to the namespace of the component that owns its concept,
in the child that implements that responsibility. `bee` has exactly the three
composition entries above. Host-selected protected admission catalogs live in
`src/security/<owner>`; endpoint wiring, selected defaults and service instances
live beside their owner (`api`, `env` and `service`). They remain app-owned
composition and do not move into installable packages.

Component roots admit `ns.definition`, `ns.dependency`, `ns.requirement` and
`contract.definition`. The following shared library entries are the complete
root library set; executable implementations, concrete bindings, policies,
resources, catalogs, profiles and app helpers belong in their owning children.
`build/layout_roots.json` records this set with exact kinds; `make lint` rejects
other root entries, including a known composition name with the wrong kind.
The check applies to the namespace regardless of which package declares the
entry: host wiring cannot leak implementations into a component root.

| Component namespace | Shared root libraries |
|---|---|
| `bee.app` | `arguments`, `caller`, `client`, `diagram`, `folder_picker`, `forms`, `host_leases`, `interaction`, `names`, `sessions`, `sessions_protocol`, `status_reader`, `status_surface`, `thread_protocol`, `viz` |
| `bee.capability` | `model` |
| `bee.credentials` | `formats`, `protocol` |
| `bee.desktop` | `model`, `state`, `layout` |
| `bee.docs` | `protocol` |
| `bee.driver` | `types` |
| `bee.driver.wippy` | `protocol`, `types` |
| `bee.files` | `protocol` |
| `bee.gateway` | `protocol` |
| `bee.harness` | `types` |
| `bee.hive` | `types` |
| `bee.node` | `protocol` |
| `bee.placement` | `decode`, `request`, `transitions`, `types` |
| `bee.placement.native` | `protocol` |
| `bee.sync` | `protocol`, `replica_protocol`, `types` |
| `bee.threads` | `record_types`, `types` |
| `bee.ui` | `appearance`, `frame`, `text` |
| `bee.values` | `bounds`, `canonical`, `clock`, `reply` |

The SDK `bee.app` owns its documented public application helpers and presentation
kits at its root. Shared frame, appearance and text values belong to `bee.ui`.
Those entries are included in the same explicit set. New
shared root libraries require a documented responsibility and a reviewed update
to the set; a new implementation does not qualify simply because it is shared.

An append requirement (`+=`) contributes one element. It has no array default;
an absent host selection contributes nothing instead of a nested empty array.

`bee.harness.host:environment` is not composed: Bee's native host component
registers it at boot (`native/launch/component.go`) with the `home`, `cwd`
and `self` facts, environment-name presence metadata, and executable discovery, so module defaults may reference
it in every composition, including isolated module tests.

A module-owned `fs.directory` with a project-relative path must set
`base: project`; without it the runtime resolves the path against the owning
module's resource root instead of the project.

Registry IDs are public identities independent of file paths. `main.lua` is an
actor entry point, `app.lua` a default app entry point and `view.lua` a
renderer. Extract helpers by responsibility and name them for their domain;
do not create a universal manager. Core may import shared UI, shared UI may
import shared UI, and apps may import public client contracts and their own
helpers. Apps must not import private brokers, stores or process owners.

The physical display owner keeps surface and viewport handles; a presenter
receives only a native viewport grant. Asynchronous terminal delivery owns
attachments and serialized per-view input/resize queues. Rendering reads the
local cache and must not block the input loop. Adjacent unsent resizes may
coalesce; failed or uncertain input is not retried automatically. Rejected
input requests a redraw so its error is visible.

Pure reducers and value modules have no registry, process, SQL or terminal side
effects. A subsystem that needs an independent owner adds only the required
process, persistence, migration, binding, trait and registry slices. The
module's root, namespace ownership and dependency requirements must be declared
before extraction. Independent release publication and destination Hub package
transfer remain proposals.

Application entries, renderers, screen models and view helpers live in
`modules/<module>/src/app` as `<module namespace>.app`. The SDK root
`bee.app` belongs only to `modules/application`; app children such as
`bee.files.app` import its helpers and own their separate application entries.
Desktop values and the projection actor live in `modules/desktop/src`; the
terminal shell remains in `src/terminal`.

Within a module, keep shared domain types and contracts at the root. Public contract
bindings live in `binding`. Workspace catalog contracts retain their existing
domain root `bee.workspace.catalog` and durable binding IDs; their method
implementations live in `.binding`. Contract
implementations belong in `binding`, SQL repositories in `persist`, and
long-running processes in `service`. Use `api` for HTTP endpoints and `traits`
for agent tools. Each child namespace declares its own local sources in its
YAML. Inject host resources through `ns.requirement`; creating a child directory
does not require a new contract or forwarding layer.

## Values, messages and authority

Use explicit record types for exported values and functions. Treat decoded JSON
and message payloads as `unknown` until validated; never use casts or `any` to
skip validation. Bound strings, arrays, state, geometry, request IDs and
pending work. Reject invalid versions before changing state.

Import generic bounds, canonical JSON, clock conversions and reply decoding
directly from `bee.values`. Domain checks stay with their owning components;
retained startup phases and deadlines live in `bee.app.status:startup_progress`.

Authenticate `message:from()` and the relevant instance, launch token,
execution generation or operation grant. A PID in a payload is not
authentication. Keep request IDs, instance IDs, view IDs, execution PIDs,
revisions and resume schemas distinct. A send is queued, not ready, committed
or stopped; report asynchronous completion explicitly. A timeout may leave an
unknown result and must not trigger a blind retry.

Use `process.listen(topic, {message = true})` and `channel.select` with checked
values, and unregister listeners on exit. The remote Hive protocol remains a
typed local map at each receiver; transport identity, payload validation and
domain authorization are separate checks. Rendering derives from committed
values; transient drag prediction belongs only to the presenter.

Protected host bindings select application policies. Metadata, registry entries
and shared helpers never grant capabilities. Default to the smallest exact
resource and action scope. Native execution has OS-user authority and is not
confined by a Lua permission scope. Apps reach subsystem stores only through
that subsystem's authenticated methods.

## Persistence and migrations

Only an owning service opens its primary store. Apps persist opaque,
application-owned JSON through the checkpoint protocol. Every subsystem owns
its tables and migration ledger. Sharing a SQLite file is not permission to
query another owner's tables. Migrations are append-only: never edit applied
SQL, change an applied checksum, or delete a workspace database to hide a
failure. A migration change is a new migration with recovery behavior defined
by its owner.

Registry definitions and configuration history, workspace state, thread
records, approvals, resources, credentials and client presentation state remain
separate version domains. Export/import and overlay activation transfer
declarative content and explicitly supported state; they do not copy secrets,
live PIDs, mounts or grants.

## Verification and packaging

Use the Makefile:

```sh
make setup
make lint
make fixture-lint
make test
make check
make pack
make native-pack
make portable-deployment-check
make standalone
```

`make test TEST_JOBS=1` runs the same four isolated Lua shards sequentially
on a loaded host. The default runs all four in parallel.
Tests declaring `meta.resources: [docker_daemon]` share one shard so a run
does not issue container creates from separate test processes against the same
host daemon. That shard holds an exclusive `flock` across checkouts for its
runtime process. The unit and focused Lua runners use the same lock, selected
from the test entries' resource metadata. `BEE_DOCKER_DAEMON_LOCK` selects the
lock file; otherwise it is `docker-daemon-<daemon ID>.lock` under `bee/` in the
user's XDG cache directory, so every checkout using the same daemon shares one
lock and an unreachable daemon fails with its exact error. The runner prints when it waits and when it acquires the lock, including the wait duration.
The wait has no timeout and can be interrupted. Failures release the lock and
retain their cause. The remaining entries retain their balanced parallel shards.

`make check` covers typed source, permissions, persistence, source/pack
behavior and terminal acceptance. Release CI runs it as the Makefile's
`check-shard-*` targets; a new `check` member joins one shard, and
`make check-shards-check` fails until it does. Use `make desktop-check` after `make pack`
when registry entries change and `make attachments-check` for host/client grant
or revocation changes. Focused tests should exercise the real host wiring,
negative permissions, retry, restart, cancellation and cleanup for the changed
boundary. A constructed completion record does not prove process cleanup.

`make check-parallel CHECK_JOBS=4` runs the same verified release shards in
parallel on a local machine. Each shard writes its own native pack generation
and log under `.wippy/check-parallel/`; the command reports wall and CPU time
and fails if any shard fails.

The root has a 19,277 Lua line ceiling under `src/`, recorded in
`build/root-src-lua-budget.txt`. Shared retained-startup progress values live
in `modules/application/src` as `bee.app.status:startup_progress`. Run
`make root-src-budget-check`; it fails if the count grows beyond that ceiling.
Lower the ceiling as later component moves reduce root code.

Fixtures use disposable test workspaces and remain outside production `src/`.
Test scenario folders are independent overlay roots, not namespace children;
their indexes augment the identities under test. The complete overlay inventory
is in [the layout audit](layout.md). Inspect
source and assembled packs for test registrations, fixture data, test-library
dependencies and embedded filesystem assets. Production loads only the root
and selected modules' `src/` directories.
`make native-pack` seals independently packed root and component WAPPs into the
native manifest. `make portable-deployment-check` inspects the exact local lock
and vendor set, then proves isolated source-free boot, restart and tamper
rejection. The same build seals a Hub core with `bee.deps` excluded; the Hub
composition supplies those host-selected roots. The bundled baseline and Hub
core share the component artifacts, and host admission authorizes their use.

New runtime patches require upstream Go tests, a refreshed runtime checksum and
a clean pinned build. `make -C native patched-check` validates the native source
against the manifest without modifying repository module files. Documentation
edits need link/source consistency checks and an update to the relevant current
contract; avoid machine-specific paths, credentials and local stores.

`make lint` and `make fixture-lint` enable strict-any: native and decoded values
must be narrowed before use. `make fixture-lint` checks the disposable test
composition without running tests.
