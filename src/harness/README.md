# bee.harness

Execution contracts for admitted work: the catalog discovers driver bindings,
the carrier prepares an admitted attempt, and structured or native-window
execution composes placement with the thread contracts.

## Slices

| Slice | Responsibility |
|---|---|
| `bee.harness` | Module root |
| `bee.harness.carrier` | `provenance`, `checkpoint`, `settle`: the pure rules of [the carrier contract](../../docs/CARRIER.md); `policy`: the host-selected launch policy with executable bindings and required capabilities; `machine`: one attempt from plan to receipt over an injected IO; `process`: the production carrier process, no fault hooks (a test-only entry wraps the same run with barriers); `capabilities`: bounds and the takeover rule |
| `bee.harness.launch` | `definitions`: exact decoding and digest of `bee.launch_definition` entries; `selection`: picker discovery plus component-owned CLI command lookup; `admission`: `resolve` (a measured plan pinning definition, binding, profile, policy and catalog generation, no effects), `admit` (for the authenticated requester: thread by policy, an attempt-bound resource grant and credential projections obtained in the requester's own authority, all keyed on the request id so a retry replays), `start` (spawns the carrier as the requester, resumes when a checkpoint exists, refuses a settled request) |
| `bee.harness.permission` | `adapter`: the pure permission exchange rules (request identity, proposal, qualified keys, response encoding, pending ambiguity, transcript consistency); `acceptance`: the host acceptance record binding driver, profile, adapter and fixture measurements. A profile is eligible with `permission_exchange: {mode: adapter, adapter_ref, adapter_digest}` pinning a `harness.permission_adapter` entry the catalog measures from the same snapshot; enabling needs a matching acceptance record proven by the live fixture runner in `tests/lua/harness/acceptance_test.lua` and, for Claude, by the real executable in `claude_acceptance_test.lua` and `claude_control_test.lua`. Request fields and response fields are dotted paths, a request may name a separate acknowledgment id (Claude echoes `tool_use_id`, not `request_id`), and a terminal denial may be correlated. Both Claude profiles pin `bee.driver.claude:permission_adapter`; the acceptance record (`bee.permission-acceptance@2`) also carries placement's `executable_digest`, compared at plan time; shipped launch policies enable no exchange, so a terminal permission-denied result remains terminal |
| `bee.harness.catalog` | `classify`: pure classification of a driver binding with its resolved profiles and methods; `catalog`: one immutable registry snapshot (`registry.snapshot()`), every `harness.driver` binding, declaration, method target and the host's `bee:harness_activation` entry read from that same snapshot, classified and marked activated |
| `bee.harness.window` | Broker-launched Agent application and public `agent` command. The reusable `runtime` library owns the managed-window lifecycle; each process entry supplies its fixed placement binding and a constructor returning a process-local window handle. The runtime rejects a different planned placement before action admission or placement preparation; request data cannot select a constructor. An empty launch opens the host-defined profile picker; a bounded measured envelope selects one directly. Both admit the broker-authenticated application actor, share planning and preparation with the carrier, and consume the broker's sole terminal grant for one native PTY. PTY exit records `uncertain` completion; explicit application close records `cancelled`. Neither proves a successful agent turn. |

## Rules

A binding is compatible when it implements `bee.driver:driver` with four
bound functions, its `profiles_ref` names a `harness.profile` entry that
points back at it, the declaration decodes under `bee.driver:profile`, and
at least one profile (the default among them) uses a supported protocol. Two
compatible bindings with one `driver_id` are both marked ambiguous. Digests
measure the entry and the declaration only and say so; executable closures
are measured at admission. Compatible is not activated, and activated is not
admitted: the host lists activated bindings in `bee:harness_activation`, and
launch admission decides per request. That entry is a strict
`bee.harness-activation@1` declaration containing only distinct `bindings`.
A missing or malformed declaration activates nothing and adds a catalog
diagnostic; it cannot publish, admit or authorize execution. A read capped below the number of
bindings is `complete: false`: an unseen binding could share a `driver_id`
with a visible one, so `usable` resolves nothing from it.

Catalog compatibility matches the implemented execution paths: `stream-json`
for batch/session profiles, and `pty` for window profiles. Fixture metadata does
not change compatibility. Host activation and protected launch admission remain
required; compatibility alone does not publish a launch route or authorize it.

Launch resolution and admission read the definition, catalog and policy from
one registry snapshot. The library's `admission.read(snapshot, ref, mode)` lets
a composing host reuse its pinned snapshot without side effects; ordinary
`resolve` and `admit_request` pin internally. A retained snapshot describes its
own generation even after registry changes. Reading that plan grants no
permission and does not promise that a later execution will use stale code.
A caller selecting a resolved plan passes its `plan_digest` back as
`expected_plan_digest` on admission/start (or in the managed window request).
Admission compares it with the current measured plan before creating a thread or
obtaining grants and projections; a changed definition, binding, profile or
policy returns `CONFLICT`. The digest is a consistency check, not permission.
An immediate launch with no prior selection may omit it and resolves current
host configuration. A selector must retain the digest until start and require a
fresh selection after conflict; it must not silently drop the check on retry.
Managed launch requests accept no environment map, including an empty one.
Nonsecret environment and driver options come from the selected host policy;
credentials are projected separately by the broker. The lower carrier and
placement contracts remain separate execution primitives.

Launch admission resolves the `bee.placement:placement` contract from the
same pinned registry snapshot as the driver and launch policy. The resulting
plan records the selected binding ID, its digest and all contract method
targets; the carrier routes every placement operation through those targets.
The binding ID is copied into the durable `attempt.prepared` record, so
continuation, interrupted-window recovery and checkpoint resume refuse a
changed placement selection. Registry metadata describes the implementation
kind but does not authorize it. Native window code additionally requires the
exact native binding ID before opening a terminal.

After a profile has been selected, `bee.harness.launch:setup` accepts its
workspace, definition and measured plan digest. The caller needs the scoped
`bee.harness.setup` action; the facade remeasures the plan before it enters a
fixed setup scope. That private scope can associate/list resources and
define/list credentials. It reloads the selected definition under its measured definition
digest, then creates its declared `project` and `session` associations with
create-if-absent revision zero. A retry accepts only the same root, empty
subpath and writable association, and refuses a mismatch. Definitions with no
declared resources or credentials succeed without consulting the host setup map. The host maps
the declared names to admitted roots; driver metadata cannot choose a root or
grant management permission. Admission subsequently uses the ordinary resource
grant path, which verifies the root digest before issuing a grant.

## Host binding

The `process_host` requirement links `bee.harness:carrier_host_ref.host_ref`.
Launch start resolves that process host before admission and refuses an unlinked
or missing host. The bundled host defaults to `bee:workers`; another assembly
can supply its own host. This reference grants no permission: the host-selected
spawn policy must independently allow the carrier and selected host.

The entry policies still bind `bee:carrier_policy` and
`bee:launch_spawn_policy`. Independent installation must supply those reviewed
policies; host binding alone is not Hub or Hive installation acceptance.

## Agent profile picker

Agent activity belongs on the existing application title surface:
`bee.application:client.title`. Bee-native applications use that same API.
Committed harness hooks supply fixed activity labels such as `Working`,
`Using tool`, `Stopped` and `Needs attention`. Ambiguous observations show
`Activity uncertain`; hook stops never imply a successful attempt. Prompt text
and tool arguments cannot become titles. The selected profile name stays in
the title, bounded with the existing text sanitizer. Updates follow a confirmed
thread commit; claims, failed commits and stale replies cannot publish activity.
An actual native-child/gateway/broker fixture proves the resulting title update.
This source change is not part of the installed `edf6a7c3` checkpoint.

Native CLI terminal-title sequences are a separate source. Selected runtime
`291f5c6b` does not expose VT title changes through `exec` terminal sessions;
the proxy currently forwards mode and cursor callbacks. Forwarding those titles
needs a runtime terminal-session capability, not a second ANSI parser in Bee.

A profile describes **harness + isolation + options + MCP scope**. The shipped
defaults are registry declarations owned by the separate driver components.
Editable DB-backed profiles and policy-controlled exchange through `bee.sync`
are planned, not implemented. Shared configuration must not contain host paths,
credential bytes or live process/session handles. Launch context uses the
existing runtime `ctx` module and is resolved for each invocation; it is not a
static profile payload or permission grant.

Opening `bee.harness.window:app` with no arguments (the `agent` command) presents
window launch definitions marked for the Start menu whose driver is activated
and compatible. The bounded `selection` reader uses one registry snapshot and
projects only the definition reference, title, launch ID and plan digest.
Hidden and non-window definitions do not become choices; discovery grants no
execution permission and does not promise resource or credential readiness.

The picker supports arrows, Enter, wheel selection, mouse actions, refresh and
Escape. It uses the display's appearance, sanitizes label controls and disables
launch when the window cannot show a choice. Selecting a changed plan clears the
list and requires an explicit refresh and selection; no attempt is created.
Before native execution, it closes its drawing surface and keeps the same input
subscription and broker terminal grant. Existing measured request envelopes
still select a profile directly through admission.

The component-owned `command_names` route `bee claude`, `bee codex`, `bee agy`
and `bee grok` to this same application and admission path. Command discovery
returns only a definition reference and presentation preference; the Agent actor
then resolves and fences the current plan before setup or admission. Valid
duplicate claims refuse, and managed aliases accept no raw trailing arguments.
An empty catalog displays an empty picker; it does not infer executable paths,
credentials or a launch policy from registry metadata.

Launch definitions may name `session_resource: <host-resource>` to retain
provider state. Admission derives a bounded identity from the workspace and
launch request and obtains a writable
`purpose: session` grant for the authenticated application actor and that
attempt. Retries with the same request ID reuse the same session identity and
grant. Without this field, placement uses its normal per-attempt home.
Placement selects the retained session home from the
grant. The host resource association must be writable and available before
child launch, and callers cannot provide a session resource or grant.

Placement excludes concurrent unfinished attempts from a retained owner/session
home. Driver-owned configuration delivery gives each admitted attempt fresh
argument literals and protected files. Claude carries per-attempt MCP/settings
configuration inline; retained Codex files permit only byte-identical replay.
The carrier can resolve a committed provider conversation reference and launch
admission can obtain fresh grants for continuation. The Agent app checkpoints its
launch identity, selected profile revision and previous attempt using
`bee.agent.window@1`. Restore shows a responsive, themed view while typed admission
runs in a coroutine owned by the same application process. Closing that view
prevents the returned admission from reaching native preparation. UI readiness
does not mean the harness has started or recovered successfully. If the saved
launch plan digest is fenced by a changed registry plan, restore resolves the
current definition, profile and placement for display and pauses for an explicit
Enter confirmation. The confirmation admits the current digest with the saved
continuation identity and its reauthorization marker; a later stale conflict
returns to the review instead of retrying automatically. Esc, close and Ctrl+Q
cancel without changing the checkpoint.

An interrupted attempt is recoverable only after placement observes the recorded
native process exit. Recovery obtains a fresh carrier epoch, commits the rebound
checkpoint, seals intake and reconciles recoverable hook deliveries, then records an uncertain attempt
outcome. Continuation still requires a consistent committed provider conversation
reference and independently proven process-group cleanup. Occurrence ambiguity
does not erase a validated session claim, while conflicting claims refuse
continuation. It retains the session home and obtains fresh admission for the
replacement attempt. Failure or incomplete
hook draining refuses replacement; a copied checkpoint grants no authority.
The gateway retains terminal rejection of unclaimed hooks on revocation; accepted
intake is not a guarantee of thread commitment. Already-claimed rows remain
recoverable under its existing epoch fences.
These paths have fixture-harness acceptance in a live runtime. Whole-runtime crash
and real-provider cold conversation recovery remain unverified. See
[the recovery handoff](../../docs/handoffs/NATIVE_AGENT_RECOVERY.md).

If planning, preparation or native startup fails after the Agent actor is
admitted, the actor keeps a bounded error surface until the user closes it.
Resize and close remain available while the failure is shown; the app does not
retry the launch. Planning failures create no lifecycle receipt. After confirmed
admission, it attempts a receipt for the new action or prepared attempt and
revokes its admitted gateway. A confirmed placement intent is stopped and cleaned
through placement's existing proof rules; an unstarted intent releases its session
without creating or deleting files. Failed cleanup or settlement remains visible.
These calls run asynchronously inside the app actor. Closing during settlement
can cancel them and leaves the result unconfirmed; there is no separate durable
settlement worker or automatic retry. The failure view makes that pending state
explicit and continues to accept resize and close input.

First-use setup also prepares definition-declared credential names from the host's
`bee:harness_setup.data.credentials` map. Each value selects a provider and a
`source: {kind, ref}` accepted independently by the credential broker. Setup uses
`define(expected_revision = 0)` and accepts an existing matching definition;
it never replaces a differing definition or reads secret bytes. The fixed setup
scope admits only the resource and credential define/list operations it needs.
Missing credential configuration is refused before creating resources. A later
operation failure may leave earlier creations intact; retries reuse them.
Production's credential map remains empty, so this does not yet discover or
project the user's machine login automatically.

The Agent picker source now summarizes the selected measured profile: project or
configured directory, whether persistent profile instructions are selected, and
the number of configured gateway tools. It reads that summary from the same
immutable registry snapshot as admission planning. Counts describe configuration,
not a live MCP listener or granted authority. Instruction text, environment values
and credential contents are not included in the summary. Compact windows retain
the existing list and actions without the summary row. This UI addition passes the native Agent selector acceptance, including the
summary before launching Claude/Codex and retained session/login behavior.
The initial unit run passed 772 cases; the final selection/view check passed
14 cases including exclusion of private instruction text.

The saved-profile facade under `bee.harness.profiles` now stores workspace-scoped
preferences through the existing node-owned sync ledger. The picker and launch
admission carry the selected profile ID and revision; a changed profile cannot
silently alter a restored conversation. Store access grants no workspace read or
write authority. See [saved profiles](../../docs/handoffs/SAVED_AGENT_PROFILES.md)
for the verified boundary, retention limits and remaining integration gates.
