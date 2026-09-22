# Development conventions

Bee is a typed Lua terminal desktop. Keep package ownership explicit and
preserve the authority boundaries described in
[application contracts](../reference/applications.md),
[package boundaries](package-boundaries.md) and [the system map](ownership.md).
Bee-owned code and artwork are MIT; Wippy and other dependencies retain their
upstream licenses.

## Placement and ownership

| Location | Owns |
|---|---|
| `src/_index.yaml` | Host composition, resources and protected admission/policy wiring |
| `src/core/workspace` | Workspace persistence, application checkpoints and workspace identity |
| `src/core/host` | TTY-free host, client admission, renderer grants and live inventory |
| `src/core/launch` | Local startup, presenter selection and coordinated exit |
| `src/core/client` | Desktop client, public commands, qualified layout and client store |
| `src/core/interaction` | Bounded host/client questions and delivery state |
| `src/core/session` | Committed desktop projection |
| `src/core/applications` | Admission, application lifecycle, producer capabilities and routing |
| `src/core/desktop` | Pure scene, reducer and layout values |
| `src/core/protocol` | Private core message decoders |
| `src/core/terminal` | Replaceable presenter, input and composition |
| `src/core/storage` | Workspace database and migration ledger |
| `src/ui` | Public application helpers, appearance and rendering values |
| `src/apps/<name>` | A standalone default application and its view/domain helpers |
| `modules/bee-threads/src` | Durable records, authority, subscriptions, delivery and carrier store |
| `modules/bee-resources/src` | Resource associations, scoped grants and owner-local ledger |
| `src/sync` | Owner-local projection, event and receipt ledger |
| `src/approvals` | Durable approval owner, inbox feed and outbox worker |
| `src/placement` | Launch attempts, executor boundary, evidence and cleanup state |
| `src/node` | Authorized native-node descriptions and metadata |

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
before extraction. Independent Hub packages, public enrollment and remote
package transfer remain separate proposals.

Within a module, keep shared domain types and contracts at the root. Contract
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
make test
make check
make pack
make native-pack
make standalone
```

`make check` covers typed source, permissions, persistence, source/pack
behavior and terminal acceptance. Use `make desktop-check` after `make pack`
when registry entries change and `make attachments-check` for host/client grant
or revocation changes. Focused tests should exercise the real host wiring,
negative permissions, retry, restart, cancellation and cleanup for the changed
boundary. A constructed completion record does not prove process cleanup.

Fixtures use disposable test workspaces and remain outside `src/`. Inspect
source and assembled packs for test registrations, fixture data, test-library
dependencies and embedded filesystem assets. Production loads only the root
and selected modules' `src/` directories.
`make native-pack` and `make standalone` create a native distribution with its
own manifest; bundled modules are not independently published packages.

New runtime patches require upstream Go tests, a refreshed runtime checksum and
a clean pinned build. `make -C native patched-check` validates the native source
against the manifest without modifying repository module files. Documentation
edits need link/source consistency checks and an update to the relevant current
contract; avoid machine-specific paths, credentials and local stores.
