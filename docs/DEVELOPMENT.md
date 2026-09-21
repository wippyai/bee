# Development conventions

These conventions apply to Bee, a typed Lua terminal desktop. Kickside's module
patterns inform subsystem boundaries; its web/HTTP layout is not a requirement
to create empty directories or web adapters in Bee.

## Placement and ownership

User launch instructions use the globally installed `bee` executable. For an
editable checkout, `make run WIPPY="$PWD/.wippy/bin/bee-wippy"` runs source through
the development launcher in the repository directory. This is separate from
normal `bee` launches, which preserve the caller's project directory. Build and
install the executable using the README before testing global launch behavior.

| Location | Owns |
|---|---|
| `src/_index.yaml` | Host composition, resources and protected admission/policy wiring |
| `src/core/workspace` | Workspace persistence and checkpoint decoding; historical combined actor exists only in upgrade fixtures |
| `src/core/host` | TTY-free workspace host, client admission, renderer grants and live inventory |
| `src/core/launch` | Local physical startup helper and separate TTY-free supervisor: admission, presenter selection and coordinated exit |
| `src/core/client` | Desktop client, public command entry, qualified layout, owned client store and question projection |
| `src/core/interaction` | Bounded host/client question envelopes and host-owned delivery state |
| `src/core/session` | Committed desktop projection |
| `src/core/applications` | Admission, app lifecycle, producer capabilities and operation routing |
| `src/core/desktop` | Pure scene/reducer/layout values |
| `src/core/protocol` | Private core message decoders |
| `src/core/terminal` | Replaceable presenter, input and composition |
| `src/core/storage` | Workspace database and migration ledger |
| `src/ui` | Optional app-facing lifecycle helper, appearance and rendering values |
| `src/threads` | Native local journal contract, typed consumer, owned SQLite store and the first declared module root with its `target_db` hole |
| `src/sync` | Owner-local projection/event/receipt ledger and pure typed synchronization protocol |
| `src/node` | Authorized editable native-node descriptions and their public metadata trait |
| `src/apps/<name>` | A default app process and its own view/domain helpers |

Registry IDs are public identities independent of file location. Existing
`bee.desktop:appearance` and `bee.application:client` live in `src/ui`; preserve
their IDs. `main.lua` is an actor entry point, `app.lua` a default app entry point,
and `view.lua` a renderer. Use domain names for helpers, not generic `utils.lua`.
Extract by responsibility when an actor grows; do not create a universal manager.
Public local launch uses the verified host/client path. The broker
owns application questions; host interaction delivery selects eligible clients,
and the client inbox translates native view identities into its own tab identities.
The presenter owns only dialog rendering and input. Keep admission and question
authority out of that presentation layer.
`bee.terminal:display` is the stable owner's physical display adapter. Its surface
and viewport handles remain inside that owner; only a native viewport grant goes
to a presenter. It handles boot, frame forwarding and the paused frame, while the
owning actor decides when to restart a presenter or end the desktop.

`bee.terminal:delivery` owns asynchronous attachments and serialized per-view
input/resize queues within the presenter actor. Rendering reads cached content;
remote operations must not block the input loop. Only adjacent unsent resizes
coalesce. Retired operations retain their memory charge until completion; failed
or uncertain input is not retried automatically. Rejected input must request a
redraw so its error becomes visible without another terminal event.
The native remote viewport's `snapshot()` reads its local cache; it does not
perform a request to the remote host. Check that runtime contract before moving
snapshot reads into extra coroutines or introducing another polling layer.

Core may import core/shared UI, shared UI may import shared UI, and apps may
import their own helpers/shared UI. Apps may import the public `bee.threads:client` and `bee.threads:protocol`.
The application envelope additionally imports the pure `bee.threads.records:bounds`
decoder for opaque thread IDs; its complete closure must have no runtime
modules or security policy. This does not admit thread
storage or service imports into core. Carrier and native placement share the driver resolver and configuration
boundary, plus `bee.gateway:configuration`; gateway operations still go through contracts.
Apps must not import private broker or store implementations. Keep pure reducers free of registry, process, SQL and terminal
side effects. Review module boundaries in code review; verify permissions,
persistence and recovery through behavioral tests.

For a future independent subsystem, add only the slices it actually needs:
`service/` for its process owner, `persist/` for owned storage, `migrations/` for
its schema, `binding/` for contract adapters, `traits/` for agent adapters, and
`registry/` for discovery projections. Avoid parallel `tools/` and `agent/`
folders implementing the same operations. A subsystem declares its module root
in place, an `ns.definition` with a README and `ns.requirement` holes with
enumerated targets, before it is extracted; `src/threads` is the first. Current
folders are still not separately published Hub packages, and versioned
dependencies belong to the extraction change. The runtime linker leaves a
dangling requirement target unfilled without an error, so a module must refuse
to run on an unlinked reference and prove that in its standalone test.

## Types and messages

Use explicit record types for domain values and exported functions. Treat decoded
JSON and incoming message bodies as `unknown` until validated. Do not use casts
or `any` to bypass validation. Bound strings, arrays, state and pending requests;
reject invalid versions and geometry before changing state.

Authenticate `message:from()` and the relevant instance/token or operation grant.
A PID in a payload is not authentication. Keep request IDs, instance IDs, view IDs,
execution PIDs, revisions and resume schemas distinct. A successful send means
queued, not ready, committed or stopped. Report asynchronous completion explicitly;
timeouts can leave an uncertain outcome and must not trigger blind retries.
Structural workspace-to-broker/session control uses the local owner's checked
delivery boundary. A rejected structural send ends that owner through its save
path with the topic and request ID when available. Ordinary app open/close and
quit-preparation failures instead return an error without ending running apps.
Do not introduce an unchecked control send that
leaves a restore, close or receipt waiting forever. Presenter snapshots may be
reconstructed; remote reconnection requires its own attachment contract.

Use `process.listen(topic, {message = true})` and `channel.select` as in the current
actors; unregister listeners on exit. Wippy 2 semantics must be proved against
the selected runtime/linter before adoption. The candidate Hive supervisor uses
`process.listen(topic, {message = true, type = T})` from runtime PR #718 and
`message:data()` for the checked value. Remote v1 payloads remain maps, validated
against the receiver-local type before delivery. Domain bounds and native sender
authorization remain separate; the release pin has not yet adopted this API.
Keep rendering derived from committed
values; transient drag prediction belongs only to the presenter.

## Authority and persistence

Declare runtime modules and registry imports explicitly in `_index.yaml`.
Protected host bindings select app policies; app metadata cannot grant them.
Default to the smallest exact resource/action scope. Shared helpers carry no
publication authority. Native execution is not confined by a Lua permission scope.

Only the workspace opens the primary store. Apps use the checkpoint protocol and
own their opaque JSON schema. Append migrations; never change an applied SQL body
or checksum. Keep registry code/configuration history separate from workspace
state. A subsystem must own its tables and migration lifecycle; sharing a SQLite
file is not permission to query another owner's tables.

## Verification and documentation

`make setup` builds the pinned runtime; `make lint` checks typed production entries;
`make check` runs model/protocol, storage and source/pack PTY checks.
For a confirmed stale Lua cache, preserve a reproduction first, then use
`make lint LINT_FLAGS=--cache-reset`. Normal lint remains cached and strictly typed.
`make desktop-check` runs the desktop acceptance portion against an already built
pack; use `make pack` first when registry entries changed. `make attachments-check`
is the focused host/broker grant and revocation gate.
Use focused tests during implementation and the full suite for a behavioral
foundation change. `make test` first builds the Go HTTP helper used by the
Claude protocol fixture; the executable stays ignored and outside production. Test fixtures stay outside `src/` and use disposable databases.
Python acceptance boots use `tests/workspace.py::database_environment` to assign
all subsystem stores to the disposable fixture directory; explicit migration or
client-store overrides remain local to that fixture.
Keep tests separate in `tests/lua` and `tests/*.py` for the current pack boundary;
do not mechanically copy Kickside's colocated test convention into production.

Test negative permissions and failures, not only successful UI frames.
For a changed component, prove its public operations through its real host
wiring as well as its pure models. A standalone harness must supply the
declared resources, apply the actual migrations when the component owns a
store, and demonstrate that missing bindings and unauthorized callers are
refused. Exercise retry, restart and cancellation at the boundaries affected
by the change; a constructed completion record does not prove native process
cleanup. Test reports must count executed cases, not merely registered suites.
Inspect the assembled release packs for test registrations, fixture data and
test-library dependencies, including any explicitly embedded filesystem assets.
Source layout and a passing unit count alone do not establish release acceptance.
The headless acceptance also inspects service failure events from the actual boot;
workspace readiness and a clean exit do not excuse a failed background service.
New runtime patches require upstream Go tests, a refreshed checksum and a clean pinned build.
`make -C native patched-check` tests native source against the manifest runtime.
It resolves that runtime's dependency graph in temporary copies of `go.mod` and
`go.sum`, then runs race tests and vet with read-only module resolution. The
repository's module files remain unchanged.
Pure documentation edits need link/source consistency checks, not a repeat of
every PTY test. Update current status/contracts with the code, including limits
and unimplemented guarantees. No machine-specific paths, secrets or local stores
belong in shipped configuration.

Standalone composition is explicit in `build/modules.json`. A child namespace
does not need `ns.definition`; each package has one root and enumerates its
owned namespaces. Adding a namespace requires updating that ownership file.
`make native-pack` freezes source, checks exact pack coverage and generates a
separate build manifest; `make standalone` passes it to the pinned builder.
`make pack` continues producing the single source/pack acceptance snapshot.
These are different artifacts with different ownership requirements. See
`NATIVE_DISTRIBUTION.md`; bundled modules are not independently published packages.

The release owner runs `make promotion-check MILESTONE=native-agents` from a
clean immutable commit with the exact runtime, rollback executable and five
provider inputs named on the command line. The target rebuilds the candidate,
composes existing source, pack, native, recovery, display, project-upgrade and
real-provider gates, and writes `dist/promotion-native-agents.json` only after
they all pass. The receipt records hashes and versions, never credential bytes,
and states that installation was not performed. Global installation remains a
separate explicit operation after reviewing that receipt.
Each real-provider recovery target fingerprints its admitted login/configuration
inputs before and after the run and refuses mutation. The receipt hashes those
preserved inputs after all live gates; it records only the presence and selector
for Claude's environment credential, never its bytes or a reusable digest.
