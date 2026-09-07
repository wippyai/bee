> Historical Bee source paths in this study are relative to `../bee-legacy/`,
> outside this repository. They are references, never boot dependencies.

# Platform study and implementation preparation

Study date: 2026-09-07. Design output: [Desktop foundation](DESKTOP_FOUNDATION.md).
No production rewrite, package installation or Kickside mutation was performed
as part of this study. Source inspection is evidence of available mechanisms,
not proof that an entire module closure already runs in the Bee host.

## Source baseline

`~/kickside` contains several worktrees. Its `core` and `platform` symlinks point
into `kickside/kickside`, whose inspected HEAD is `e672e58b8` (2026-08-15).
For the architectural reference this study used `kickside/main`, inspected HEAD
`6c994a67c` (2026-08-30), and its developer documentation. Provider KB10 was
inspected separately under `kickside/providers/kb10`. Compatibility work must
pin a coherent module closure rather than mixing whichever worktrees look newest.

The relevant Kickside AGENTS.md identifies registry documentation entries as
canonical in a running environment; checkout sources live in
`app/src/app/docs/`. This study used checkout sources, not a live registry.
The most relevant pages are `00-canonical-model`, `01-component-development`,
`02-contracts-and-ports`, `18-blocks-flows-workflows`, and
`19-discovery-addressing-and-context` under `kickside-development`.

## Findings that affect the design

| Evidence | Implication for Bee |
|---|---|
| Kickside canonical model distinguishes package, registry declaration, component instance, private context, public meta, events and views | Keep these identities and data planes separate; do not use window IDs or registry searches as resource identity |
| `main/core/component/src/component.lua` opens instances through access-checked contracts | A Bee resource adapter should call the component authority, not copy its SQL or private-context access |
| `main/core/component/src/migrations` and `main/core/core/src/migrations` include SQLite and PostgreSQL paths | A local SQLite compatibility spike is justified; no automatic need for a new component/event engine |
| Component/core declarations require DB, router, scope, host, environment and lifecycle wiring | Reuse still requires a real minimal host and correct policy binding; a module import is not a complete installation |
| `main/platform/models/src/_index.yaml` owns DB/cache provider profiles and model overlays independently | Model administration is a subsystem with its own UI and resolver; its DB/cache overlays are not automatically runtime registry overlays |
| `main/platform/knowledge/src/engines.lua` resolves engine declarations and exact bindings | Add a KB engine through its owned contract/catalog, not a desktop hardcoded engine list |
| Knowledge declares uploads, core, agent/dataflow/LLM/views dependencies and authenticated router requirements | Full Knowledge is not a tiny standalone widget; inspect the closure before promising immediate embedding |
| `providers/kb10/src/migrations/01_kb10_schema.lua` contains PostgreSQL vector/full-text constructs | Component/core SQLite support does not prove KB10 is SQLite-ready. Verify its separate SQLite path/extensions and workload before choosing local packaging |
| Kickside Blocks lower to native Dataflow; visual Workflows is optional | Do not build a second DAG scheduler inside Bee or force every utility to install the visual workflow product |
| Keeper `hub/service.lua` separates planning, publication, migrations, install/uninstall steps and failure handling | Reuse its contract/receipt discipline for live install; do not copy the whole Keeper UI into desktop core |
| Keeper MCP has separate auth, surface, trait validation and session state code | MCP can be an independent transport subsystem over common admission; it need not define Bee's core API |
| Runtime `system/registry/overlay.go` enforces owner/generation and rejects directive-owned overlay kinds | Saved experiments need durable source/activation records; Hub mounts use the durable install lane |
| Runtime tty PR #653 and shutdown PR #655 handle shared rendering/lifecycle defects | Keep terminal defaults and scheduler behavior in runtime; avoid Lua compensation layers |

## Honest Bee baseline

The current desktop provides useful UX evidence: colours, windows, four-corner
resizing, focus, fullscreen, menu bounds, scrolling, themes, app discovery and
simulation views. It is not the production architecture described in the older
roadmap. Latest demo verification at this study boundary: 282 tests and clean
lint; these tests do not certify a production authority or durable run system.

Specific source gaps:

- `poc/shell/src/shell/windows/manager.lua` owns application spawning, carrier
  attachment, layout, page policy, catalog refresh and relaunch logic together.
  The new desktop must separate these responsibilities, not move this file.
- `os-thread/src/journal.lua` reads the previous digest and inserts separately.
  This does not establish serialized per-thread append under concurrent writers.
  Independent chats now have durable IDs, but membership, replay cursors and
  recovery are not yet a complete thread service.
- `os-session/src/core.lua` has an in-memory carrier table and a same-PID upgrade
  path. It is not yet a cold-boot run/service reconciler with fenced attempts.
- `os-gateway/src/mcp.lua` uses action-addressed routes and a fixed TOOLS table;
  `granted()` treats absent and empty lists as unrestricted. `listChanged=false`.
  The inspected host router has no authentication middleware declaration, and
  handlers execute with the broad app runtime policy. Do not call this a secured
  multi-actor access plane.
- `poc/shell/src/_index.yaml` and `host/src/_index.yaml` grant broad runtime actions
  including registry publication over `*`. Split actual authorities before
  treating installed or agent-authored code as isolated.
- `os-publication/src/apps.lua` allows the broad `casha` prefix and applies a
  snapshot changeset; it does not bind a reviewed candidate, actor-specific
  namespace grant, isolated-test receipt and upgrade plan into one admission.
  Its whole-version rollback is not application-scoped migration rollback.
- `driver-kit/src/kit.lua` has machine-specific homes/endpoints and a fixed tool
  list. External drivers implement useful prepare/command/parse/resume behavior,
  but placement and authority need an independent executor contract.
- `os-harness/src/session.lua` records external session references, but a full
  admitted cold-reopen recipe and instance recovery policy are still required.
- Training/mesh/trace/artifact demos are fixture renderers, not live domain
  services. Retain them as acceptance fixtures and optional examples.

## Reuse decisions and bounded spikes

1. **Wippy is the substrate.** Keep registry/history, contracts, execution,
   scopes, process supervision, Dataflow and tty. Add runtime work only when a
   platform invariant cannot be expressed or a demonstrated defect exists.
2. **Prefer Kickside resource/event authorities after proving the minimal host.**
   Mount pinned `kickside/component` and `kickside/core` against isolated SQLite;
   wire DB/router/scope/host/lifecycle requirements; create/open one resource,
   deny another actor, append/replay concurrent events, restart, delete cleanly.
   If this fails, document the exact missing seam and fix/extract that seam.
   Do not preemptively create a competing universal records framework.
3. **Keep public Bee application/view DTOs small.** A component ID can be their
   durable resource reference; domain modules still own domain contracts. If a
   migration is necessary, keep old journal refs as explicit aliases. Use one
   authoritative write path, not indefinite dual-writing of old/new histories.
4. **Models is an early independent subsystem.** Reuse resolver/provider contracts
   from Wippy/Kickside; implement only the adapter that Bee's host requires.
   A view can edit profiles, and an authorized materializer can update supported
   runtime model entries. Desktop appearance settings never become model admin.
5. **First KB integration is contract-level.** Prove one actor-scoped query/create
   path with an actual pinned engine and required storage. Supply a native Bee
   view over it. Existing browser components require a compatible web host or
   browser view adapter; they do not become tty components through an overlay.
6. **Keeper is the live-install/authoring reference.** Inspect/reuse its governance
   and Hub seams, with a minimal host adapter. Expose plan/apply/status to the
   desktop; keep protected authority outside experimental code. Component install
   must be observable in the already-running shell, including failed activation.

## Independent subsystems after the desktop contract is stable

| Subsystem | Stable boundary | First proof |
|---|---|---|
| Threads | Create/read/append/subscribe, membership, correlated outcomes | Two conversations remain isolated and reopen after restart |
| Local chat | Conversation view + admitted local-agent invocation | Two windows, different threads; restored selection, no resubmission |
| External agents | Session/turn driver + executor placement + admitted tools | One harness reconnects/resumes and reports on its originating thread |
| MCP | Authenticated session → normalized tool surface → admitted dispatch | Denied/empty/revoked grants, tool refresh and alias collision handling |
| Models | Catalog/resolver/provider operations | Profile change refreshes available models without desktop restart |
| Promptmap | Typed map/query operation and durable run/artifact references | Same invocation and report from UI and agent |
| Script runs | Launch/observe/control/artifact protocol | Real local Python fixture, no GPU needed, survives view close |
| KB | Kickside component + engine contracts | Query allowed resource, deny unshared resource, view result in Bee |
| Publication | Candidate/validate/test/commit/activate/status | Live experimental edit and durable install, failed upgrade recovery |

“Same tools” means the same admitted operation identities and schemas through
native and MCP adapters. Human-friendly aliases can remain identical across
harnesses; reject ambiguous aliases rather than silently picking a tool.
Tool visibility is distinct from resource authorization and from execution
confinement. A native command with a working directory is not folder-sandboxed.

## Real Python adapter, when desktop is ready

A definition declares exact executable/argv, input schema, resource references,
placement requirements and optional view. Admission resolves those references
and starts a logical run with a fenced attempt. No implicit shell expansion;
shell execution is a separately declared operation.

Start with unchanged scripts: capture bounded stdout/stderr and exit status.
Offer an optional JSONL event channel or small helper for `progress`, `metric`,
`artifact` and `checkpoint`. Validate schema and size; distinguish inferred
progress from reported metrics. Time-series samples may be aggregated/stored
separately from durable lifecycle events. A dashboard and agent rundown read
the same run projection. No scrape-the-screen path.

Pause/checkpoint/resume are capability declarations, not promises made for every
Python process. A completed process is not necessarily a successful logical
request: record exit, result validation and uncertain external effects. Closing
the view preserves the run. Restarting Bee marks lost attempts explicitly and
never blindly repeats commands. Services add desired state, readiness and retry
policy; scheduled invocations can use existing cron/Dataflow instead of a new
scheduler.

## Scope for a productive first day

The project is larger than a day. The useful first-day outcome is a reviewed
contract and a working production vertical slice, not every subsystem renamed.
Prioritize D0/D1 from DESKTOP_FOUNDATION.md, then one live-editable fixture:
boot a minimal host, open two views, edit one authorized experimental view,
observe its refresh, save/reboot/rematerialize it, and deny an ungranted actor.
The existing POC remains a comparison fixture until D4, not a production dependency.

After this slice, delegate only bounded packets with frozen contracts. Example
specification fields for any Grok/agy/other child:

```
Objective and exact observable behavior
Base commit / contract revision
Owned files and permitted dependencies
Input/output and error/event schemas
Authority and state ownership
Lifecycle / upgrade / failure behavior
Non-goals and forbidden shortcuts
Required tests and live fixture
Return: changed files, test evidence, limitations, integration notes
```

The integrator owns architecture and acceptance. Child agents can implement
independent reducers, adapters, widgets and tests; they cannot invent divergent
core protocols or elevate their own publication authority.
