# Foundation status

## Current checkpoint — September 13

**New source, not installed:** `78b534f` includes the shared process-local
managed-window lifecycle and a correction to native group signalling. A rejected
OS signal command now returns failure, so the placement owner records an
unproven stop instead of successful signal evidence. The signal slice passed full
regression (866 units plus source/pack storage, desktop, client, recovery and app
checks). The lifecycle extraction preserves the native app identity and admission
policy; its module, native-window, managed-window and failure-settlement checks
pass. These are separate slice results, not a combined release gate.

The integration branch also contains host-selected private gateway interfaces.
Its actual-container check passes scoped MCP tools, separate HTTP/MCP hook
credentials, replay, and credential/Host/port/Origin refusals. The optional
Docker daemon component stays outside the default pack; its protocol test uses
the reviewed userspace client and a fake Unix daemon. That test establishes
identity checks and confirmed-absence handling, not managed Docker execution
or package publication. The private-interface gateway slice passed its full
regression; the combined integration release remains unverified. The additive
thread checkpoint response also passed all 868 unit tests and standalone
thread-module acceptance: it reports the placement from the committed
preparation, which a later carrier checkpoint cannot override. See
[gateway acceptance](GATEWAY.md) and the
[optional component](../modules/bee-placement-docker-daemon/README.md).

**Installed globally:** production `1a0ae17`, binary `c78b764d`.
Agent launch failures remain visible and responsive. Stopping an unstarted
placement atomically retires the attempt and releases its retained session;
delayed starts are fenced without deleting the retained home. Planning failures
write no receipt. Confirmed action/attempt failures settle asynchronously using
existing stop/cleanup operations. Closing during settlement can cancel it and
leaves the result unconfirmed, as the view states. No abort API or migration was added.

Full regression session `82438` passed: 865 units plus storage, source/pack
desktop, multi-display/client, recovery and app acceptance. Exact native
binary/modules/About and all four managed harness selector checks pass,
including saved profiles, scoped MCP and login present/absent. Offline
fresh/restart/reconnect and all three launch-failure stages pass. All six
installed artifacts match the candidate byte-for-byte; the preceding build is
backed up. Databases and running nodes were preserved. Existing nodes retain
their loaded code; newly started nodes use this build.

**Remaining agent workflow work:** managed Docker execution, real-provider cold
recovery across all harnesses, surviving orphan cleanup, and policy-controlled
sharing. Native Docker module composition is present, but Docker is not yet
selectable or usable in the Agent UI. See [global build](handoffs/GLOBAL_BUILD.md)
for release evidence and provider limitations.

### Previous login/hooks checkpoint

Previous production `f36e488`, binary `c8537ef7`,
adds Grok login/hooks and imports existing Agy onboarding state when creating a
private harness HOME. All four managed harness fixtures pass through the actual
picker, login delivery and scoped MCP. Real Grok startup commits SessionStart to
its bound thread without a model prompt. Offline fresh/restart/reconnect and
Claude fixture cold recovery pass. The exact candidate also launches real Agy
1.2.2 to its normal interactive prompt after the ordinary trust confirmation;
no model prompt was submitted. Full repository regression passed on repeat
(session `45783`, 863 unit tests plus storage and source/pack acceptance).
The first run's drag-failure readiness timeout remains unexplained; the unchanged
fixture passes alone and in the full repeat. All six installed artifacts match
the verified candidate; the previous build is backed up, and databases and running
nodes were preserved. Real Claude
reports "Not logged in" with the copied saved login both inside Bee and directly
in a fresh HOME. The source access token is expired; interactive refresh is
unverified and no Bee-specific cause is established. See
[global build](handoffs/GLOBAL_BUILD.md) for release evidence.

Previous global `7d9182cb` contains production `f7fe2ab` and native `fe8cb0d`: retained
configuration publication, cancellation before login writes, preserved supervisor
failure diagnostics and consistent hook conversation identity. Full `make check`
passes (851 units and source/pack acceptance), as do exact native, offline and
Claude fixture restart checks. Real Agy print-mode cold recovery retains its
conversation/HOME/app/thread and uses a fresh attempt/gateway; it recalls the
removed fixture token with no tool observations. All six artifacts were verified
and backed up; databases and running nodes were preserved. Runtime PR #744 adds
the fifth checked patch without changing the runtime pin or merging a PR.
Interactive Agy TUI and actual Codex recovery, surviving orphan trees, Docker and
policy-controlled sharing remain incomplete. The Codex live probe is currently
gated by its provider account's usage limit. See [global build](handoffs/GLOBAL_BUILD.md)
and [native recovery](handoffs/NATIVE_AGENT_RECOVERY.md) for evidence and scope.

### Preceding recovery checkpoint

Global `aa22527c` contains production `b883ae8`: interrupted Agent recovery with
responsive cancellation, offline embedded/local startup and the managed profile,
MCP, hook and native identity work below. Full `make check` at `62186b5` passed
(session `48027`, exit 0; 838 units). The final production difference is receipt
wording/comments; exact final native and offline checks pass, alongside fixture
whole-node restart and controlled SIGKILL continuation. Installation verified and
backed up all six artifacts without changing databases or restarting nodes.
Real-provider recovery, surviving orphan trees, Docker and policy-controlled
sharing remain incomplete. See [global build](handoffs/GLOBAL_BUILD.md).

The preceding global `b40aa0a5` contains production `3f3a8bc`: offline embedded/local startup,
saved Agent profiles, appended guidance, effort choices, scoped MCP, corrected
live PTY supervision and native window process identity. All 836 units, full
native executable acceptance, network-disabled fresh/restored/reconnect checks,
and the exact-source full `make check` pass. The full check completed in its
immutable checkout (session `60245`, exit 0). Installation verified and backed up
all six artifacts without restarting nodes or changing databases. See
[global build](handoffs/GLOBAL_BUILD.md) for exact artifacts and preserved state.

Real-provider Agent recovery remains incomplete. Runtime PR #743 preserves optional
terminal process identity. The installed build proves managed-window identity capture,
and independent process-group cleanup. Follow-up source proves graceful conversation
continuation through the broker using an acknowledged checkpoint and retained session home. These are
fixture-harness proofs within a running runtime, not real-provider cold recovery.
Follow-up source passes interrupted-window restore and responsive cancellation
through the real broker/native terminal fixture. The recovery view stays responsive
while admission drains hooks. Its combined full regression passed and these
changes are now in the installed global build.
The follow-up native executable also passes restoration across a whole-node
stop/restart from the actual persisted workspace checkpoint: same app/view and
conversation identity, retained HOME, fresh attempt and gateway binding. This is
a fixture Claude proof. Controlled SIGKILL of that node also passes when its
recorded native child is gone; surviving orphan trees and real providers remain
unverified.
Grok window hooks remain unimplemented; Agy now has the separate command-hook
path described in the current checkpoint. Managed Docker,
policy-controlled profile sharing, and end-to-end governed overlay activation
also remain unfinished. See [runtime requirements](handoffs/STATUS_RUNTIME_GATE.md),
[saved profiles](handoffs/SAVED_AGENT_PROFILES.md) and [Hub completion](handoffs/HUB_COMPLETION.md).
Tests and development dependencies remain outside production packs. No runtime PR
was merged for these changes.

## Earlier checkpoints

Global `dac1ba49` refreshes protected application admission and scopes without
replacing existing producers. Source/pack broker and attachment checks, 787 units,
complete native acceptance and real native Modules install/update/uninstall pass.
Full regression is running; approval-backed publication remains unfinished. See
[current build](handoffs/GLOBAL_BUILD.md) and [Hub completion](handoffs/HUB_COMPLETION.md).

Global `b92317be` removes the requested desktop hint text and Run queue display,
preserving the Bee mark and current Hub/Agent work. Source/pack Process Manager
and native acceptance pass. The preceding Hub source passed all 787 unit cases
on recheck; full repository acceptance remains incomplete. See
[current build](handoffs/GLOBAL_BUILD.md).

Global `6cfa0071` adds Contents browsing and preserves saved module settings on
updates, including failed/delayed-read handling. It retains Agent thread messaging.
79 focused cases, source/pack workflows, native acceptance and live exact-version
entry preview pass; the final full regression stopped during unit execution
with `context canceled`, and a focused unit recheck is running. Installed-app admission
and optional Hub plugin integration remain incomplete. See
[current build](handoffs/GLOBAL_BUILD.md).

Global `668d2e90` adds readable installed-package rows, active action/policy/tab
choices and preserved README code indentation. Strict lint, 73 focused cases,
source/pack interaction and native acceptance pass. Running owners retain older
UI; the full combined repository gate remains outstanding. See
[current build](handoffs/GLOBAL_BUILD.md) for source and install evidence.

Global `adeb373c` adds Settings → About with loaded bundle identity and Modules
Clear override, preserving the installed Modules redesign and native MCP work.
Combined native acceptance passes. The earlier full repository run ended with
exit 143 and is incomplete; see [current build](handoffs/GLOBAL_BUILD.md).

Global `887d0769` combines native randomized-port MCP and Claude/Codex lifecycle
hooks with the latest Hub/Modules UI. Actual fixture children authenticate and
read/wait on their bound thread; native hook acceptance passes. Full regression
is still running. See [current build](handoffs/GLOBAL_BUILD.md) for evidence and
remaining scope. Running nodes retain their loaded code.

Global `7ba0b747` now combines Hub requirements editing and package-created
database migrations with the latest Agent profile details/instructions.
Native binary acceptance, source/pack Modules UI, 71 focused Hub cases and Go
SQLite crash/rollback service acceptance pass. Full repository acceptance remains
outstanding. See the [current build](handoffs/GLOBAL_BUILD.md) for exact evidence.
The paragraphs below retain earlier checkpoint context.

Global `4a35163e` adds the Agent profile summary: folder policy, instruction
status and configured tool count. The native selector proves readable details
before Claude/Codex launch. It retains the previous Agent/Hub implementation;
see [current build](handoffs/GLOBAL_BUILD.md) for validation and remaining work.

Global `f1a29d08` now combines four-harness persistent instructions with Hub
history and migration rollback. Strict lint, 772 units, native desktop/Modules/Agent
acceptance and focused source/pack connection UI pass. See the
[current build](handoffs/GLOBAL_BUILD.md) for scope and remaining gates.
The dated source/install paragraphs below retain their earlier checkpoint context.

The Agent source now accepts persistent `instructions` on a launch definition's
host-selected policy, separate from the per-turn `brief` and dynamic `ctx`.
Claude, Codex, Grok and Agy map them through their existing configuration methods;
plan digests fence changed guidance, and no caller override grants authority.
Strict lint and all 766 unit cases pass, including instruction delivery and
stale-policy refusal before placement intent. Hive Manager source/pack acceptance
also passes after correcting its isolated HOME fixture. The combined history recheck passes all 771 unit cases. The frozen full
repository gate stopped at a 1.052-second exit against its one-second limit;
this source is not installed globally. An editable
instructions field, Docker profile execution and authenticated provider behavior
remain unverified; see [driver instructions](../src/driver/README.md#instructions-and-turn-prompts).

New database source supports migration targets supplied by the installation.
It verifies database definitions and saves an empty-ledger checkpoint before
running migrations. Real SQLite acceptance covers selected/default database paths,
ledger collisions, denied grants, crashes around the checkpoint and schema commit,
changed database refusal, and rollback of the new resource. Strict lint and 70
focused Hub cases pass. Native acceptance passed on isolated Hub source `d6671c6`. Integration with
global Agent profile source `d05b47c` is underway; the combined candidate and
full acceptance remain pending.

The rollback source keeps a durable removal receipt before calling down
migrations, retains the root on partial failure, and publishes root deletion with
its completion phase atomically. Real SQLite acceptance covers normal rollback,
completed replay, crashes before/after root deletion, changed-definition refusal
and partial failure/retry. Confirmation plans now list removed migrations.
Strict lint, 69 focused Hub tests and source/pack rollback review/confirmation
pass. Native desktop, Modules and Agent acceptance pass. Global is updated to
`1da5b5c6` (source `b8dd68c`), retaining running nodes. Full combined checks
remain pending; newly installed database resources remain unfinished.

The Hub history source adds caller-owned paged receipts and an explicit recovery
review in Modules. Real service acceptance covers pagination, read-only access,
actor isolation and replay using the persisted request. Source/pack application
acceptance covers cold recovery without a local plan, cancellation, confirmation,
status refresh, F12 and compact layouts. Strict lint and 68 focused Hub tests
pass. The original migration source full regression also passes; the combined
history source regression remains pending. The UI is installed globally as
`2f3f8e5a`, preserving Agent recovery and optional machine login. Native desktop,
Modules, Agent and real empty-history/F12 checks pass. Running nodes were retained.

Installed Hub build `f276bc2b` adds host-granted migration `up`, captured definition
receipts, post-commit ledger verification and explicit recovery. A disposable
local Hub proves real publication/SQL effects, completed replay, SIGKILL after
schema commit followed by restart, partial failure/retry and refusal after a
host-authorized definition change. Removal checks
include orphaned dependencies; `leave` retains their schema. Selected migration database requirements also pass real service acceptance.
Strict lint and 63 focused Hub tests pass. Migration `down`, newly installed
database resources and the complete regression gate remain pending.
The combined native build preserves Agent recovery and optional machine login;
see [Hub](HUB.md) and [global evidence](handoffs/GLOBAL_BUILD.md) for exact limits.

Hub checkpoint `237d76a8` combines managed Agent profiles with Hub package reads,
install/update/uninstall, README browsing, scrollable plan review and explicit
post-publication crash recovery. The combined source passes 746 unit cases and
the independent desktop suite. Two obsolete managed-Agent fixture assumptions
were corrected, and all five focused cases pass. A transfer-restart fixture now
waits for host retirement before replacement admission. The complete foundation
gate passes in segments after these fixture corrections. Migration execution and overlay activation
remain unfinished. Global has since advanced to the Agent recovery build
`849166aa`, retaining this Hub work. See [the current global build](handoffs/GLOBAL_BUILD.md) and
[Hub contract](HUB.md) for exact evidence and limits. Older checkpoints below
retain their historical status.

The September 12 build `78aae0b0` includes four separately packaged harness
drivers (Claude, Codex, Agy and Grok), with executable/client/upgrade acceptance.
The Agent picker still needs default production profiles. File-login delivery,
managed MCP activation and Docker are not complete. The broad source check
completed in segments after 677 passing unit cases and corrected module/hook fixtures.
See [the current global build](handoffs/GLOBAL_BUILD.md) for exact evidence and
limits; older checkpoints below describe earlier installations.

The Hub lane subsequently installed `acb59231`, retaining these four driver
packages and adding Modules. Its journal checkpoints 1388–1389 record the
installation and an active retained-node attachment investigation. The Agent
picker changes here are not installed in that binary.

The Agent selection source now keeps a valid but unavailable window profile in
the list, shows its admission refusal and disables Open. Refresh rebuilds the
snapshot; ready profiles still require the displayed plan digest at admission.
Each driver now ships a default window profile and a host-resolved executable
reference. The pre-setup checkpoint passed 684 unit cases and five managed-window
cases. The retirement
fixture now waits for the broker's exact close acknowledgment before testing
revoked input; thread completion alone does not establish application exit.
A source-free native candidate launches a fixture Codex CLI from the actual
Agent picker. That probe caught the production binding's missing thread-create
permission, now added. Admission failures stay visible in the picker, and retries
of the same selected plan preserve the request identity.

First-use setup now creates project/session associations under an explicit
operation grant and rechecks the selected plan before making changes. Placement
uses resource-authority grants. The native candidate proves a fixture Codex CLI
starts in the canonical project directory, uses a separate session home, and
keeps session files after app and node exit. The project root uses the runtime's
existing `fs.directory` with `base: project`. Full regression verification is
still running after updating fixtures for grant mode; automatic login setup,
cold conversation recovery, MCP activation and Docker remain incomplete. This
candidate is not installed globally.

The September 12 agent-integration branch composes Claude, Codex, Agy and Grok
as separate driver packs under the shared driver contract. The credential broker
also supports bounded host-admitted login files, with an append-only populated
store upgrade and separate filesystem permissions. File delivery into private
session homes is implemented on the separate retained-login integration branch:
the selected private home receives one exact admitted provider file before
configuration, and resume preserves harness-refreshed bytes. All 680 unit cases,
native/managed window, hook and resource-isolation gates pass; a deliberately
injected environment leak fails the secret-absence assertion. This delivery is
not in global `78aae0b0`. Production Agent profiles, automatic login setup,
managed MCP activation and Docker placement remain incomplete. See
[the journal handoff](handoffs/JOURNAL.md) for validation evidence.

Governed authoring now accepts an ordinary app with an explicit workspace
operation grant, while preserving its direct database and scope-creation denials.
The public function validates permission, then uses an existing named scope for
one fixed private storage call with the original actor. All 626 unit cases and
the two-boot authoring check pass; callers cannot access the private scope or
backend after the call. No runtime change, service or migration was added.
Hub installation and DB-backed additive overlay activation remain unfinished;
system/Hub definitions use registry history, while app edits will use stored
definitions projected through overlays. Global is now refreshed at the user's
request (SHA `55b725aa`); native acceptance and an actual upgrade preserve Settings,
identity and migration history. Automatic per-project state selection remains
unfinished; explicit `--state-dir` isolates all databases. See
[current global build](handoffs/GLOBAL_BUILD.md).

The combined September 12 integration checkpoint (`343eefa`) has a verified
standalone with driver-owned configuration delivery and no Hive review fixture
in production. Native acceptance and the combined Hive application checks pass;
all 15 assembled packs contain 608 entries without test/fixture registrations
or test-library references. The configuration slice's full foundation check
passes, as do all 626 combined unit cases after fixture removal. Global remains
unchanged until project-directory isolation is
supported by the runtime. See [current integration evidence](handoffs/AGENT_INTEGRATION.md).

The current source removes Hive Manager's review-node table and fixture selector.
Production reads the live directory. Its test data and slow-query/confirmation
probes stay in disposable Go/Lua source and pack hosts. All 26 focused model,
directory and view cases pass, along with six application cases and an explicit
failing-probe check. The 15 release component packs contain 608 entries. This
change is not installed globally.

The September 12 Agent integration branch has a verified standalone component
candidate, source `cf667d8`: retained provider homes exclude concurrent attempts,
interactive continuation resolves committed hook observations, and application
resume state becomes visible only after persistence acknowledgement. Existing
provider fixtures and native executable checks pass. Public Agent conversation
recovery still needs saved-state and fresh-admission wiring; the default picker
has no production launch profiles. Global installation remains gated on
per-project default state selection in the runtime. See
[the current integration checkpoint](handoffs/AGENT_INTEGRATION.md).

Native Agent windows now attach their placement attempt before opening the PTY
and receive a host-selected cooperative close allowance. The actual child/HTTP
hook test passes with a three-second claim delay: input remains responsive,
duplicate submissions produce one observation, and the cancellation receipt is
durable before the broker reports close. All 616 Lua tests, three managed-window
tests and the remaining foundation checks pass across the initial run and
targeted continuations. Two fixture-path omissions were fixed so governance
uses disposable databases in workspace-host and source-free acceptance.
The initial cached lint failure was preserved; fresh strict lint passes unchanged
source with the existing desktop-lifecycle warning. Global Bee is unchanged.

The September 11 Agent integration now includes governed authoring and claimed
hook recovery. All 600 Lua tests pass; actual restart checks preserve frozen
authoring content, retry receipts and the migration ledger. Exact operation and
workspace grants are checked even for the stored author. Revoked hook recovery
proves a committed record is reconciled once after a lost acknowledgement.
Source/pack headless checks pass. The earlier intermittent missing fault
diagnostic remains unexplained; this is not an uninterrupted full-check pass.
Public MCP activation and native Agent conversation recovery remain open.
Architecture tests and their build gate were removed at the user's direction;
behavioral permission and recovery tests remain. Global Bee is unchanged. See the
[current Agent checkpoint](handoffs/AGENT_INTEGRATION.md).

The Agent window now has a profile-selection phase and `agent` command metadata.
It lists bounded host-defined window profiles, carries the displayed plan into
admission, and requires refresh after a changed plan. Real broker acceptance
passes empty-list recovery, changed-plan refusal before work, mouse launch and
native terminal continuity. The selector closes its drawing surface before PTY
attachment and reuses the input subscription. All 578 unit tests pass; the
current narrow-window follow-up also passes its six focused selection tests.
Native packaging covers 14 modules / 589 entries. The source-free executable
`bee agent` path passes empty-catalog, F12, close-without-work and 0.120-second
detach acceptance. Broader checks remain pending; this source is not installed
globally. A selectable profile now requires its host policy to contain an
absolute executable binding. Exact policy binding waits for the driver to
prepare its executable on the launch path. Provider configuration remains
driver-owned and is checked after a user selects the plan but before Bee creates launch work;
for example, a Codex policy without its provider refuses without creating a
thread. A named provider entry is measured into the selected plan, so changing
its model or endpoint requires refresh and refuses a stale selection. Listing
never executes a driver function. The host-owned
[source fragment](../examples/agent-profiles/README.md) supplies the current
build-time composition path for Claude Code and Codex window definitions.
Installation and overlay activation remain unimplemented. Authenticated turns,
production process-tree cleanup and scoped MCP remain open acceptance gates.

Selected launch plans can now be carried into admission with
`expected_plan_digest`. A changed plan refuses before thread/resource/credential
effects; a matching plan follows normal admission. All 572 unit tests pass,
including changed-policy refusal and malformed-digest validation, and actual
broker-spawned window acceptance passes with the digest in its launch envelope.
The profile selector and public CLI wiring remain unimplemented. Broader
validation remains pending; this source is not installed globally.

Native placement now rejects conflicting environment ownership: `HOME` belongs
to placement, gateway token destinations belong to the gateway, and credential
projections cannot overwrite either those destinations or policy values. The
focused native suite passes all 20 tests, including refusal before intent and
credential-collision refusal before child start without secret bytes in evidence.
Disabling the credential overwrite guard in a disposable fixture makes exactly
that regression fail (19 pass, 1 fail).
All 570 combined unit tests pass for environment ownership and named-profile
isolation. The broader gate remains pending; global Bee is unchanged.

The profile work first corrects launch admission to read its definition, driver
catalog and policy from one registry snapshot. Managed admission also refuses caller environment before creating a thread;
the selected policy and credential broker supply it. All 567 unit tests pass,
including a real registry-update regression; restoring a live policy read makes that
regression fail. Managed-window and source/pack harness isolation checks pass.
The preceding driver checkpoint's complete foundation gate is recorded below;
this admission follow-up has not repeated that broader gate or changed global Bee.

The current driver source adds a shared `configure` contract method and generic
`provider_ref` launch policies (`bee.launch-policy@2`). Carrier and placement
resolve activated bindings from pinned snapshots; placement rerenders and checks
the private-home file before creating intent. A third-driver fixture proves
materialization without provider-specific imports in either caller. The native
harness receives scope-management authority only through protected host admission;
ordinary apps keep their existing denial. All 565 unit tests pass on the runtime
candidate. The remaining `make check` recipes also pass (the already-passing
unit prerequisite was omitted), as does standalone executable acceptance. This
source is not in the global executable. Gateway content combined with provider configuration
remains Codex-specific, and authenticated turns and production process-tree
cleanup remain separate acceptance gates.

Global Bee now includes local Hive Manager display browsing through exact
supervisor-selected reader admission. Native catalog/connection checks pass on
the final binary; source real-actor checks prove revocation and native-control
denial. Remote browsing and switching remain unfinished. The installed SHA starts
`5c604fa7`; existing running nodes retain their loaded code until restarted. See
[the build handoff](handoffs/GLOBAL_BUILD.md).

Current global Bee includes app transfer between independent displays, friendly
names, retained-display recovery and observer-safe assignment projection (SHA
`2569142f`, source `4e57054`). Public two-client transfer preserves the same shell
PID/state; final unit, executable, client/launcher/recovery and source/pack gates
pass as documented in [the build handoff](handoffs/GLOBAL_BUILD.md). Actual-user
cold/warm frames were 1.433s/0.209s, with about 0.11s detach. Live Hive Manager
browsing/attachment and workspace switching remain unfinished. Older checkpoints
below describe earlier installations and narrower evidence.

The September 11 global build now includes the production Hive eventual-name
cleanup permission fix (`6c6c574`, global SHA `82afdae8`). A controlled native
regression proves name release and fresh-PID publication on service re-add;
removing the permission reproduces the failure. Actual-user cold/warm frames
were 1.976s/0.218s, with clean 0.114s detaches. The initial retained desktop exit
remains unexplained. See [current build](handoffs/GLOBAL_BUILD.md).

Hive Manager source now retires departed node/display-client rows after 60 seconds
of absence in complete native membership samples. Returning nodes cancel retirement;
a failed or truncated membership sample resets the grace period while still
updating the members it reports. Repeated partial samples keep the presentation
cache bounded at 64 rows, preferring local and selected nodes under pressure.
Returning nodes clear departure status. Removing a node also clears pending and
saved-selection hints so another node cannot inherit its desktop selection. Retirement only
removes the manager's cached row, catalog and session presentation; saved display
layouts and application processes are untouched. Refresh is every five seconds
when its directory worker is idle, so cleanup may occur later than 60 seconds.
This change is installed globally as application source `6b2da06`; 516 Lua tests
and native client/binary checks pass. The intermittent startup/expired-mount
failure remains unresolved. See [current global build](handoffs/GLOBAL_BUILD.md).

The earlier global executable included native `a0fc01e088b2`, the proven physical
cancellation-order fix, with unchanged Bee source `c3b2c9f` and runtime `674b58a1`.
Native-client/standalone acceptance and focused race/vet pass; actual-user observe
reached a frame in 217 ms and detached in 87 ms. Global SHA starts `2c1f1109`.
Intermittent startup and detach failures remain unresolved; this is not sustained
reconnect acceptance. See [current build](handoffs/GLOBAL_BUILD.md). Older dated
checkpoints below describe previous installations and their evidence.

The source now includes an owner-local sync ledger, editable node descriptions
with a metadata trait, and multi-source approval inbox feeds over the existing
Hive policy route. Node updates use revision CAS and caller-scoped retry receipts;
all schema changes use the checked migration lifecycle. Two-runtime acceptance
passes metadata read/update/replay, mapped read-only denial/revocation, and
approval snapshot/decision/catch-up with revoked visibility. The local inbox
application smoke and 508 Lua tests pass. The full repository check passes,
including source-free packaging after adding the node database to the fixture's
isolated environment. The two-runtime feed gate also passes with the race-enabled
harness. This is source evidence, not a global binary installation or Hub publication.
See [sync and inbox](SYNC_AND_INBOX.md) for authority, retention and enrollment
limits. Governance source now provides a host-admitted, caller-owned staging
workspace with revision checks, retry receipts and frozen file snapshots. It has
no default authoring grants and cannot activate an overlay, install from Hub, or
replicate through Hive; those remain separate acceptance gates.

The currently installed September 10 candidate (production c3b2c9f, native
ced4008999f4, runtime674b58a1) passed full `make check`: 494 Lua tests,
525 source/pack entries, storage/restart, permissions, desktop/client lifetimes,
recovery and bundled apps. Evidence: `/tmp/bee-hive-session-identity-full-check.log`,
session61042, exit0. The existing desktop_lifecycle convergence warning remains.
Native-client and standalone gates74144/79123 also passed. The global executable
SHA starts `cbb6d6a5`; [the build handoff](handoffs/GLOBAL_BUILD.md) records full pins.

`bee desktops`, `bee attach WORKSPACE DISPLAY` and `bee observe WORKSPACE DISPLAY`
now select existing local desktop identities through authenticated supervisor
admission. Occupied/foreign selections refuse without allocation. Hive Manager
session presentation is qualified by node and owner generation. Actual-user
cold/warm/observe frames took1.486s/0.215s/0.221s; detach took0.077–0.086s.
The user databases were preserved. One-hour diagnostic50459 remains pending on
the previous build. Live workspace switching, multi-host composition and public
remote recovery remain unfinished. Earlier dated measurements below describe
previous candidates, not newer acceptance.

The latest September 10 global candidate now selects an independent desktop when
another physical client controls the default. It reuses an available durable
identity before allocating another; explicit selection and observe do not fall
back. The public native suite proves three simultaneous desktops, F12, reuse,
clipboard, bounded detach, retained shells and client-crash reconnect. Quit-dialog
presenter replacement also passes source/pack acceptance. Cold-node connection
stages allow 60 seconds, with immediate successful progress and cancellation.
The actual user state booted in 1.572 seconds after the authorized restart.
The independent-desktop source passed the combined full repository check
(490 Lua tests, 524 registry entries). This is not full-release acceptance. The older retained node's idle connection hang remains unexplained.


The global candidate installed September 10 now uses the native owner/client
launcher. Ordinary `bee` loads embedded code with shared registry history and
attaches through the same-machine native mesh. Ctrl+Q and Ctrl+] detach the
physical client while retaining its owner and applications. `bee observe` adds a
read-only physical view of the same running desktop; it cannot send app input or
resize it, and refuses promptly if no Bee is running. Public executable tests
prove shared content and controller continuity after observer detach. Standalone startup,
selection/copy, scrolling, explicit-detach reconnect and old-binary upgrade checks
pass. Warm launch now reuses the existing runtime lock and skips an extra owner
process; one standalone probe reached the retained desktop in 0.204 seconds.
Abrupt client death now has a standalone regression: after a 40-second native
node-departure observation interval, a fresh client rejoins the same retained
shell. Bee's supervisors handle existing LINK_DOWN events and revoke the
attachment without terminating the owner or declaring remote process completion.
The isolated owner-service trace has no failures and passes race/vet. Immediate
exact-actor EXIT while transport remains live is still a failing runtime gate.
The source used by the installed observer build passed one uninterrupted `make check`, including
486 Lua tests, source/pack architecture at 517 entries, storage and subscription
restart checks, all desktop/client/launcher/recovery gates and the bundled apps.
The 16-window load check exited in 323 ms. Both previously intermittent startup
failure points passed without increasing time limits; their causes remain
unexplained, so this run is not a claim that those intermittent failures are fixed.
Evidence: `/tmp/bee-membership-foundation-check.log` (session69756, exit0).
The observer build uses the same 365 production source files; its native launcher
and standalone suites pass separately on native142e753.
Named commands such as `bee terminal` now launch through controller admission to
the retained owner. Cold/warm command launches, literal arguments, replay, denied
observer launches and fullscreen provider aliases pass; the global binary is
installed and its isolated cold/warm smoke test passes. Existing owners keep
their previously loaded code until restarted.
See the current [runtime/build handoff](handoffs/STATUS_RUNTIME_GATE.md).
Older gate descriptions below refer to earlier candidates.


Bee is a local terminal desktop with on-demand default applications: Terminal,
Settings, Process Manager, Approvals, Timeline and Hive Manager. A fresh workspace opens no applications;
later boots restore applications that opted into automatic recovery. The source
and portable pack load only `src/`; fixtures and the legacy archive are excluded.
This file and [application contracts](APPLICATION_CONTRACTS.md) describe the
implemented boundary. Older design documents are proposals where they differ.

Settings provides 16 themes, 11 backgrounds and a Labels/Icons taskbar choice.
These preferences persist with the workspace. Compact tabs retain admitted app
icons, minimize/restore actions and the normal focus/overflow behavior.
Windows Classic keeps its silver application panels and uses a black console
with light default text for Terminal. Start and context menus align shortcuts
and submenu indicators; the BEE arrow reflects only the Start menu state.
Title/tab context menus also support user labels and named accents. The session
owns these values independently of application identity; supported recovery
restores them. Apps can announce their own bounded titles through the authenticated
broker; user labels retain precedence. Native PTY title forwarding is not implemented.

Applications can request bounded confirmation and single-line text dialogs.
The broker owns pending requests; the shell presents them and isolates input.
Questions survive F12, while app exit clears them. Apps may opt into negotiated
close at readiness; confirmation/cancellation and an unresponsive-app force-stop
choice are implemented. Normal workspace quit gathers guarded-app decisions before cleanup. The bundled
Terminal opts in and conservatively confirms every PTY close. Emergency exit from
failed-presenter recovery bypasses negotiation.

The installed candidate adds **Select text** to window context menus. Right-click
the body, title or tab; Shift-right-click in the body goes to the application.
Selection freezes one body; left-drag selects text and Ctrl+C requests clipboard
output from the physical client. Source/pack and standalone checks prove exact
foreground text with overlapping Terminals. Selection is absent from persisted
state and viewport snapshots. The native owner/client route sends a session-qualified
Copy request through the existing supervisor protocol; F12 and reconnect do not
replay it. Native text extraction and clipboard capabilities come from the candidate
runtime, not a released runtime main pin. Public remote selection remains open.
See [selection and its acceptance limits](handoffs/TEXT_SELECTION.md).


## Ownership

Public local launch uses the host/client split and the installed candidate's
embedded-default policy. It preserves shared registry history and application
state. `bee --base` is an explicit recovery path; it is not required for ordinary
launches to use embedded code. An already-running owner keeps its loaded code
until restarted. The runtime changes remain on the candidate pin; see
[the runtime cutover handoff](handoffs/RUNTIME_UPSTREAM_CUTOVER.md).

| Owner | Responsibility | Replacement boundary |
|---|---|---|
| Local supervisor | Host bootstrap, client admission and coordinated local quit | Local launch restart |
| Workspace host | Workspace persistence, recovery, client permissions and authoritative inventory | Host restart |
| Desktop client | Physical terminal, client layout persistence and presenter recovery | Client restart |
| Session | Complete committed desktop projection: scene, stable tabs, preferences | Client restart |
| Broker | Protected app admission, instance/process identities, producer viewports, app lifecycle | Host restart |
| Presenter | Input prediction, drag previews, menus, composition and delegated attachments | Live F12 rejoin |
| Application | Its own content and child resources | Close/stop then fresh instance |

The client caches the session projection; it does not independently edit tabs
or preferences. Rendering consumes values. App metadata supplies launcher groups
and presentation roles; core code contains no bundled-app IDs. Shared UI helpers
are optional; the Terminal uses Wippy's native PTY proxy directly.

Applications receive identities before spawn and acknowledge readiness. A spawn
alone is not an opened application. Readiness has a three-second deadline and
does not require a presenter attachment. The broker can retain a ready producer
and accept its checkpoints while detached; a mount failure reports attachment
failure without killing the app. Source/pack Lua acceptance checks this through
piped execution. A low-level `bee-host` command now owns the existing workspace
host without a desktop. It must execute on `bee:workers`, not the runtime's
default terminal command host. Source/pack acceptance covers piped readiness, stable
workspace identity across restart and bounded SIGTERM shutdown. Managed headless
launch, supervisor discovery and public remote enrollment remain unimplemented.
`make workspace-hosts-check` proves two host actors in one runtime with exact
separate database grants, concurrent sender-qualified requests, cross-workspace
target rejection, Settings checkpoint recovery and independent workspace IDs.
It passes from source and a source-free pack. Public launch still selects one
workspace; dynamic workspace activation, scoped catalogs and dormant-workspace
resource costs remain unproved.

Unguarded close
sends the producer a cooperative close event, then requests termination after
250ms. Guarded apps enter this cleanup only after an accepted decision. Records remain owned until EXIT; unsuccessful termination reports
uncertainty rather than claiming the process stopped. Workspace exit starts all
child cleanup together and does not serially wait for each close deadline.
The store remains available during cooperative cleanup; global shutdown preserves
recovery records. Completion waits for observed exits and known writes, with a
bounded error path for incomplete cleanup. Applications requiring a durable save
before accepting close must wait for their checkpoint receipt.

F12 retires only the presenter. The broker revokes old mounts and binds new ones
to the fresh PID. App processes, PTYs, viewport content, geometry, tab order and
preferences survive. Retry exhaustion preserves the last physical frame and
allows F12 retry or Ctrl+Q exit. Failure of the session or broker ends the workspace.
Rejected structural workspace-to-broker/session sends end the local workspace
with a visible error through its save path. Bind, restore, accepted shutdown and
checkpoint-receipt failure tests verify recovery survives and healthy reboot
works. Rejected ordinary open/close and quit preparation preserve running apps,
report failure and permit explicit retry.
Presenter snapshots remain reconstructible; this is not remote reconnection.
Workspace preferences and opt-in app checkpoints survive cold starts in the primary
workspace database. Settings demonstrates the resume contract. Terminal does not
claim to resurrect native processes after runtime shutdown.

Host-admitted clients without control permission can observe an existing
application through separate recipient-bound mounts. Source/pack desktop checks
cover different display sizes, F12 and observer loss while the original controller
continues using the same Terminal. Observer frames are clipped locally; input and
producer resize are denied. Public shared-desktop selection and explicit controller
transfer remain unimplemented.

## Security

Ordinary apps receive `process.send` and their producer capability, plus only
policies named in protected admission bindings. Metadata cannot select grants.
App scopes explicitly deny scope/context escalation and direct registry/overlay
mutation. Private core process spawning is denied to apps and the broker. Core
bootstrap checks the context installed by the workspace, not just a caller-supplied
owner argument. Receivers authenticate actual sender PIDs before interpreting data.

Settings receives an appearance-write operation grant. Process Manager receives
read-only runtime metrics plus a broker stop operation grant; core and supervisor
service control remain protected. Terminal alone receives its named native executor
and native command execution. Empty arguments launch `/bin/bash -i`; registered
CLI handlers launch `claude`, `codex` or `agy` fullscreen with literal arguments.
These programs must be installed on PATH; agent integration is not implemented.
Bash supplies interactive line editing
and history navigation. It has no ambient foreign TTY authority.
Producer capabilities and recipient-bound mounts carry terminal rights.

**Native shells run with the local OS user's authority.** They can access that
user's files and network, including editable Bee source. Runtime policies isolate
Lua actors; they do not sandbox native code or protect against the OS account
owning the files. No untrusted-code sandbox is claimed. An overlay-owning service
will be the sole runtime publication authority when implemented; direct registry
mutation is denied to applications today.

## Reproducible runtime and validation

`make setup` uses the Go builder and `wippy.build.json`, the same runtime and native
components used for standalone releases. The builder disables ambient Go workspaces
and verifies its pinned checkout. Bee's own source is MIT; the remaining runtime
patches retain MPL-2.0. Removing those patches requires the upstream changes tracked
in [runtime upstream work](RUNTIME_UPSTREAM.md).
The published build has completed that migration. This shared checkout retains
parallel host/Hive experiments; see [the runtime cutover handoff](handoffs/RUNTIME_UPSTREAM_CUTOVER.md)
before publishing those changes.
The local host work also preserves explicit command-host selection for packs,
needed to execute the headless entry on a worker host; its upstream acceptance
remains part of that workstream.

The workspace alone opens `bee:workspace_db`, a separate SQLite store from runtime
registry history. Its append-only migration ledger verifies names and checksums;
newer or altered migrations fail closed. Generation checks reject stale writers.
Migration 2 assigns a stable opaque workspace identity without changing the
existing envelope or migration 1. The ID survives reopen and database relocation.
The workspace supplies this ID through trusted broker bootstrap and application
launch values. The app SDK exposes a copied logical view reference. Broker
replies and desktop windows retain the workspace ID; workspace/presenter replies
for a different workspace are rejected. Local application requests carry an
explicit target checked by both the workspace and broker. Missing or foreign
targets return an error without executing locally. Mixed-workspace composition and public
remote launch are not implemented; the internal remote attachment fixture is described below.
Apps checkpoint through their broker; a successful receipt follows database commit.
See [storage](STORAGE.md) and [application contracts](APPLICATION_CONTRACTS.md).

`make check` runs typed lint, pure model/protocol/lifecycle tests, import and loaded
registry audits, and real source/pack terminal acceptance. Native terminal tests
exercise execution, PTY isolation, input, resize, interruption, rejoin, color fill,
close and registry/TTY access denial. Acceptance uses disposable stores and never
modifies a user's workspace history. CI runs the same setup and checks.

## Next boundaries

[Hive startup](HIVE_BOOTSTRAP.md) is in progress. The native manifest includes a
runtime patch for retained automatic listeners, concurrent authenticated startup
and graceful rejoin at a new port. It also includes an actor-ingress patch that
rejects source-node claims inconsistent with the authenticated peer; its full
internode race suite and clean native toolchain build pass. See
[Hive boundary proof](HIVE_POC.md) for the external-peer forwarding limit.
CLI acceptance passes for twenty isolated
runtime processes, including three Raft servers with converged leadership;
the fixture explicitly aligns relay and gossip node identities. Bee pairing,
project-host discovery, managed headless
launch and public remote enrollment remain unimplemented. Runtime transport tests
are not Bee cluster acceptance.

An experimental two-runtime source fixture now proves supervisor-selected Bee
host admission, destination Terminal execution, resize, revoked input and fresh
mount reattachment to the same live shell. It passes both locally and across two
machines through native mesh transport. `make hive-remote-check` also checks
coroutine progress while a destination viewport resize is stalled;
`make hive-lan-check` requires explicit remote test coordinates. Both use the
current native manifest toolchain; see [the exact scope](HIVE_POC.md).
Public enrollment, discovery and a remote desktop selector remain unimplemented.
The internal Hive supervisor implements bounded challenge exchange, peer
replacement and asynchronous open telemetry dispatch. A two-runtime fixture
proves discovery by native node-qualified names, calls in both directions,
sibling rejection and supervisor restart. It uses explicit fixture enrollment
and boot scopes. The current standalone launcher now starts the same-account
owner supervisor automatically; public external enrollment is still separate.
Hive Manager refreshes supervisor lookup, membership and owner telemetry. The
installed app now draws local Hive state before querying peers and performs
directory calls in one asynchronous worker, keeping input and close responsive during slow queries.
Concurrent refresh requests are refused visibly instead of accumulating work;
results remain keyed to their node. The installed standalone and source/pack
slow-query checks pass. A failed lookup is shown as **Hive supervisor unavailable** with its reason; it does not
infer that Hive is disabled or that enrollment would repair the failure. A found
supervisor is reported separately from each peer's reachability and desktop
availability. Detailed startup phases require an authoritative lifecycle source.
The installed revision separates the MEMBERSHIP and BEE SERVICE columns:
presence in the native member list does not imply a configured supervisor route.
Raft role is shown only under Details. This presentation change grants no access and does not establish peer connectivity.
Its standalone and full source/pack checks pass.
See [the supervisor boundary](HIVE_SUPERVISOR.md) for remaining activation gates.
`make hive-presenter-check` additionally drives the real presenter while the
destination runtime is stopped for fault injection. Start opens and F12 retires
cleanly within one second; input queue overflow is visible, and fresh attachment
retains the same Bash PID and variable. This is not public desktop discovery or
automatic recovery after network loss.

`make hive-desktop-check` proves the actual desktop client and session against a
workspace host in another runtime: destination Terminal execution and resizing,
F12, and a fresh client reconnecting to the same retained shell through its local
client store. This uses fixture-selected admission and pre-pinned test keys, not
the public launch/discovery path. It waits for the new presenter and retained
content in the same frame before typing; lossless input during reattachment
remains unproved.

The candidate `hive-desktop-admission-check` also admits a separate compiled
native client through the supervisor to a retained desktop. Its PTY mode proves
shell input, F12 with the same shell, resize, bounded Ctrl+] detach and restoration
of terminal settings. This requires the candidate runtime's isolation of blocking
stdin reads from terminal control commands. Explicit detach passes; remote actor
crash cleanup remains a failing native monitor gate, reconfirmed against the
current combined runtime on September 10. Ordinary second-`bee` auto-attachment
is now implemented and verified for explicit detach/reconnect. The physical LAN desktop fixture has passed
against `100.70.10.28`, including an owner-only file assertion and a separate
physical-process SIGKILL/rejoin to the retained shell with a fresh explicitly
enrolled client identity and automatic ports; same-name immediate rejoin remains
a separate failing runtime case; this does not establish the public remote launch route.

The local native thread journal is implemented and the rich thread authority,
delivery and projection are built on it; the Timeline application reads a
thread through the owner's subscription contract, with resume under a new
lease proven against the real owner. The isolated Lua subscriber fixture
remains separate.
Production views currently poll. Owner-local durable subscriptions preserve
acknowledged cursors across close/restart, fence old leases on resume, and reclaim
capacity only through explicit forget; the restart acceptance now passes on the
typed-listener candidate. Crash-safe job scheduling and dynamic membership remain
future work. See [threads](THREADS.md) for the
implemented API and limits, and [workspace attachments](WORKSPACE_ATTACHMENTS.md)
for the proposed identity split.

The Hub component now has a scoped read/plan/apply/status API and a Modules app
under acceptance. Exact artifact state reads and real dependency install, update,
uninstall and receipt persistence across restart pass on the existing runtime.
It requires no upstream changes or Keeper dependency. Migration execution,
interrupted-operation recovery and complete Modules confirmation/apply UI
acceptance remain incomplete. Uninstalled embedded-resource listing, chunked reads
and unchanged registry history pass against a public artifact. Basic Modules search, parameter input, F12 and
resize pass from source and pack; this backend milestone is installed globally. See
[Hub installation and package reads](HUB.md) for the current contract and evidence.

The shell remains the delivery focus. Hub installation, authorized overlay editing,
MCP, AI drivers and service/run
lifetimes are separate subsystems, not unfinished responsibilities of the presenter.

The first resource subsystem should own a workspace's named filesystem roots:
a stable resource ID, provider, authorized root, display name, and entry points.
Terminals, file views, Docker mounts and watchers reference those IDs instead of
embedding host paths into desktop state. Discovery may propose projects; it must
not authorize a root automatically. Native paths, container roots and virtual
providers need explicit resolution and containment checks at the provider boundary.
The terminal currently starts in the runtime's working directory; a resource binding
will replace that implicit choice once this subsystem exists.

## Native assembly

A pinned builder assembles Bee, Wippy and the typed native `ioevents` module for
Linux and macOS on amd64 and arm64. Standalone acceptance verifies source-free boot, Settings
recovery, native shell execution and F12. Base/bootstrap deployment handling and a
draft-release and Hub publication pipelines are implemented. A completed Hub upload
and update proof, in-app installation and stable distribution remain pending.
See [native distribution](NATIVE_DISTRIBUTION.md)
for the canonical update boundary and outstanding acceptance/license limits.

## Experimental computer owner

The [native computer owner](../native/computer/README.md) now has isolated
Windows VM acceptance for runtime-frame permission checks, one controller per
seat, child restart/crash/cancellation, stale grant/frame rejection and sustained
secure-desktop retirement. Parent and child use the same test executable.
It is not registered in the normal Bee launcher or exposed through Lua/Hive.
Actual login/logout recovery, execution-epoch wiring and lossless OS lifecycle
notifications remain acceptance gates. Linux uses a transport fixture in this
package; X11/macOS implementations are not integrated. Native race tests, vet
and Windows build/VM checks pass. The full foundation check was attempted and
stopped at 23 existing Lua lint errors; no passing full-suite claim is made.

The installed revision includes a private durable desktop catalog in the client
store: one default identity and up to 32 allocated identities, with no layout
content or live-availability claims. Source/pack storage and upgrade checks pass;
this helper is not exposed as public desktop selection yet.

The subsequent catalog source full run stopped on a presenter bug: a committed
window removal could leave its expired-view error in the header. The source fix
retires the removed attachment and clears only that window's error. A regression
fails on the old presenter and passes on fixed source/pack; the original Process
Manager scenario also passes. This does not fix or explain the separate retained
node's intermittent mesh disconnection. The protected desktop storage methods and
this presenter fix passed their combined full gate (486 tests, 519 entries) and
are installed globally. The actual-user smoke reached the desktop in 1.568s
cold, 0.222s on warm reconnect, and 0.219s through `bee observe`; all three
detached in under 100 ms. See the global build handoff for exact evidence.

The subsequent source Hive desktop route now publishes the durable catalog with
an explicit default, supports idempotent identity allocation, and activates an
allocated desktop for control on the existing workspace host. Sessions qualify
launch, copy and detach by selected desktop; observers cannot activate a dormant
record. Two-runtime acceptance proves simultaneous controllers on separate
desktops, retained default-shell continuity, allocation replay and cross-target
session denial. The native binding and 490 Lua tests pass. This is not installed:
automatic public second-launch selection and executable acceptance remain pending.
The runtime's separate exact remote actor EXIT recovery gate still fails. See
[client state](CLIENT_STATE.md) for the source contract and limits.


The next source UI adds a compact connection dropdown to the existing workspace
label (mouse or F9). It separates the local Hive service, executing node, workspace
identity/readiness and durable display identity/size. Hive service information is
supplied by the trusted retained-supervisor bootstrap; unreported legacy sessions
show "Not reported". This is not remote-peer health or a physical-client identity.
The presenter performs no discovery or networking. Source/pack tests cover mouse,
Escape, F12 and a 42×12 terminal. Hive Manager keeps readiness in view at narrow
widths and moves addresses and full IDs to Details. The native UI build is installed globally and its executable acceptance passes,
including stable display identity after reconnect. Hive Manager recognizes explicit
native client-role metadata as display clients and does not query them as Bee
services. This metadata grants no authority; names alone never establish roles.
The full check for that installed UI revision passed Lua and storage gates, then
caught an F9 modifier regression: Alt+F9 opened the dropdown instead of minimizing.
The following source correction restricts the dropdown to unmodified F9.

The next Hive Manager safety fix binds an attachment confirmation to the exact
node, workspace, desktop, owner generation and mode shown in the question.
Selection or owner changes require a new confirmation; an unconfirmed proposal
cannot become a retryable pending operation. Source/pack regression checks pass.
Live desktop browsing/attachment in the app remains unavailable: the existing
catalog is admitted to native clients only. This fix grants no new access and
is now in the installed global build. Alt+F9 minimize and plain-F9 status pass
source/pack and executable checks. The corrected safety checkpoint has passed its full repository check
(493 Lua tests, 525 registry entries); the later session-identity follow-up is
being validated separately.
