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

The active release branch is `feat/docker-harness-delivery-20260913`. Its next
release is deliberately smaller than the whole roadmap: it makes native Claude
and Codex dependable with the user's ordinary configuration, Bee's additive
hooks and MCP, and durable recovery. The historical-pin recovery regression and
the focused native acceptance are complete. The global executable has not been
updated from this branch.

The host HOME release blocker is corrected in the active source. A profile may
request host HOME only when the host-selected launch policy explicitly
authorizes it. The decision participates in the policy digest and is enforced
at carrier planning, native preparation, and again before materialization.
Registry profile metadata continues to describe the requested isolation; it
never grants host filesystem authority. Strict lint, all 883 Lua tests, exact
native/offline acceptance, Codex hook/MCP acceptance, both recovery paths, and
pack exclusion inspection pass on the rebuilt candidate. The final exact-source
repository check and committed rebuild remain before global installation.

The remaining immediate queue is fixed:

1. finish one captured `make check` on the exact source;
2. commit and push the coherent checkpoint;
3. rebuild from the commit and atomically install the six global artifacts with
   a tested rollback.

## Completion rules

Each milestone ends with one immutable candidate and these gates:

1. strict lint and focused behavioral tests;
2. the relevant source and packed-application user journey;
3. standalone executable and restart/recovery acceptance;
4. inspection proving tests, fixtures, credentials and local state are absent
   from the production pack;
5. one full `make check` on the exact candidate;
6. an atomic six-artifact global install with rollback, preserving all existing
   databases, profiles, conversations, workspaces and displays.

Passing a model test, fixture or source-only check does not complete a public
feature. Full regression runs once per integration candidate rather than after
every small change. Focused checks carry intermediate development.

## Milestone 0: release the current native Agent foundation

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
- Preserve the result of the already-running broad regression as evidence for
  the pre-fix slice, then run the final broad regression on the corrected exact
  source. Build one fresh standalone candidate and run installed-to-candidate
  and same-build recovery.
- Prove offline boot, native Agent selection, Claude/Codex inherited HOME and
  custom configuration directories, scoped MCP, additive hooks, cancellation,
  and responsive close on that candidate.
- Commit and push one coherent checkpoint, then atomically refresh global Bee.

Exit: `bee`, `bee claude`, and `bee codex` start without network access to Bee
services; normal global harness login/settings remain available; Bee's MCP and
hooks are additive; an interrupted conversation reopens with the same durable
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
not build another installer or import Keeper.

- Complete install, update and remove with immutable versions, transitive
  requirements, provenance, migrations, recovery receipts and rollback.
- Connect installation to protected application admission so an installed app
  can appear in Tools only after reviewed permissions are admitted.
- Package the four harness drivers independently and prove installing or
  updating one changes the Agent catalog without editing Bee core.
- Add update discovery and preserve module values/configuration across updates.
- Transfer package definitions and immutable files through Hive with destination
  admission. Never replicate credentials, grants, live PIDs, mounts or database
  ownership merely because a component exists on another node.
- Keep filesystem synchronization as an explicit component-owned resource
  contract for packages such as WASM or future GPU workers.

Exit: a clean Bee can find, preview, install, authorize, launch, update, recover
and remove an app or harness, locally and on an admitted Hive node.

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
