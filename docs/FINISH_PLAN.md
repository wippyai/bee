# Finishing Bee

This plan defines the first complete Bee release as a dependable local coding
desktop that can also join a Hive, run managed coding agents locally or in
Docker, install components from Hub, and activate reviewed overlays. A feature
is complete only when its public workflow, recovery behavior, executable
acceptance, documentation, and global installation all agree.

The existing owner, host/client, application, thread, gateway, governance and
native-mesh boundaries remain authoritative. This work must not add a second
mesh, a Bee-specific message ingress, a second registry, or a Docker control
plane beside native `exec.docker`. The production pack contains only `src/`.
The external `bee-legacy` tree is a reference and never a dependency.

## Current execution point

Train A is complete on branch `feat/docker-harness-delivery-20260913`. Source
commit `414c03b` produced global executable SHA `4692e267`. The exact pinned
repository check passed all 883 Lua tests and the full desktop, storage,
recovery and application acceptance. The earlier mixed-source presenter failure
did not reproduce. The rebuilt six-file candidate passed native selection,
offline boot, scoped Codex MCP/hooks, installed-to-candidate recovery,
same-build recovery and production-pack inspection.

The installer proved rollback with an injected post-replacement failure. Its
first real attempt then exercised that rollback when receipt serialization was
invalid; all six old files were restored byte-for-byte. The corrected retry
installed and verified all six candidate files. Four old executable instances,
including the user's retained owner, exited gracefully afterward; no state file
or database was removed. Installed offline fresh/restart/reconnect acceptance
passes.

The active implementation queue is now B1 through B4. The integration branch is
at `df31a70`. B1 command routing is complete at `7ea6d05`: `bee claude`,
`bee codex`, `bee agy` and `bee grok` resolve the same managed definitions as
the picker, while duplicate aliases and raw argument bypasses refuse before
admission. Agy additive configuration inheritance is complete at `df31a70`.

The only active uncommitted implementation is the Grok half of B1.1 in
`src/credentials/sources.lua`, `src/credentials/broker.lua` and
`src/_index.yaml`. It imports the user's ordinary Grok configuration into the
retained private harness home while Bee keeps its generated MCP configuration
at the higher private layer. This work is not complete until its typed boundary,
fixtures, real `grok inspect` proof, restart behavior and global-tree
non-mutation checks pass. B1.2 must not begin on top of a partially validated
B1.1.

The four active lanes are:

1. finish the clean-install four-harness Agent product and durable thread/title
   behavior;
2. complete native `exec.docker` parity under the same profile and carrier;
3. correct folder/node/workspace/display selection and two-node Hive behavior;
4. finish local Hub install/update/remove and protected admission.

### How the plan is operated

The execution board below is the only forward-looking status board. Dated
sections in `FOUNDATION_STATUS.md` are evidence history and can describe older
global executables; they do not change the current queue. Every work unit has
one owner, one branch or worktree and one bounded diff. Agents may perform
read-only audits in parallel, but only the unit owner edits its surface.

For each unit, work proceeds in this order:

1. state the public behavior and the existing authority boundary it uses;
2. add or repair the smallest typed implementation at that boundary;
3. run focused model and executable acceptance;
4. update the implementation contract and foundation status;
5. commit and hand the immutable commit plus evidence to the integration lane.

The integration lane accepts commits only after focused evidence. It resolves
cross-lane conflicts, runs the complete release gate once, builds the exact
standalone candidate and performs the atomic global install. It never installs
from a dirty worktree. Tests and fixtures remain outside `src/`, no new Python
fixture is added, and no architecture-count test is used as a completion gate.

At most four implementation lanes run concurrently: B1 Agent product, B2
Docker, B3 topology and B4 Hub. C package distribution waits for B3 and B4;
D overlay activation waits for C and the released registry compare-and-set
primitive. Work that does not close an exit proof is deferred.

## Definition of finished

Bee v1 is finished when these six user journeys pass from one tagged executable:

1. **Open locally:** `bee` starts offline in the current folder without waiting
   for Hive, restores the selected project workspace and gives each client an
   independent display.
2. **Run an Agent:** the picker and all four CLI aliases run ordinary installed
   Claude, Codex, Agy and Grok with their normal global configuration, additive
   Bee instructions/hooks/MCP, a durable thread and predictable recovery.
3. **Change isolation:** the same Agent profile runs locally or through native
   `exec.docker`; only isolation changes, while identity, thread, tools, terminal
   behavior and recovery remain the same.
4. **Join a Hive:** two real Bees find and attach through the existing native
   mesh, show clear node/workspace/display state, retain applications through a
   client loss and support controller transfer plus observers.
5. **Install a component:** Modules can plan, review, install, update, recover
   and remove an immutable app or separately packaged harness locally, then
   deliver admitted immutable content to another Bee.
6. **Edit safely:** an Agent or user can stage an exact-revision overlay, inspect
   source and permission changes, submit it to the correct governance owner,
   apply it once and roll it back from a durable receipt.

Anything that cannot be exercised through one of these journeys remains a
foundation or proposal. It does not delay a checkpoint unless that checkpoint's
acceptance requires it.

## Execution board

This board is the operational order. A lane may develop in parallel once its
start gate is satisfied, but only a release train may update global Bee.

| Train | Deliverable | Status | Next irreversible fact | Exit proof |
|---|---|---|---|---|
| A | Daily-use native Agent Bee | Complete: global SHA `4692e267` | Begin the four B lanes | Offline aliases, managed Claude/Codex hooks/MCP, recovery and installed hashes passed |
| B1 | Four managed native harnesses | Partly implemented | Finish Agy/Grok inheritance and clean-install picker profiles | UI and CLI launch all four; each owns a durable thread and resumes |
| B2 | Docker isolation | PTY foundation implemented | Route the same carrier/profile through native `exec.docker` | Local/Docker differ only by isolation; lifecycle and MCP proofs are identical |
| B3 | Folder/display/Hive model | Foundation implemented, public behavior incomplete | Make folder launch select the correct node/workspace/display without blocking offline boot | Multi-display local acceptance and two real nodes on the native mesh |
| B4 | Local Hub lifecycle | Planner/catalog foundation implemented | Complete immutable install/update/remove with admission and rollback | Installed app or harness enters its catalog without core edits |
| C | Hub distribution and harness packaging | Waiting on B1, B3 and B4 | Transfer one immutable admitted harness package to a second node | Destination installs and launches it without transferring authority or credentials |
| D | Governed overlays and self-edit | Authoring foundation implemented; activation incomplete | Implement exact-revision stage, review, apply and rollback through registry ownership | Agent prepares an edit, user reviews it, authorized owner applies or rejects it safely |
| E | Release hardening | Waiting on B-D integration | Produce one immutable cross-platform candidate | Full matrix passes twice and documentation matches the executable |

The integration order is `A → (B1 + B2 + B3 + B4) → C → D → E`. B1 through
B4 share contracts but do not share mutable implementation files without an
explicit handoff. B3 consumes the existing native mesh; it does not invent a
Bee transport. C transfers immutable package content after destination
admission. D is the only path that mutates live definitions.

### Lane ownership

Each lane owns one narrow surface and hands typed results to the next layer:

- **Agent product:** harness catalog, profiles, carrier, drivers, hooks, MCP and
  thread binding. Each provider driver stays an independently installable
  component.
- **Docker:** Docker placement and its native executor adapter. The carrier and
  thread owner remain unchanged.
- **Topology:** supervisor admission, folder/workspace selection, attachments,
  display presentation and Hive UI. Cluster/Raft remains owned by the runtime
  cluster lane.
- **Hub:** package resolution, immutable inventory, migrations, admission and
  rollback receipts. Hub does not publish directly into the registry.
- **Overlays:** authoring workspace, review proposal, governance decision and
  registry-owner activation.
- **Release:** integration, executable acceptance, documentation, atomic install
  and rollback. Only this lane updates global Bee.

Any required runtime semantic change is isolated in a runtime PR assigned to
`skhaz`. Bee proceeds against a pinned candidate and never merges the runtime
PR or carries a private replacement API.

The six installed files are `bee`, `bee.LICENSES.txt`, `bee.go.mod`,
`bee.go.sum`, `bee.provenance.json` and `bee.runtime-patches.tar.gz`. The
provenance document is the canonical manifest for source, runtime, native,
builder and patch pins. Every executable gate uses the runtime selected by that
manifest explicitly; ambient `.wippy` state is not release evidence.

## Completion rules

Each implementation milestone ends with one isolated immutable candidate and
these gates:

1. strict lint and focused behavioral tests;
2. the relevant source and packed-application user journey;
3. standalone executable and restart/recovery acceptance;
4. inspection proving tests, fixtures, credentials and local state are absent
   from the production pack.

A release train additionally requires one full `make check` with the exact
pinned `WIPPY`, followed by an atomic six-file global install with rollback.
Only the release lane installs globally. Train A installs immediately; a
completed B, C or D integration may be promoted as an explicit daily-use
checkpoint through the same release gates, and E installs the final candidate.
Every install preserves all existing databases, profiles, conversations,
workspaces and displays.

Passing a model test, fixture or source-only check does not complete a public
feature. Full regression runs once per integration candidate rather than after
every small change. Focused checks carry intermediate development.

## Delivery checkpoints

Bee will ship through three usable checkpoints. A checkpoint is promoted only
from a clean integration commit after the release gates above pass; unfinished
lanes continue in their own worktrees and cannot leak into the global build.

| Checkpoint | User-visible result | Required milestones | Promotion gate |
|---|---|---|---|
| Agent Bee | Agent picker and `bee claude`, `bee codex`, `bee agy`, `bee grok` use the same managed definitions; Local and Docker are profile choices; threads, hooks, MCP and recovery agree | 1 and 2 | All four native and Docker journeys, offline boot, restart/recovery, pack inspection, full `make check`, atomic six-file install |
| Connected Bee | Folder launch, displays, two-node Hive and local Hub install/update/remove are coherent and visible in the shell | 3 and 4 local | Multi-display and two-real-node mesh acceptance, ordinary package lifecycle, restart/recovery, full `make check`, atomic install |
| Editable Bee v1 | Hub distribution and governed stage, review, apply and rollback work end to end | 4 distribution, 5 and 6 | Cross-node package install, overlay conflict/rollback, platform matrix twice, permission/secret/pack audit, atomic install |

The release lane owns the integration commit and global installation. Feature
lanes hand it reviewed commits plus focused evidence; they never install a
mixed worktree. Existing databases, profiles, conversations, workspaces and
displays are migration inputs in every checkpoint.

## Immediate execution queue

This is the concrete queue from the current Train A source. Work inside a unit
may run in parallel when its files and ownership do not overlap. Integration
and promotion remain sequential.

### B1 — finish native managed Agents

1. **Done at `7ea6d05`:** canonical command routing makes the four CLI aliases
   resolve the same measured launch definitions as the Agent picker. Duplicate
   aliases and raw argument bypasses refuse before admission.
2. Make all four clean-install defaults launchable and give Agy and Grok safe
   access to their ordinary global configuration without writing generated Bee
   MCP or hook files into the user's global configuration directories.
3. Complete picker profile create, edit and select for the public profile fields:
   harness, isolation, options and MCP scope. Resolve context and additional
   instruction functions only at admission.
4. Prove one durable thread, title/activity projection and subscription cursor
   for every provider across presenter, client and owner replacement.
5. Prove provider cold resume where credentials permit and classify provider
   login/refusal as an external visible outcome. Reconcile a surviving child
   before starting a replacement.

Merge gate: UI and CLI acceptance for all four providers, raw-bypass refusal,
offline boot, cancellation/close, restart recovery, and no credentials or test
fixtures in the pack.

### Critical path from the current commit

Work these units in order. B2, B3 and B4 may develop beside B1 only in separate
worktrees with disjoint ownership; integration follows this table.

| Unit | Concrete result | Depends on | Proof that closes it |
|---|---|---|---|
| B1.1 | Agy and Grok retain ordinary global settings/login while Bee files remain session-owned and additive | current HEAD | real executable clean-start, cancel and restart probes; global config trees unchanged |
| B1.2 | Saved profile UI exposes only harness, isolation, options and MCP scope; instructions and dynamic context remain admitted inputs | B1.1 | create/edit/select/restart journeys from source and pack |
| B1.3 | Every provider has one durable thread, committed title activity, cold recovery and surviving-child reconciliation | B1.1 | four-provider replacement/restart matrix and Timeline cursor proof |
| B1 release | Native four-provider candidate | B1.1–B1.3 | full `make check`, standalone checks, pack inspection and atomic rollback-capable install |
| B2.1 | Native Docker placement implements start, stop, reconcile and cleanup under the existing placement owner | B1 contracts stable | daemon-backed lifecycle and restart tests with attempt labels |
| B2.2 | Local/Docker is one profile switch with the same carrier, project, MCP, hooks and credentials behavior | B2.1 | four-provider Local/Docker parity matrix on Engine and Desktop/WSL |
| Agent Bee release | First complete Agent checkpoint installed globally | B1 + B2 | checkpoint matrix passes twice from one immutable commit |
| B3.1 | Folder-derived state selects all databases; explicit `--state-dir` wins; local boot never waits on Hive | B1 release | two-folder restart and offline startup/cancel timing acceptance |
| B3.2 | Node, workspace, display and attachment identities drive launch, restore, observers and `Send to display` | B3.1 | multi-client/multi-display acceptance with stale lease retirement |
| B3.3 | Compact switcher and F9 view operate over two real native-mesh Bees | B3.2 | sleep/rejoin, remote viewport, approval and retained-app acceptance |
| B4.1 | Local Hub install/update/remove is immutable, admitted and rollback-safe | Train A | clean-store and populated-store lifecycle with injected failure recovery |
| B4.2 | Each harness is an independently installed Hub component | B1 + B4.1 | catalog gains/updates/removes one driver without a core edit |
| Connected Bee release | Folder, displays, Hive and local Hub are installed globally | B3 + B4 | two-node and Hub matrices plus the release gates |
| C | Destination Bee installs one app and one harness from immutable admitted content | B3.3 + B4.2 | cross-node transfer/retry/restart proof with no authority or credential transfer |
| D | One stage → review → apply → rollback overlay path serves UI and scoped Agent MCP | C + released registry CAS | conflict, stale-review, protected-core and rollback acceptance |
| E | Dead paths removed and one cross-platform candidate released | all above | Linux, WSL, macOS, Docker and two-host Hive matrix twice |

The current coding order is therefore B1.1, B1.2 and B1.3; then the B1 release
gate. Docker and local Hub may advance in parallel, but neither may invent a
second carrier, installer, registry or authority model. Topology work consumes
the native mesh only after local folder/display semantics pass.

### B2 — make Docker an isolation choice

1. Implement the Bee durable Docker placement adapter over native `exec.docker`:
   record intent, label the container with owner/action/attempt identity, and
   implement start, stop, reconcile, cleanup and restart recovery under the
   existing placement owner and sweeper. The direct PTY proof is a foundation,
   not this admitted lifecycle. The optional `userspace.docker` component is not
   a release dependency.
2. Add `isolation` to saved profiles and route the same managed window/carrier
   through the selected placement binding. Image, mounts, credentials, resource
   limits and placement options remain host-selected. Do not add a Docker-specific
   carrier, state owner or sweeper.
3. Run the user's installed harness executable with the selected project mount,
   minimum credential/configuration mounts and attempt-owned writable state.
   AppArmor remains an optional explicit profile requirement.
4. Make the host-selected gateway reachable from the container while preserving
   randomized addressing, bound credentials, MCP scope intersection, additive
   hooks, thread context and revocation.
5. Prove lifecycle parity: PTY input/output/resize, cancellation, close and
   container removal, failed create/start, owner restart, surviving-container
   reconciliation and secret-path inspection.
6. Delete superseded release-path userspace Docker scaffolding after parity is
   proven; separately installable optional components may remain outside the
   default pack.

Merge gate: the same four profile journeys pass with only `isolation` changed
from Local to Docker on ordinary Linux Docker and Docker Desktop/WSL.

### B3 — correct folder, display and Hive behavior

1. Make the executable-selected folder derive the default state directory for
   every Bee database, while explicit `--state-dir` takes precedence. Preserve
   existing stores and prove two folders remain isolated across restart.
2. Implement the public launch decision table in Milestone 3. A project launch
   creates or reuses its node/workspace and creates an independent display when
   appropriate; explicit client/observe commands attach without changing the
   selected project.
3. Make local readiness immediate. Hive rejoin proceeds asynchronously and can
   remain connectable for up to 60 seconds without blocking local presentation,
   input, cancellation or exit.
4. Replace ephemeral client-node pollution with display attachments and retire
   stale displays through leases and generations. Preserve retained applications
   and saved layouts.
5. Finish the compact shell status/switcher and F9 topology view. Always show
   friendly Hive, node, workspace and display identity plus reachability,
   authorization and controller/observer state.
6. Add safe `Send to display`, multi-client/multi-display acceptance and two
   real Bee nodes over the existing native TLS mesh, including sleep/reconnect
   and remote approval.

Merge gate: offline folder boot is immediate, two local folders and several
displays behave predictably, and the two-node acceptance passes without a second
mesh or remote-monitor subsystem.

### B4 — complete the local Hub lifecycle

1. Finish immutable resolve, plan, install, update and remove with provenance,
   migrations, receipts and rollback. Reuse the current Hub catalog and planner.
2. Route capability changes through protected application admission. A package
   appears in Tools or Agents only after the required review succeeds.
3. Preserve configuration and service-owned application values across update
   and restart; expose clear pending, installed, failed and rollback states in
   Modules.
4. Package each harness driver independently and prove install/update/removal
   changes the Agent catalog without a Bee core edit.

Merge gate: a clean Bee completes the ordinary application lifecycle and an
independent harness package lifecycle using only admitted immutable content.

### C through E — distribute, edit and release

1. Transfer one admitted immutable application and one harness package to a
   second Bee. The destination performs its own plan, admission and installation;
   credentials, grants, PIDs, mounts and database ownership never transfer.
2. Build the single governed overlay path: exact-revision stage, review,
   registry-owner apply and receipt-backed rollback. Expose it to the UI and
   narrowly scoped Agent MCP tools.
3. Require a released compare-and-set registry publication primitive before
   activating overlays. Any runtime work is a separate PR assigned to `skhaz`.
4. Remove dead paths, measure startup/idle/shutdown and run the Linux, WSL,
   macOS, Docker and two-host Hive matrix twice.

Final gate: the tagged executable, source documentation, website claims and MIT
install/download notices describe exactly the same accepted behavior.

## Milestone 0: release the current native Agent foundation — complete

Finish the active `feat/docker-harness-delivery-20260913` checkpoint before
starting another integration branch.

- Keep the completed recovery regression that calls `interrupted.recover` after
  a driver/profile implementation change and proves hook resume uses the
  historical checkpoint pins.
- Require explicit host-policy authorization before a profile can inherit host
  HOME. Enforce the same decision independently in native placement and include
  it in the measured policy digest.
- Prove that carrier planning rejects an unauthorized host HOME request, direct
  native placement rejects the same request, and the authorized Claude/Codex
  policies succeed.
- Preserve the failed mixed-source broad regression as diagnostic evidence,
  then run the final broad regression on the clean release HEAD containing
  `b9d1487`. Reproduce and fix the presenter-replacement failure only if it
  occurs on that exact source and pinned runtime.
- Build one fresh standalone candidate from the qualifying clean commit and run
  installed-to-candidate and same-build recovery.
- Prove offline boot, native Agent selection, Claude/Codex inherited HOME and
  custom configuration directories, scoped MCP, additive hooks, cancellation,
  and responsive close on that candidate.
- Atomically refresh global Bee only after the rebuilt artifact hashes and
  rollback path are recorded.

Exit: `bee`, `bee claude`, and `bee codex` start without network access to Bee
services, and the direct aliases preserve normal global harness login/settings.
Claude and Codex launched through the managed picker receive Bee's additive MCP
and hooks; an interrupted managed conversation reopens with the same durable
session and a fresh attempt. This is the next daily-use global build.

## Milestone 1: complete the managed Agent product

Use one small public profile contract throughout:

`profile = harness + isolation + options + MCP scope`

Dynamic context is resolved at admission and is not stored as authority in the
profile. Each of Claude, Codex, Agy and Grok remains a separately installable
harness component with its own driver/configuration boundary.

- Make the Agent picker useful on a clean install: four working defaults,
  saved-profile create/edit/select, readable availability failures and direct
  `bee <harness>` aliases using the same launch path.
- Make native defaults inherit each harness's ordinary global configuration and
  credentials. Apply Bee instructions, hooks and MCP additively. Support stored
  instructions and a host-authorized function that can build additional
  instructions from dynamic context.
- Finish Agy and Grok inheritance to the same standard as Claude and Codex.
- Bind every Agent window to one durable thread. Show committed activity in the
  title/status surface, expose the thread in Timeline, and preserve subscription
  cursors across client and owner restart.
- Complete real-provider cold recovery where account access permits it. Provider
  refusal must remain a visible external outcome rather than trigger a Bee login
  workaround.
- Prove surviving-child reconciliation: a lost owner either reattaches to the
  measured child or independently confirms cleanup before replacement.

Exit: all four harnesses launch from UI and CLI with global behavior intact,
scoped tools and hooks visible in their durable threads, and predictable resume,
cancel and close behavior.

## Milestone 2: deliver Docker through native execution

Docker is another isolation choice under the same Agent profile. It uses native
`exec.docker`; the optional userspace Docker client is not a release dependency.
AppArmor is optional and enforced only when a profile explicitly requires it.

- Route the existing managed window/carrier lifecycle through the selected
  Docker placement binding with no parallel state owner or sweeper.
- Run the normal installed Claude/Codex/Agy/Grok command in the container. Mount
  only the selected project and the minimum read-only global configuration or
  credential paths required by that harness. Keep Bee session state, hook/MCP
  material and writable harness state in the attempt/session home.
- Reuse randomized, authenticated, loopback/private-interface gateway endpoints.
  Admission intersects profile MCP scope with host policy and dynamic context.
- Prove PTY input/output, resize, clipboard/selection where supported, terminal
  title/activity, close, cancellation, container removal, lost-create recovery,
  restart reconciliation and no credential leakage.
- Remove the userspace-path scaffolding from the final release surface once the
  native path has equivalent acceptance.

Exit: changing a profile from Local to Docker changes isolation only; the Agent
picker, thread, MCP, hooks, recovery and global harness experience stay the same.

## Milestone 3: make workspace, node, display and Hive behavior coherent

Keep these identities distinct in storage, protocols and UI:

- a folder selects or creates a project workspace;
- a node hosts workspaces and applications;
- a display owns client layout and presentation;
- an attachment grants one live controller or observer relationship.

Public launch behavior:

1. `bee` in a folder with no local project owner creates that project node,
   workspace and current-terminal display;
2. `bee` in the same folder reuses that workspace and chooses an available
   display or creates a new independent display;
3. explicit attach/observe joins the selected existing workspace/display;
4. a configured Hive rejoins automatically, while discovery never blocks local
   boot or offline use.

- Make local readiness immediate and show connection progress in the UI. A
  remote node may remain connectable for up to 60 seconds, but local startup and
  cancellation must remain responsive.
- Retire stale client nodes/displays gradually using owner-held lease and
  generation state. Never publish dead ephemeral clients as durable nodes.
- Add one compact shell switcher for Hive, node, workspace and display. F9 opens
  the richer topology view with friendly labels, roles, reachability and the
  difference between empty, unavailable and unauthorized.
- Support several clients on one machine, several displays per client, and tabs
  from several owner-qualified workspaces. Existing tabs keep their owner when
  the browse/launch destination changes.
- Add `Send to display` as a presentation transfer. Revoke the old controller
  before granting the new one; uncertain revocation cannot create two input
  controllers. Allow many observers with one input/resize controller.
- Restore saved display layout after client replacement without moving the
  underlying application, PTY or workspace owner.
- Prove two real Bee nodes on the existing native TLS mesh, including sleep,
  reconnect, missed records, remote approval, retained applications and clean
  detach. Do not merge a speculative remote-monitor subsystem.

Exit: folder launches, local multi-display use and two-node Hive use match the
same identity and attachment model, and the UI always tells the user where an
application runs and where it is being displayed.

## Milestone 4: finish Hub installation and component distribution

The existing Hub catalog, planning, migration and Modules work is the base. Do
not build another installer or import Keeper. This milestone has three ordered
owners so local package work never waits on Hive and Hive transfer never changes
the local installer.

### Local lifecycle

- Complete install, update and remove with immutable versions, transitive
  requirements, provenance, migrations, recovery receipts and rollback.
- Connect installation to protected application admission so an installed app
  can appear in Tools only after reviewed permissions are admitted.
- Add update discovery and preserve module values/configuration across updates.

Exit: a clean local Bee can find, preview, install, authorize, launch, update,
recover and remove an ordinary application.

### Harness packaging

- Package the four harness drivers independently and prove installing or
  updating one changes the Agent catalog without editing Bee core.

Exit: a clean local Bee installs one harness component and gains its Agent
catalog entry without a Bee core edit or restart-dependent authority shortcut.

### Hive distribution

- Transfer package definitions and immutable files through Hive with destination
  admission. Never replicate credentials, grants, live PIDs, mounts or database
  ownership merely because a component exists on another node.
- Keep filesystem synchronization as an explicit component-owned resource
  contract for packages such as WASM or future GPU workers.

Exit: an admitted destination Bee receives, installs and launches the immutable
application or harness package with the same local lifecycle and receipts.

## Milestone 5: governed overlays and self-edit

Implement one durable workflow: **stage → review → apply**.

- Stage edits against exact registry/package revisions in an author-owned
  workspace. Store source, expected revisions, dependency closure, validation
  results and requested capability changes.
- Review the source, registry and permission diff. Core, registry and protected
  components require the governance inbox/keeper authority path; ordinary
  admitted app overlays may use their narrower owner policy.
- Recheck every measured revision and digest at apply time, publish through the
  native registry owner, record an activation receipt and provide rollback to a
  known baseline.
- Close the guarded registry-publication/CAS runtime gap before activation. Any
  runtime correction is a separate PR assigned to `skhaz`; Bee consumes the
  released primitive and never hides stale-base acceptance with a local lock.
- Project service-owned application definitions from their databases through
  admitted overlays. Keep system/Hub definitions in registry history. Do not
  give applications direct registry publication.
- Make the workflow callable from Bee's UI and scoped Agent MCP tools so an agent
  can prepare a change, the user can review it, and only the authorized owner can
  activate it.
- Prove conflict, stale review, partial failure, restart recovery, rollback,
  non-editable component refusal and Hive destination admission.

Exit: Bee can safely modify an app or its own editable components, while core
changes remain governed and every activation has a reviewable receipt and
rollback path.

## Milestone 6: release hardening and cleanup

- Remove dead release-path code, temporary compatibility branches and superseded
  Docker machinery. Keep the production vocabulary and component graph small.
- Consolidate duplicated storage only where ownership and migration boundaries
  remain explicit; do not merge databases merely to reduce a process list.
- Measure cold/warm startup, Agent start, idle CPU/memory, goroutines, Hive
  traffic, detach and shutdown. Fix causes rather than extending local timeouts.
- Exercise fresh install and upgrade from the current global build on Linux,
  WSL and macOS, plus two-host Hive and ordinary Docker Desktop/Engine.
- Audit permissions, secret paths, pack contents, migration history and rollback.
- Update the website and install instructions only to behavior proven by the
  released executable, including the MIT notice next to install/download.

Exit: one tagged candidate passes the complete matrix twice, installs atomically,
preserves all existing state, and its documentation describes no proposal as a
callable feature.

## Order, parallelism and estimate

Milestone 0 is the only immediate release lane. After it lands, Milestone 1 and
the native part of Milestone 2 can run in parallel, while the existing cluster
owner continues native-mesh hardening. Milestone 3 is the next integration point.
Hub completion can proceed beside it, but Hive distribution waits for the
Milestone 3 owner/attachment proof. Governed overlays consume the finished Hub,
governance and destination-admission boundaries.

The safe parallel lanes are:

| Lane | May start after | Integration boundary |
|---|---|---|
| Four native harnesses | Milestone 0 | One profile, carrier and thread contract |
| Native Docker placement | Milestone 0 | Same carrier lifecycle and `exec.docker` |
| Hub local install/update/remove | Milestone 0 | Protected admission and immutable receipts |
| Folder/display/Hive correction | Milestone 0 | Existing owner-qualified native mesh operations |
| Harness packaging through Hub | Milestones 1 and 4 local | Agent catalog changes without core edits |
| Hive package distribution | Milestones 3 and 4 local | Destination admission and immutable content only |
| Governed overlays | Milestones 4 and runtime CAS gate | Governance inbox and registry-owner activation |

Each lane owns a component boundary and focused evidence. Only the integration
branch builds a global candidate. Runtime changes remain separate PRs assigned
to `skhaz`; Bee never merges or carries a private runtime semantic fork.

With the current source as the baseline, the next dependable global Agent build
is a same-day checkpoint after its remaining recovery proof and release gates.
The complete four-harness local/Docker workflow is approximately two to four
focused working days. Coherent folder/workspace/display behavior and a real
two-node Hive add roughly three to five days. Hub admission/distribution and
governed overlays add roughly five to eight days. Parallel work makes a credible
Bee v1 an eight-to-twelve-working-day target if the existing runtime and cluster
contracts hold; a new runtime semantic blocker would move that date and must be
reported with a reproducer and PR rather than hidden in Bee.
