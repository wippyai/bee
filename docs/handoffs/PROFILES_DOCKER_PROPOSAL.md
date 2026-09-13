# Agent profiles, per-profile environment, Docker placement with the full UI (scheduling proposal)

Written 2026-09-10 for Astra's review after the user's direction the same day: "we should also be able to add agent profiles like additional kits or anything like that, maybe different environment variables as well; make sure that we can easily run that in Docker and so on, Docker with proper full UI", and "is there a way to set the system prompt or something like that for all the agents when you run them". Astra (round 64): carry it forward at full scope, separate the acceptance cases, keep nonsecret profile environment apart from broker-projected secrets, and never let container logs stand for the full UI.

## September 13 implementation boundary

`bee.placement.docker:configuration` now supplies an internal pure projection
from explicit image, sandbox limits, admitted mount paths and attempt labels to
the existing narrow Docker create config. It preserves argument boundaries and
project access, generates container-visible HOME/TMPDIR, and refuses unknown
options, mutable images, host network sharing, mount traversal/overlap and a
project source containing the private home. Supplied paths/labels grant nothing.
The optional module has no placement binding, Docker runtime dependency or Agent menu
entry. The owner has not yet connected it to durable admission/materialization.

All 854 Lua tests pass. `make docker-configuration-check` loads this projection,
the reviewed userspace narrow runtime and the actual Lua Docker HTTP client in
an isolated host. A private fake daemon checks the create payload and exactly one
inspection; no container starts. The check is Go, outside the production pack.
This is not actual sandbox or managed Agent acceptance. Full `make check`
passes on the selected atomic-publication runtime, including source/pack desktop,
storage, recovery and application acceptance. Existing Lua fixpoint warnings
remain. No global update is claimed.

The path review confirms driver configuration must render against the selected
container-visible HOME **before** its delivery is frozen at placement intent:
Codex embeds absolute hook paths. The existing materializer must retain all host
credential/file publication ownership and expose those same files through the
admitted mount. Bind the path projection into the attempt before creation;
do not rewrite already-frozen configuration at start. A project directory that
contains private session homes cannot be mounted wholesale into the container.

The current integration review found that narrow inspection discarded Docker's
`State.StartedAt`. PR #67 now preserves it as optional `started_at` (head
`a37e91a`), so an admitting component can distinguish executions of the same
container. No timestamp is inferred from labels or a clock. Baseline/fixed
regressions and isolated lint pass; the actual Lua HTTP client preserves distinct
nanosecond timestamps through a private socket fixture. Existing sandbox and
removal checks pass. The stacked PTY PR #68 includes this change at `4a0e62d`
and its HTTP creation proof passes. Both remain unmerged and unpublished.

Luna's read-only placement review confirms the common terminal seam is
`src/placement/native/window.lua` at child construction before `attach_terminal`.
Keep the attempt claim, materialization and lifecycle owner shared; do not copy
the runner or store. Docker selection and its daemon/container/image/execution
identity must come from the admitted attempt, not application-supplied window
options. Host paths/configuration need an admitted container projection; native
PID reconciliation must not be used for Docker. The gateway currently accepts
only host loopback, so container MCP/hooks are a required integration change.
These are implementation requirements, not callable Docker placement APIs.

**Correction after the component-source review:** lack of container inspection
in `exec.docker` does not establish a need for a new runtime inspection API.
Published `userspace/docker` 0.5.12 already exposes narrow create, find by labels,
inspect, start, stop and remove operations. Its source is in the userspace
repository; it is not an implemented Bee dependency. The separate interactive
worker uses an executor-created process, while narrow creation manages a Docker
API container. Those paths do not yet prove native terminal attachment to the
same managed container. Earlier local `create_terminal` work is recorded in
the September 12 journal; it and direct Go PTY proofs are not a shipped Bee path.

The proposed runtime `reference`/`inspect`/signal-by-reference experiment was
paused after the user's scope objection. It is uncommitted, unvalidated and not
a runtime requirement or PR. Resolve the existing component/terminal seam before
resuming any such API proposal.

Draft [userspace PR #68](https://github.com/wippyai/userspace/pull/68), stacked on
#67 and assigned to `skhaz`, enables PTY creation through the existing narrow
`create` operation. It accepts an explicit boolean `Tty`, preserving the same
stdio and sandbox validation for both modes. There is no second create operation
or automatic start. Baseline/fixed Lua regressions, isolated lint, existing narrow
checks and the actual HTTP client against a private fake daemon pass. It remains
unmerged and unpublished; native terminal attachment is still a separate gap.
The local daemon advertises seccomp and cgroup namespaces but no AppArmor, which
the existing narrow contract requires. That requirement was preserved; the HTTP
fixture does not establish a running hardened container or full component-host
acceptance. Evidence is under `bee-evidence/0912/bee-docker-pty-*.log`.

Component review reproduced a false cleanup receipt: failed removal followed by
failed inspection was reported as `destroyed`. [Userspace PR #67](https://github.com/wippyai/userspace/pull/67)
preserves the actual HTTP status and requires confirmed 404 for that reconciliation.
Five regression cases, the existing narrow checks and an actual Lua HTTP-client
proof against a private Unix-socket fake daemon pass. The PR is draft, assigned
to `skhaz`; full component-host and managed Docker acceptance remain outstanding.
The follow-up in the same draft preserves paused/restarting/removing/dead states,
uses the daemon's actual image ID rather than a label, and requires a terminal
observation before reporting successful stop. Baseline failures and positive
regressions pass, alongside existing narrow checks and isolated lint.
Caller-qualified identity and full component-host acceptance still need review
before Bee treats these observations as cleanup evidence.

An isolated Go proof at the exact runtime pin now attaches an independently
started Docker container to unchanged `proxy.New`/`Run`, using a test-only
`exec.PTYProcess` implementation and the Docker SDK. Structured paste/Enter and
resize render correctly; proxy close exits the exact original container. The
focused race test passes with a local immutable image, no download, and no
Docker CLI attachment process. Evidence lives in
`bee-evidence/0912/docker-existing-container-proxy-{race.log,proof_test.go}`.
This proves the existing native terminal interface is sufficient. It does not
provide a callable production attachment operation, its permissions, cold
reattachment, safe write cancellation or managed Agent-window acceptance.
The test wrapper is not production code and must not be copied in as a driver.

A subsequent blocked-input proof exposes an existing cancellation gap at that
same runtime pin. `TestProxyNativeDockerBlockedInputCancellation` uses the actual
Docker executor, an already-local immutable Alpine image and a container that
does not read stdin. A 16 MiB paste blocks native `WriteStdin`; cancellation does
not complete within eight seconds, and explicit kill of the fixture child releases
it. The focused race run fails in 8.961s. The proxy handles input synchronously,
so the event loop cannot observe cancellation while that write is blocked.
This was also reproduced with the test-only existing-container attachment.
Evidence: `bee-evidence/0912/docker-native-blocked-input-cancel.log` and
`docker-blocked-input-proof_test.go`. Check current runtime and installed patches
for overlap before requesting a correction to this existing path. This result
does not justify a new reference/inspection API and is not yet evidence against
the installed runtime combination. Managed Docker remains unimplemented.

The same source gap exists on fetched runtime main `da80fddea4`.
[Runtime PR #745](https://github.com/wippyai/runtime/pull/745), assigned to
`skhaz`, fixes cancellation and direct close by moving existing shutdown
escalation into a joined watcher, independent of blocked input. No public APIs
or input queues are added. Deterministic main regressions fail before the fix;
the candidate passes terminal/native/Docker/Lua exec race suites, the opt-in
real Docker regression and scoped lint. Signal failures and forced-shutdown
errors remain observable. An event-channel close still follows earlier input;
asynchronous callers use the existing `RequestClose`. The PR remains unmerged
and uninstalled. Global `7d9182cb` was rechecked unchanged. This does not supply
the managed-container admission or container gateway integration.

An external-package Go proof at the runtime pin also supplies an existing
`exec.PTYProcess` through the public Lua `exec.NewProcess` constructor and
`value.PushTypedUserData(..., "exec.Process")`. The normal resize/start/close
and `attach_terminal` methods are available without private runtime helpers.
The focused race test passes. Hostless attachment is refused before starting or
consuming the supplied handle; that refusal occurs at the missing runtime
context/relay check, so it does not establish actual terminal-grant admission.
Evidence: `bee-evidence/0912/external-exec-process-proof{.log,_test.go}`.
This identifies a native component extension point, not a shipped Docker module:
the component must authorize the exact container before constructing the handle,
and real application-actor/terminal-grant acceptance remains required. Do not add
a second Lua exec handle or reopen the generic reference/inspection experiment
merely to return a PTY from a native component.

The optional native attachment backend is now implemented at Bee native commit
`e2ee130` on `feat/docker-attachment-component-20260913`, based on installed native
`fe8cb0d`. `native/docker` implements the existing PTY, stdin-close and wait-cancel
interfaces. It checks full container/image IDs, execution start time and copied
expected labels before and after attachment, closes a failed attachment, checks
identity before control, and does not infer exit from canceled waiting. It never
creates, starts or removes a container. Its Makefile race/vet gate passes with
real Docker input, resize and exact-container exit plus failure cases; evidence
is `bee-evidence/0912/docker-attachment-component.log`.

This backend is not registered as a Lua module or wired into the Agent app.
Authorization belongs to its admitting caller, and actual Bee terminal-grant
acceptance remains open. Docker inspection and control are not atomic: the
lifecycle owner must serialize restart/control, and these checks cannot fence a
daemon administrator racing an execution replacement. Full cold screen recovery
and the complete sandbox/profile/gateway path remain unproved. Global is unchanged.

Native candidate `32e632f` adds the typed `docker_pty` module factory. The host
binds its daemon client/reference; Lua cannot choose a URL or socket. Attachment
requires an actor and scope and checks `docker.attach` on the daemon-qualified
full container ID, with requested image/start/labels as policy metadata. It
returns the existing runtime `exec.Process` without daemon I/O. Refusal tests
cover wrong daemon/container/actor, missing scope, malformed fields and changed
execution time. A real Docker integration uses runtime frames, a system TTY
viewport grant and Lua `attach_terminal()` for rendering/input/resize/close.
A child inherits the security scope but not the parent's port and is refused.
The native Makefile race/vet gate passes; evidence is
`bee-evidence/0912/docker-module-frame-integration.log`.

This is native frame/grant acceptance, not Bee broker/application acceptance.
The public launcher does not register the module yet. Host policy must derive
container permission from admitted records, not the labels supplied to the
operation. Placement/profile/sandbox and scoped container gateway integration
remain unfinished; global Bee is unchanged.

Saved profile data, the Agent picker and appended instructions are implemented;
see [saved profiles](SAVED_AGENT_PROFILES.md). The additional profile schema and
instruction-entry scheme below remain historical proposals.

Docker placement is still unimplemented. The current integration direction is
native `exec.docker` with the existing `exec.PTYProcess` and `attach_terminal`
path. Bee's exact runtime pin `291f5c6b708c80afe5da07f3223767573b4d183f` already
supports Docker PTY input and resize. Its real `TestDockerPTYResize` passed against
the local daemon, including initial size, input and changed size; it was not
skipped. Evidence: `bee-evidence/0912/docker-pinned-pty.log`. This is runtime
capability evidence, not a managed Bee Docker window or cold recovery proof.

[Runtime PR #739](https://github.com/wippyai/runtime/pull/739), assigned to
`skhaz`, proposes per-process admitted bind mounts and remains unmerged. Bee
must select only the attempt's private HOME and authorized project roots.
Container paths, image/executable selection and daemon locality must be resolved
by the placement component; saved profiles cannot supply arbitrary host mounts.
Credentials use the existing broker projection into that private HOME.

Durable Docker execution identity and reconciliation remain an unresolved seam:
the current Lua exec API exposes a host PID when supported, but no durable Docker
container identity or owner-qualified container lookup. A lost terminal handle
cannot prove that a container exited, and therefore cannot authorize deleting its
private HOME. Resolve this using the runtime/container component's lifecycle
before advertising managed Docker recovery; do not infer exit from disconnect.
The gateway also needs a container-reachable, authorized address: a loopback URL
inside a container does not address the Bee host. This must preserve the current
binding token and MCP/hook scopes.

The historical dependency on `userspace/docker` below is not an implemented Bee
requirement. No second container or Docker CLI attachment loop is needed for PTY
support. Full Agent-window acceptance must still prove input, resize, detach and
rejoin, retained conversation data, credential isolation and crash cleanup.

### September 13 source review: integration boundaries

The installed native window cannot become Docker placement just by changing its
executor reference. The source review identifies these concrete dependencies:

- `src/placement/native/materialization.lua` resolves host paths for both HOME
  and the working directory. Docker must distinguish where the host writes
  retained configuration from the paths the harness sees inside its container.
  Keep credential projection and the existing cancellation/publication fences.
- `src/placement/native/window.lua` measures a host executable and reads host
  PID/PGID/start ticks/boot identity. Docker needs the admitted image identity
  and evidence from the container executor. A missing host PID is not exit
  evidence. The broker terminal grant and `attach_terminal()` remain applicable;
  no separate Docker terminal transport is required.
- `src/gateway/configuration.lua`, `address_method.lua` and
  `hook_http_method.lua` enforce loopback destinations or Host headers. The
  native `hookpost` command also validates loopback. Changing only the listener
  bind or generated URL cannot enable container hooks. A container endpoint must
  be host-selected and checked consistently through delivery and HTTP admission,
  retaining binding-specific tokens, scopes and revocation. Broader network
  exposure and its transport protection remain design/acceptance work.

The runtime comparison must use the manifest pin, not the unrelated revision
currently checked out in the main runtime directory. At pin
`291f5c6b708c80afe5da07f3223767573b4d183f`, `api/service/exec/api.go` exposes
`PTYProcess`, optional host `ProcessIdentity` and `WaitCanceler`.
The Docker implementation keeps its container ID privately; those APIs do not
provide a durable, owner-qualified container reconciliation contract. PR #739
was rechecked OPEN at `69a6e6e8597a02a586fccc884a23db46d2b516ff`, assigned
to `skhaz`; its mount work does not by itself resolve that lifecycle boundary.

These are integration findings, not newly callable APIs or Docker acceptance.
Reuse common lifecycle behavior only with a concrete Docker consumer and its
failure tests; do not copy the native runner or add a speculative backend layer.
The installed offline native build remains unchanged by this review.

## September 11 implementation direction

The extra `bee.agent_profile` composition proposed below is superseded. A named
`bee.launch_definition` already selects the binding, driver profile, launch
policy and presentation. It is the user-facing agent profile; a second entry
repeating those references would duplicate ownership. The selected host policy
continues to own environment, executable bindings, driver options and gateway
configuration. Credentials remain separate broker projections. Profile selection
will list eligible launch definitions through the existing Agent application.
The source Agent window now contains that selector and exposes `agent` command
metadata. Real broker/PTY acceptance and the source-free executable `bee agent`
route pass. Global installation and production harness activation remain open.

The first prerequisites are implemented on the isolated profile branch:
definition, catalog and policy resolve from one registry snapshot, and managed
launch admission rejects caller environment before any thread/resource/credential
effect. The lower carrier and placement remain general execution primitives.
All 567 unit tests and managed-window acceptance pass for these boundaries.

The native environment-ownership follow-up passes all 20 focused native tests:
placement owns HOME, gateway destinations cannot collide, and credential
projections cannot overwrite existing values. Removing the overwrite guard makes
exactly the credential-collision regression fail. A focused real-child test also
passes for two named definitions sharing one Claude batch profile: each child
receives its selected environment and broker credential, excludes the other
profile's variables, and retains a successful receipt and answer without secret
bytes in thread records or placement evidence. The combined suite is pending.

The next source boundary accepts `expected_plan_digest` on admission/start and
the private window envelope. A mismatch with the currently resolved definition,
binding, profile and policy refuses with `CONFLICT` before creating a thread or
obtaining grants and credentials. Actual broker-spawned window acceptance passes
with a resolved digest carried through the envelope. All 572 unit tests pass, including a
changed policy, matching selection and malformed digest.
The source selector carries the displayed plan's digest, clears choices after
conflict, and requires an explicit refresh and selection before another launch. Shared instructions need driver-specific measured rendering
and real-executable checks. Docker placement and its full interactive UI retain
the acceptance below. No `profile_ref` replacement schema or extra presentation
decoder is needed for the existing launch definition.

The original proposal below is retained as design history. Its instructions,
Docker and acceptance requirements remain planned; its additional profile schema
and duplicated references must not be implemented.

## What exists that this builds on

| Piece | Where | What it already gives |
|---|---|---|
| Harness bindings and profiles | `bee.harness.catalog` classifies `harness.driver` bindings and their `harness.profile` entries (driver id, protocol, modes, permission adapter) | The catalog of harness kits: Claude Code and Codex today, a kit is one binding plus its profiles and driver library |
| Launch definitions | `bee.launch_definition` entries (`launch_id`, `binding_ref`, `profile_id`, `policy_ref`, `default_mode`, `allowed_overrides`, `workdir_policy`, `thread_policy`, `credentials`, `presentation`) | What the Start menu and the CLI resolve to one measured plan |
| Launch policies | `bee.launch_policy` (`executables`, `environment`, `prepare_options`, `permission_exchange`, `provider_ref`, `gateway_tools`, `gateway_hooks`, `gateway_ttl_ms`, cleanup and timing) | The host's authority over how a launch runs: bound executable, nonsecret environment, driver options, gateway |
| Credential broker | `bee.credentials` projections into the child's environment, bytes never in records | The secret side of the environment |
| Native placement | `bee.placement.native`, private home per attempt, protected configuration files, measured executable | The attempt's home, configuration adapters, hook and MCP credentials |
| Docker contract | Hub module `userspace/docker` 0.5.12 (`userspace.docker:narrow`, interactive routes) and the agreed design in [Placement, resources and subscriptions](../PLACEMENT_AND_SUBSCRIPTIONS.md) | Hardened container per attempt, placement profiles, workspace launch document |
| Desktop | Session, viewport, terminal, taskbar, Timeline, Inbox, Hive Manager, thread windows | The full UI that has to operate Docker attempts unchanged |

## Proposal

Three units, each with its own acceptance, in this order.

### A. Agent profiles: kits and environments (host-owned registry data)

An agent profile is a host-owned registry entry `bee.agent_profile` that composes what exists rather than adding a new authority: `{schema_revision, profile_id, title, binding_ref, harness_profile_id, policy_ref, environment: {name: value}, system_prompt_ref?, presentation}`. Its environment is nonsecret and goes into the launch policy's environment map path (placement `environment`), never into the launch request and never through the broker; secrets stay broker projections named by the launch definition's `credentials`. A launch definition selects a profile (`profile_ref`) instead of naming binding, harness profile and policy separately; the Start menu and the CLI list profiles. Adding a kit means adding a `harness.driver` binding with its profiles and a driver library that implements `bee.driver:driver` (prepare, dispatch, normalize, configure); the catalog already classifies them, the carrier already runs whatever binding the definition names. The first additional kit is the one the user names; until then the acceptance uses the fixture driver.

System prompt: `system_prompt_ref` names a host-owned `bee.agent_instructions` entry whose text placement renders into the private home as a measured file. The Claude launch line gains `--append-system-prompt-file <home>/.bee/instructions.md` (append, never replace); the Codex provider configuration gains `model_instructions` with the same text (or `experimental_instructions_file`, whichever the pinned version honors; verified on the executables before the acceptance). The text is host data: it reaches the plan digest, never the launch request.

Acceptance A: two profiles of one kit with different environments run two attempts whose children see exactly their profile's variables and the broker-projected secret, with no variable of the other profile; a fixture kit added as a third binding runs under the same carrier and settles; the instructions file is in the home, measured, referenced from the launch line or the provider file, and its text appears in neither records nor evidence; a launch request naming environment or instructions is refused at placement intent.

### B. Docker attempt placement

`bee.placement.docker` implements `bee.placement:placement` on `userspace.docker:narrow` exactly as agreed: `bee.placement_profile` entries with the immutable image digest, non-root user, limits, tmpfs, network policy, resource and credential requests; admission produces the attempt-specific resolved specification; the driver runtime is in the image; the private home, the MCP and hook configurations, the credentials and the gateway credentials are materialized into the container by the same runner logic as native placement, with the gateway reached over a restricted interface the profile's network policy admits (no `host.docker.internal`, no host networking). One process per turn until an acknowledged bidirectional attach path exists. Creation intent recorded before dispatch, reconciliation by exact attempt labels, terminal evidence captured before removal.

Acceptance B: the same launch definition runs an attempt natively and in Docker with identical records, identical settlement and identical gateway behavior (MCP read, hooks, revocation); the container is proven hardened by the narrow contract (a broader configuration fails closed); the project resource is mounted from its resource reference, writable only when granted; a lost container is reconciled by labels; cleanup removes the home and keeps the terminal evidence; the workspace launch document from the placement design (`bee.workspace-launch@1`) is the only configuration the user writes.

### C. The full Bee UI operating Docker attempts

The desktop must operate a Docker attempt exactly as a native one: start from the Start menu, the thread window shows the turn, input reaches the child (batch: the brief; session: the next turn), resize reaches the viewport, F12 and a client restart reconnect to the same attempt, termination and cleanup show their true outcome, Timeline and Inbox show the same records and approvals. Container logs are evidence, never the UI.

Acceptance C: `tests/tui_smoke.py` style proofs against a Docker attempt: start, input, resize, reconnect after a client restart, explicit termination, cleanup, with the same screens as native; plus the desktop check on a host without Docker showing the concrete error rather than a reduced UI.

## Amendments (Astra round 67, accepted before unit A starts)

1. Profiles compose configuration; the launch policy remains the ceiling. A profile-backed managed launch takes no caller-selected environment: the launch request's environment must be empty. The launch policy declares `profile_environment` constraints (allowed names or patterns, bounds on count and value size) and every profile value must satisfy them; a name the policy's own `environment` also sets is a collision and is refused, never resolved by precedence.
2. One measured resolution. The launch definition, the agent profile, the harness binding and profile, the launch policy and the instructions entry are resolved from one registry snapshot; their entry measurements, the effective environment (names and digests) and the instructions digest are bound into the plan digest. The plan is revalidated before materialization and before start; recovery before start refuses changed inputs; a takeover of a running attempt keeps its recorded measurements.
3. The environment boundary. Variable count, names and value sizes are bounded. Reserved names and prefixes are refused for profiles: `PATH`, `HOME`, `USER`, `SHELL`, `TMPDIR`, `CODEX_HOME`, `CLAUDE_CONFIG_DIR`, the gateway and credential destinations, loader and preload variables (`LD_*`, `DYLD_*`, `NODE_OPTIONS`, `PYTHON*`), runtime configuration variables (`XDG_*`, `BEE_*`, `ANTHROPIC_*`, `OPENAI_*`). A profile cannot override a policy, placement, adapter, gateway or broker-owned value. Records and evidence carry variable names and value digests, never values.
4. Instructions stay adapter-owned. The `bee.agent_instructions` entry has bounded text and a measured digest; the text never enters the launch request, records, evidence or diagnostics: placement reads the entry itself by reference, verifies the digest the plan recorded, and writes the file with protected creation at the driver adapter's exact destination in the private home. Claude Code's append behavior (`--append-system-prompt-file`) and Codex's model-instruction behavior are distinct semantics, each proven with the pinned executable.
5. Definitions and presentation stay host-controlled. A caller selects a launch definition; the definition selects `profile_ref`; registry discovery authorizes nothing. A profile a definition marks headless stays out of the desktop unless the definition's presentation admits it.
6. The third fixture kit proves the extension boundary only; a production kit needs its own measured executable, binding, profile and catalog checks, configuration adapter and real-driver acceptance.

Units B and C are separate review units after A.

## Order and dependencies

A first (it needs nothing new below it and it answers both of the user's questions), then B (build sequence step 11, needs `userspace/docker` pinned as a dependency and a digest-pinned image with the Claude Code and Codex runtimes), then C (needs B). Docker windows, ACP and RPC stay at step 15. The hook and gateway work carries over unchanged: a container child reaches `/mcp` and `/hook` on the restricted interface with the same credentials.
