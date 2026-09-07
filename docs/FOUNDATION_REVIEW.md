# Foundation critique — 2026-09-07

Historical baseline review: `ddf6ba8`. The subsequent sweep is documented in
[foundation status](FOUNDATION_STATUS.md) and [contracts](APPLICATION_CONTRACTS.md).
The findings below retain their original baseline wording.

Reviewed baseline: `ddf6ba8`. This is a review, not an implementation or a claim
that the issues below have been fixed. Source was inspected across core, shared
UI, bundled apps, protocols, tests and packaging. The baseline's 34-test suite and
source/pack acceptance had passed in the preceding implementation round; they
were not rerun for this review. A separate disposable PTY confirmed finding 1.

The foundation is suitable for continued internal development. It is not ready
to freeze a public application API or admit arbitrary agent-authored packages.
Its strongest properties are the pure window model, process-separated apps,
capability-based terminal delegation, stable physical-terminal ownership and
actual source/pack recovery tests. Keep those properties.

## Findings

### 1. High: a navigation key can exit the workspace

`src/core/terminal/menu.lua:118` routes both Enter and Right through `activate`,
which runs a leaf action as well as entering a group. Reproduction: open Start,
select Exit with End, press Right. Bee exits with code 0. The same behavior can
activate Close in a window menu. Restrict Right to entering groups; leaf actions
need Enter or click. Add a regression for navigation over destructive items.

### 2. High before app extensions: spawn, ready, close and stopped are conflated

`src/core/applications/broker.lua:231` spawns an app and then replies with `open`
once its mount exists. There is no app-ready acknowledgement, launch deadline,
startup-failed state or running definition revision. A spawned process that never
presents a frame is still treated as an opened app.

At `broker.lua:61`, disposal removes the instance record before sending close,
requesting termination and closing its viewport. Return values are ignored, and
callers report closure without observing EXIT. This is adequate only for the
current disposable view-owned apps. It is not a sound completion contract for
editors, terminals, checkpoints or services.

Define explicit lifecycle states and distinguish close-view, stop-instance and
force-stop. Normal close needs a bounded cooperative path and an observable stop
result. This must not make workspace exit wait serially for every app; durable
checkpoints should be maintained during operation.

### 3. High before public contracts: identity is allocated too late

`broker.lua:239` allocates `id` and `instance_id` after the app has been spawned.
The app receives only broker/owner PIDs. There is no launch envelope containing
its logical identity or the definition revision it is executing. Today a broker
record couples an instance, process and viewport one-to-one.

Allocate logical identity before spawning and pass a versioned launch envelope.
Keep instance, execution and view distinct even if this release allows only one
execution and one view per instance. Do not implement multi-view support merely
to make the distinction. Stable identity must be available before checkpoint,
restore, update, external attachment and service contracts are published.

### 4. High before installable apps: the core still contains app policy

`broker.lua:51`, `:108`, `:137`, `:188` and `:225` special-case Settings and Process
Manager for capabilities, messages and singleton reuse. `terminal/main.lua:88`
and `terminal/menu.lua:10` hard-code their launch actions. A third app needing
appearance, singleton behavior or a lifecycle operation requires core edits.

Introduce a validated application descriptor and protected admission binding.
The descriptor supplies identity, contract version, title/icon, placement in the
launcher, instance policy and supported lifecycle contracts. Protected policy
supplies actual grants. Metadata must not be allowed to approve its own
privileges. Move appearance observation and authorized preference mutation behind
a general core protocol; the process inspector should not speak a Settings-app
protocol just to inherit the theme.

### 5. High before untrusted code: bootstrap authority remains an assumption

`src/core/session/main.lua:7` and `broker.lua:38` accept an owner PID argument and
subsequently authenticate messages against it. The current trusted composition
creates these processes with explicit scopes, and bundled apps cannot spawn
arbitrary processes. That limits current exposure; this review does not establish
a privilege escalation from a bundled app.

Before adding agent-created packages, constrain private-core spawn targets and
bind bootstrap ownership to authenticated runtime context or a capability.
Separate application definition identity, process sender identity and user/agent
principal identity. Review `src/_index.yaml` resource wildcards in that concrete
threat model. A caller-provided owner string is not an authority proof.

### 6. Medium: protocol types describe containers more than operations

`src/core/protocol/decode.lua:4` has one reply record with `op: string` and many
always-present empty fields; the broker duplicates that type. Session commands
are decoded inline (`session/main.lua:23`) and floor numbers without the bounded,
finite checks used by the scene decoder. Requests carry no protocol version.
Some paths correlate request IDs; others use a preference-value string
(`src/apps/settings/app.lua:71`). Errors are display strings rather than stable
codes.

Define discriminated request/reply types and centralized decoders. Specify
request correlation, completion, stale revisions, duplicate requests, rejection,
timeouts and process incarnation fencing. Include finite bounds in command
validation. UI input can remain optimistic, but failed delivery must settle its
pending intent. Do not require durable command logging for the shell merely to
standardize these contracts.

### 7. Medium: desktop state has several partial owners

The session owns windows and focus; `workspace/main.lua:52` owns tab order and
preferences separately and joins them into an envelope at `:77`. The presenter
keeps committed scene, predicted routing scene, pending intent, closing IDs and
drag state. That is real asynchronous complexity, not just long files.

Give each authoritative field one named owner and define the revision covering
the complete desktop projection. Prefer moving durable tab ordering and desktop
preferences into the desktop state owner, with the workspace retaining lifetime
and terminal responsibility. Keep transient input prediction and capture local
to the presenter. Extract routing/capture reducers and lifecycle helpers so their
state transitions can be tested directly; avoid creating new actors just to
split files.

### 8. Medium: capability failures can become false local state

At `terminal/main.lua:125`, the presenter records new producer dimensions even
when `view:resize` fails. Output presentation and many sends similarly discard
errors. Broker reattachment reports per-view errors, while workspace activation
is driven by the final bind reply without an explicit per-view recovery decision
(`workspace/main.lua:200`).

Audit fallible operations at ownership boundaries. Commit cached dimensions only
after successful resize. Keep failed attachment state visible and retryable.
Define which failures are benign stale events, which fail one app and which stop
the workspace. Avoid turning every transport call into a blocking round trip.

### 9. Medium: tests protect this composition more than an extension contract

`tests/architecture.py:22` checks imports for selected namespaces but omits the
workspace and application broker from that dependency rule. Exact app/entry lists
protect a clean pack, but do not prove that a new ordinary app can be admitted
without core changes. The test suite is valuable, especially real PTY rejoin and
intermediate-frame checks, but success is not proof of all message interleavings.

Add a deliberately uncooperative fixture: slow startup, early exit, failed
attachment, duplicate/reordered replies and termination during rejoin. Test
ownership invariants across transition sequences. Apply dependency rules to all
core modules and test contracts independently of the bundled app list. Keep
exact pack inventory checks as a separate composition assertion.

### 10. Medium before release: build and documentation contracts need finishing

`Makefile:1` and `run.sh:4` rely on an ignored local native executable or an
externally supplied one. The repository does not pin a reproducible compatible
runtime build or contain CI. A clean checkout cannot reproduce the development
runtime from the current instructions alone.

Pin the required runtime revision/capabilities, provide a repeatable setup and
run the existing checks in CI before tagging a release. This can precede the
single-binary distribution subsystem. Consolidate historical design notes into
one current ownership map, glossary and implemented-protocol reference. Keep
future subsystem designs explicitly separate from callable operations.

## Performance and composition limits

The presenter polls cached viewport snapshots on a 33 ms ticker
(`terminal/main.lua:47`, `:221`) and samples them again when painting. This is a
reasonable small-shell implementation, not evidence of a performance problem.
Before calling the foundation scalable, measure idle CPU, allocations, input
latency and redraw work at 1, 8 and 16 windows, including a noisy producer and
resize storms. Document the tested bound and backpressure behavior. Prefer
invalidation/events only if measurement justifies the complexity. Keep metric
sampling in the optional inspector and histories bounded.

Avoid a generic framework rewrite. The useful extractions are a small application
descriptor decoder, lifecycle reducer, input-routing/capture reducer and operation
contracts. Existing runtime registry, permissions, messaging and surfaces should
remain the primitives; Bee should not grow parallel registries or a new bus.

## Vocabulary to freeze

| Term | Meaning |
|---|---|
| Package | Versioned distribution unit containing registry entries and dependencies |
| Definition | Registry identity describing an app, service, library or resource |
| Revision | Exact version of code/configuration selected from a definition/overlay |
| Application | User-facing capability implemented by an admitted app definition |
| Instance | Logical app identity that can survive execution replacement |
| Execution | One running process incarnation; identified by a PID |
| View | One presentation endpoint of an instance |
| Window | Desktop placement, mode and focus metadata around a view |
| Viewport | Runtime terminal surface holding rendered content |
| Terminal mount | Recipient-bound delegation of viewport rights; not a filesystem mount |
| Workspace | Local identity, resource bindings and operational state boundary |
| Desktop state | Committed windows, tab order, focus and desktop preferences |
| Presenter | Replaceable process that draws the desktop and interprets input |
| Service | Supervised lifetime independent of whether any window is open |
| Overlay | Versioned source/configuration changes over a baseline; not app runtime state |
| Principal | User/agent security identity; distinct from a process PID |

Use `view_id`, `instance_id`, `definition_id` and `execution_pid` at boundaries;
avoid a generic `id` whose meaning changes by message. Reserve unqualified
“session” for an explicitly named domain: desktop session, terminal session and
agent conversation are different things. Core describes responsibilities, not
an exception that prevents authorized self-editing.

## Ownership target

| Owner | Authoritative responsibility |
|---|---|
| Workspace supervisor | Core process lifetime, physical terminal lease, shutdown/recovery |
| Desktop state owner | Committed desktop projection and later persistence requests |
| Application broker | Admitted instance/execution lifecycle, producers and delegated mounts |
| Application process | Domain state, resource use and its checkpoint schema |
| Presenter | Local pointer capture, menu navigation and pending input intent |
| Registry/install subsystem | Definition revisions, dependency resolution and activation |
| Workspace storage subsystem | Durable operational records and transactional migrations |
| Security/publication authority | Who may execute operations and activate reviewed code |

## Recommended sequence

1. Fix concrete input/failure-handling defects and write the vocabulary/ownership
   contract before publishing app APIs.
2. Establish launch identity, explicit app readiness/stop states and typed
   operation results. Extract testable state transitions from the current loops.
3. Remove bundled-app special cases using a small descriptor/admission contract;
   prove a new fixture app composes without editing the shell or broker.
4. Add reproducible runtime setup, CI and the adversarial lifecycle cases. Release
   a clearly scoped desktop preview after those pass.
5. Implement workspace persistence and app checkpoints before claiming restart-
   safe updates. Hub, self-edit, MCP, harnesses and native distribution remain
   independent subsystems built on the resulting contracts.

No source fixes were applied during this critique.
