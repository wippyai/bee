# Development conventions

These conventions apply to Bee, a typed Lua terminal desktop. Kickside's module
patterns inform subsystem boundaries; its web/HTTP layout is not a requirement
to create empty directories or web adapters in Bee.

## Placement and ownership

| Location | Owns |
|---|---|
| `src/_index.yaml` | Host composition, resources and protected admission/policy wiring |
| `src/core/workspace` | Physical terminal lifetime, bootstrap and durable recovery orchestration |
| `src/core/session` | Committed desktop projection |
| `src/core/applications` | Admission, app lifecycle, producer capabilities and operation routing |
| `src/core/desktop` | Pure scene/reducer/layout values |
| `src/core/protocol` | Private core message decoders |
| `src/core/terminal` | Replaceable presenter, input and composition |
| `src/core/storage` | Workspace database and migration ledger |
| `src/ui` | Optional app-facing lifecycle helper, appearance and rendering values |
| `src/threads` | Native local journal contract, typed consumer and owned SQLite store |
| `src/apps/<name>` | A default app process and its own view/domain helpers |

Registry IDs are public identities independent of file location. Existing
`bee.desktop:appearance` and `bee.application:client` live in `src/ui`; preserve
their IDs. `main.lua` is an actor entry point, `app.lua` a default app entry point,
and `view.lua` a renderer. Use domain names for helpers, not generic `utils.lua`.
Extract by responsibility when an actor grows; do not create a universal manager.

Core may import core/shared UI, shared UI may import shared UI, and apps may
import their own helpers/shared UI. Apps may import the public `bee.threads:client` and `bee.threads:protocol`.
Apps must not import private broker or store implementations. Keep pure reducers free of registry, process, SQL and terminal
side effects. `tests/architecture.py` checks the production import graph.

For a future independent subsystem, add only the slices it actually needs:
`service/` for its process owner, `persist/` for owned storage, `migrations/` for
its schema, `binding/` for contract adapters, `traits/` for agent adapters, and
`registry/` for discovery projections. Avoid parallel `tools/` and `agent/`
folders implementing the same operations. Package manifests, requirements and
versioned dependencies belong to the package extraction change; current folders
are not separately published Hub packages.

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

Use `process.listen(topic, {message = true})` and `channel.select` as in the current
actors; unregister listeners on exit. Wippy 2 semantics must be proved against
the pinned runtime/linter before adoption. Keep rendering derived from committed
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
`make check` runs model/protocol, storage, architecture and source/pack PTY checks.
Use focused tests during implementation and the full suite for a behavioral
foundation change. Test fixtures stay outside `src/` and use disposable databases.
Keep tests separate in `tests/lua` and `tests/*.py` for the current pack boundary;
do not mechanically copy Kickside's colocated test convention into production.

Test negative permissions and failures, not only successful UI frames. New runtime
patches require upstream Go tests, a refreshed checksum and a clean pinned build.
Pure documentation edits need link/source consistency checks, not a repeat of
every PTY test. Update current status/contracts with the code, including limits
and unimplemented guarantees. No machine-specific paths, secrets or local stores
belong in shipped configuration.
