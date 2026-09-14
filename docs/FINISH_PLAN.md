# Finishing Bee

This is the operational plan for the first complete Bee release. Bee is finished
when one installed executable is a dependable local coding desktop, can run
managed coding agents locally or in Docker, can join other Bees through the
native mesh, can install independently packaged components from Hub, and can
apply reviewed registry overlays through governance.

The implementation stays inside the boundaries already built:

- the workspace host owns applications and retained application state;
- a display owns presentation and layout, and an attachment owns live control or
  observation;
- threads own durable Agent communication and subscriptions;
- the native mesh and Hive supervisors carry cross-node operations;
- the Hub resolves immutable content but does not authorize it;
- governance decides protected changes and the registry owner applies them;
- native `exec.docker` is the only Docker execution path.

There will be no second mesh, Bee message-ingress API, alternate registry,
Docker control plane, or dependency on `../bee-legacy`. Production loads only
`src/`; tests and fixtures stay outside the pack.

## Current truth

The installed Train A executable has SHA-256 `4692e267` and source `414c03b`.
It is the rollback point. It passed offline boot, native Agent selection, scoped
Codex MCP/hooks, recovery, pack inspection and atomic installation.

The integration branch is `feat/docker-harness-delivery-20260913`; this execution
queue was reconciled against implementation base `2cc4e1f`. The worktree also
contains an uncommitted Grok B1.1 candidate; those files are not a release source
until the focused acceptance below passes and the result is committed.

Completed on this branch:

- all four CLI aliases resolve the same managed definitions as the Agent picker;
- raw-argument and duplicate-alias bypasses refuse before admission;
- Claude and Codex inherit their normal global configuration additively;
- Agy additive configuration inheritance is complete;
- the direct native Docker PTY and lower placement foundations pass;
- the Hub already implements most of its local immutable
  install/update/remove, migration, receipt and recovery backend;
- workspace host/client, display, Hive, thread, gateway, governance and
  authoring foundations exist, but their final public journeys do not.

The uncommitted Grok B1.1 candidate now replaces the invalid provider-owned
`managed_config.toml` path with a private composition base and structural TOML
insertion. Credential definition and use-time digests now cover the normalized
setup descriptor without hashing setup contents, and the launch specification
is the sole owner of Grok's Bee MCP permission. The placement authority matrix
and full Lua suite now pass: 893/893 behavioral tests. Real Grok 1.0.30 also
passes the clean/login/cancel/restart path, and authenticated startup commits its
SessionStart record with user hooks and Bee MCP visible. The remaining B1.1 issue
is a Go assertion that expects Grok's inspected hook event and source path in the
wrong spelling/form; the observed event is `session_start` and the hook source is
the private hooks directory. After correcting that assertion, the authenticated
run must finish its global/project tree fingerprints and the 27-file bounded diff
must receive one review. Global Bee must not be built from this dirty worktree.
`docs/BUILD_SEQUENCE.md` still describes the earlier Claude/Codex-only launch
checkpoint; update it with the four-provider callable status when B1.1 lands so
the implementation map and this operational plan agree.

### Reusable runtime gates

Bee implementation continues while these reusable runtime proofs are completed
in separate PRs assigned to `skhaz`:

1. **Selected default state directory.** The executable supplies one default
   state root to every database/resource declaration; explicit `--state-dir`
   takes precedence. Existing explicit paths retain their meaning.
2. **Atomic registry compare-and-set.** Hub publication and overlay activation
   can bind a write to the reviewed registry revision. A concurrent writer causes
   a conflict before publication.
3. **Remote actor lifecycle.** Native mesh acceptance proves authenticated public
   enrollment/discovery, exact remote actor exit delivery, destination restart and
   same-name rejoin without a Bee remote-monitor subsystem.
4. **Narrow structural TOML insertion.** Grok private configuration uses the
   reusable `toml.insert(document, path, source)` operation. Runtime PR #746 is
   assigned to `skhaz`; its candidate is pinned at `ce0c3e9d3b` with SHA-256
   `8d36335263418328f8a5c2ca117ce2fe612d890b3d5c74062eb69cb15408b240`.
   Bee does not expose general TOML parsing or carry a private copy of the codec.

The next global promotion requires gates 1 and 4. Connected Bee requires gate 3.
Hub admission and governed activation require gate 2. Candidate binaries may be
used for acceptance, but Bee does not merge these runtime PRs.

Before implementation claims depend on these gates, copy each accepted runtime
pin, digest, proof command and remaining limitation into
`docs/handoffs/STATUS_RUNTIME_GATE.md`. The finish plan orders work; that handoff
is the canonical runtime evidence.

## Definition of finished

These six journeys must pass from one tagged executable:

1. **Open locally.** `bee` starts offline in the current folder without waiting
   for Hive, restores the correct project workspace, and gives each client an
   independent durable display.
2. **Run an Agent.** The picker and `bee claude|codex|agy|grok` run the user's
   ordinary installed harness with its global behavior intact, plus admitted Bee
   instructions, hooks and MCP. Each window has one durable thread and predictable
   close, restart and recovery behavior.
3. **Change isolation.** The same saved profile runs locally or through native
   `exec.docker`. Identity, thread, project, tools, terminal behavior and recovery
   stay the same; only isolation changes.
4. **Join a Hive.** Two real Bees connect through the native mesh, show clear
   Hive/node/workspace/display state, retain applications when a client leaves,
   and support controller transfer and observers.
5. **Install a component.** Modules plans, reviews, installs, updates, recovers
   and removes an immutable app or independently packaged harness. A destination
   Bee can install admitted content without receiving the source Bee's authority,
   credentials, processes or mounts.
6. **Edit safely.** A user or Agent stages an exact-revision overlay, reviews its
   source and capability changes, submits protected effects to the right inbox,
   and the registry owner applies or rejects it once. Apply and rollback have
   durable receipts.

### Release scoreboard

This table is the progress view. A journey moves to **ready** only when its
installed-executable acceptance passes; source code or a fixture alone is
**partial**.

| Journey | State | Remaining release boundary |
|---|---|---|
| Open locally | partial | executable-selected state root for every store; offline folder and multi-display installed proof |
| Run an Agent | partial | land Grok B1.1, saved-profile UI, durable four-provider session/recovery proof |
| Change isolation | foundation | compose the same saved profiles through native `exec.docker`; reconcile and recover containers |
| Join a Hive | partial | public enrollment/discovery, project-node selection, controller transfer, remote placement and two-real-runtime recovery |
| Install a component | partial | close local Hub lifecycle, protected admission and independently packaged app/harness proofs |
| Edit safely | foundation | complete the governed stage/review/apply/receipt/rollback journey over released registry CAS |

## Critical path

The implementation lanes can run in parallel. Their release gates are
sequential and use immutable commits.

```mermaid
flowchart LR
    A[Train A installed] --> N[Native Agents]
    A --> T[Folder, display, Hive]
    A --> H[Local Hub lifecycle]
    S[State-dir gate] --> N
    M[TOML insert gate] --> N
    S --> T
    N --> X[Docker parity]
    N --> P[Harness packages]
    H --> P
    T --> D[Cross-node distribution]
    P --> D
    H --> I[Protected Hub admission]
    C[Released registry CAS] --> I
    I --> O[Governed overlays]
    C --> O
    N --> R[Final release]
    X --> R
    D --> R
    O --> R
```

Folder/display/Hive work does not depend on finishing Agents. Local overlay work
does not depend on cross-node distribution. Package distribution and overlay
activation converge only at the final release.

## Immediate execution queue

This queue turns the parallel lanes into reviewable promotions. A later item may
be implemented early when it does not share mutable files, but the global binary
advances only at the named promotion.

| Order | Lane | Work unit | Ends when |
|---|---|---|---|
| 1 | Agents | Close Grok B1.1: normalize the final real-provider inspection assertion, finish tree fingerprints, review and land the bounded diff | Real Grok 1.0.30 passes clean/login/cancel/restart; final private TOML is correct; global and project trees are byte-identical; no child starts or configuration publishes after refusal |
| 2 | Agents | Finish saved profiles and durable provider sessions for Claude, Codex, Agy and Grok | Picker and CLI use the same profile; each window owns one thread; title/activity/hooks/MCP and cold recovery pass across presenter, client and owner replacement |
| 3 | Release | Promote **Native Agents** from one clean immutable commit after runtime gates 1 and 4 | Full check, standalone, offline/restart/recovery, pack inspection and atomic install pass; this becomes the new rollback point |
| 4 | Topology | Finish folder-to-state selection, durable displays, asynchronous Hive rejoin, F9 topology and controller transfer | New folders isolate state, same-folder clients get predictable displays, local boot never waits for Hive, and two real runtimes pass enrollment, selection and viewport rejoin |
| 5 | Hub | Close local immutable install/update/remove first, then protected admission using released registry compare-and-set | One independently packaged app can enter and leave the catalog without a core edit or authority leak; harness definitions remain separate for extraction in order 8 |
| 6 | Release | Promote **Local Components** | Correct folder/display behavior and admitted local Hub components pass together from a clean executable |
| 7 | Docker | Route the same four saved profiles through native `exec.docker` and the existing carrier/gateway | Local and Docker differ only by isolation; lifecycle, terminal, hook, MCP, recovery and secret checks match on Linux and Docker Desktop/WSL |
| 8 | Automation | Prove the native runner/dataflow path, freeze accepted schemas and extract independently mounted packages | One headless runner turn and two-node settle pass; host and standalone package closures behave identically with no duplicate IDs |
| 9 | Release | Promote **Docker Agents** | All four real providers pass native and Docker profile acceptance from one executable |
| 10 | Distribution | Finish remote placement and transfer admitted immutable app/harness packages through the native mesh and Hub receipt model | Remote child/carrier/gateway/PTY and package install/restart/update pass after sleep, lost acknowledgments and destination restart |
| 11 | Release | Promote **Connected Bee** | Public enrollment/discovery, remote selection, placement, approvals, retained apps and package delivery pass between two real Bees |
| 12 | Overlays | Complete `stage -> inspect -> submit -> decide -> apply -> receipt -> rollback` | Exact-revision apply, protected approval, stale refusal and rollback pass for user and Agent edits |
| 13 | Release | Promote **Editable Bee v1**, then harden and tag | All six finished journeys pass twice on the target platform matrix and the website/docs match the tagged executable |

The integration owner keeps the critical path on orders 1 through 3 while the
topology, Hub and Docker lanes work independently on orders 4, 5 and 7. No lane
adds a replacement mesh, registry, Docker service or Bee-specific runtime API.
The existing host/client and single-controller acceptance is a retained
prerequisite for Native Agents: every Agent promotion reruns it and may not
regress independent display state, stale-controller fencing or retained apps.
Governed overlay implementation may start as soon as local Hub admission and
released registry compare-and-set are stable; only overlay replication waits for
Connected Bee.

### Current bounded unit

Work stays on this unit until it either passes or produces one named external
blocker:

1. normalize Grok inspection events by case and separator, require the private
   hooks directory and its `user` source type, and retain the user Stop hook's
   `configToml` source proof;
2. rerun authenticated real Grok 1.0.30 and finish the global/project `.grok`
   tree fingerprints;
3. rerun Go vet/compile and the managed Grok fixture; retain the already-passing
   893/893 Lua and clean-start evidence unless the implementation changes;
4. review all 27 Grok B1.1 files as one authority/configuration/lifecycle unit;
5. update its implementation status and `docs/BUILD_SEQUENCE.md`, commit the
   bounded diff separately from this plan update, then continue directly to saved
   profiles and durable sessions.

No unrelated refactor, UI polish or new provider abstraction enters this unit.
Once the Native Agents journey passes from a clean commit, install it globally
before continuing broader cleanup.

### Execution discipline

- Finish user-visible vertical slices before reorganizing working code. Remove
  obsolete POC and fallback paths only after their replacement journey passes.
- Keep at most four implementation lanes active: Agents, topology, Hub and
  Docker. Use additional agents for bounded acceptance, review and independent
  files, with one integration owner resolving shared seams.
- A lane reports progress only as a passing acceptance proof, an immutable commit
  ready to integrate, or one precisely reproduced blocker with an owner.
- Build the global executable only from a clean immutable integration commit.
  Never promote a dirty worktree or bypass a failing production lint gate.
- Prefer existing runtime, mesh, registry, thread, gateway and `exec.docker`
  primitives. A new abstraction must remove duplicated authority or lifecycle
  logic and must have a current consumer.

### Delivery windows

These are focused engineering windows after their named runtime prerequisites
exist. They are planning ranges, not release claims.

| Promotion | Remaining focused work | External gate |
|---|---:|---|
| Native Agents | 1–2 focused days | selected state root and TOML insertion runtime cuts |
| Local Components | 3–5 focused days after Native Agents | registry compare-and-set for protected admission |
| Docker Agents | 2–3 focused days after Native Agents; may overlap Local Components | none beyond the Native Agents runtime base |
| Connected Bee | 3–5 focused days after Local Components and package extraction | remote lifecycle and stable two-node package transfer |
| Editable Bee v1 | 4–7 focused days after Connected Bee and Docker Agents | released registry compare-and-set |

Every window ends at an installed executable and user journey. A lane that misses
its acceptance proof does not consume release time through polishing or unrelated
cleanup; its failing boundary becomes the next bounded work unit.

With the runtime gates available and topology/Hub/Docker work kept parallel, the
estimated critical path is 11–19 focused engineering days. The first usable global
promotion, Native Agents, remains the 1–2 day target; later promotions do not
delay it.

## Work plan

### 0. Freeze state selection

Before the next global promotion, make the executable-selected folder derive one
default state root for all Bee databases and retained resources. Explicit
`--state-dir` wins. Prove old default state imports without deleting it, two
folders remain isolated, and profiles, conversations, threads, Hub receipts,
workspaces and displays survive restart and a binary upgrade.

Write one store-selection matrix before changing paths. For every store it names
the owner, whether it is project-selected, user-shared or explicitly overridden,
its import source and its restart/upgrade rule. Shared registry history and
authorized overlays must not silently become empty merely because a project
folder changes. Every database declaration follows the matrix; no service derives
an alternate private root.

Exit proof: the installed executable opens the intended folder offline and every
store resolves beneath the selected root or its explicit override.

### 1. Finish native Agents

This is the immediate lane and the shortest route to the next useful global
build.

1. Complete the Grok private composition against runtime PR #746:
   - snapshot the approved user `config.toml` once into private retained state;
   - structurally insert only Bee's scoped `mcp_servers.bee` subtree;
   - refuse an existing semantic `mcp_servers.bee` collision;
   - bind the normalized setup descriptor into credential definition and
     projection digests;
   - compose only a base returned by the current authorized credential
     initializer, and refuse before publication or child start otherwise;
   - emit `--allow MCPTool(bee__*)` exactly once and keep Bee hooks in the
     private `.grok/hooks/bee.json`;
   - do not write into the project or global `.grok` tree.
2. Prove real Grok clean start, authenticated start, cancel and restart. Hash the
   user's global and project trees before and after. The selected private config
   must remain present after Grok exits.
3. Complete clean-install defaults and saved profile create/edit/select. The
   public profile remains:

   `profile = harness + isolation + options + MCP scope`

   Stored additional instructions are profile data. Dynamic context and any
   function-built instruction text are resolved at admission and never become
   stored authority. Bee adds instructions to provider behavior; it does not
   replace the provider's built-in system prompt.
4. Give every attempt an OS-assigned MCP endpoint and a per-attempt secret. The
   callable surface is the intersection of saved profile scope, host policy and
   the request's dynamic `ctx`; ports, secrets, grants and `ctx` are never durable
   profile data. Hooks and MCP bind to the same attempt and thread. Prove two
   simultaneous attempts get distinct endpoints and secrets, cross-attempt calls
   refuse, and a retired attempt cannot call after restart.
5. Bind every provider window to one durable thread, committed activity/title
   state and subscription cursor. The disconnected surface keeps the last
   confirmed value; Timeline resumes its cursor; Inbox distinguishes empty from
   unreachable. Prove presenter replacement, client reattachment and owner/host
   restart separately.
6. Prove cold recovery where provider credentials permit it. Reconcile a
   surviving child before starting a replacement. Login, subscription and account
   refusals remain visible provider outcomes.

Maintain a four-row provider matrix. Each row requires a real installed binary,
real configuration composition, MCP/hook delivery, close/cancel and restart. It
tests present and absent user configuration, preserves provider-specific login
state and user hooks, and fingerprints the provider's global and project trees
before and after. When credentials exist it also requires an authenticated
startup and turn; otherwise the row records the provider's explicit login/account
refusal and remains unqualified for authenticated use. No secret, endpoint or
grant may appear in argv, records, logs, retained homes or the pack. Fixture-only
evidence never marks a provider working.

Exit proof: UI and CLI launch all four real harnesses; global settings remain
intact; scoped MCP and hooks reach the bound thread; cancel, close, restart and
resume work; pack inspection finds no credentials or fixtures.

### 2. Make folder, display and Hive behavior coherent

1. Consume the state-root decision from Plan 0 without deriving alternate paths
   inside Bee services.
2. Implement one public launch decision table:
   - `bee` in a new folder creates or reuses that project node/workspace and a
     current-terminal display;
   - another `bee` in the same project attaches or creates an independent display
     according to explicit controller rules;
   - explicit client/observe commands attach to a selected existing display and
     do not change the project selection.
3. Present the local desktop immediately. Hive join and rejoin run asynchronously.
   A remote node may remain connectable for 60 seconds, while local input, cancel
   and exit stay responsive.
4. Implement public enrollment, discovery and selection. `bee hive` and the
   workspace/display switcher use supervisor admission over the native mesh; they
   expose no transport-derived user authority.
5. Stop representing physical clients as durable Hive nodes. Displays have stable
   friendly identities, attachments have leases and generations, stale displays
   retire gradually, and retained applications/layout survive client loss.
6. Finish the compact shell switcher and F9 topology view. Show Hive service,
   executing node, workspace, display, controller/observer state and precise
   reachable/unavailable/unauthorized status without polling dead clients.
7. Implement safe `Send to display`: revoke or fence the previous controller
   before granting the next one; allow many observers; never let an uncertain
   result create two input controllers.
8. Prove two actual Bee runtimes over the existing native TLS mesh, including
   sleep/rejoin, remote viewport, resize/input, approval and retained apps.

Public Hive activation waits for the reusable remote-lifecycle gate. Internal
loopback fixtures may develop the UI and protocol earlier, but they do not make
enrollment, discovery or remote attachment callable in a promoted executable.

Exit proof: offline folder boot is immediate, several clients/displays behave
predictably, stale records retire, and the two-node native-mesh journey passes.

### 3. Qualify local Hub and package components

1. Treat the current Hub backend as implemented foundation. Close its remaining
   combined regression and native lifecycle evidence instead of rebuilding its
   planner, migration or receipt model.
2. Measure and bind the exact dependency/artifact closure, configuration
   parameters, migration bodies/effects and destination requirements before
   review. A missing or changed input invalidates the plan.
3. Require the released generic registry compare-and-set operation for every Hub
   publication. The current single-writer revision check is foundation evidence,
   not the final concurrent-writer guarantee.
4. Add the missing protected admission effect owner. Hub publication installs
   immutable definitions; it never grants their capabilities. An unadmitted app
   stays out of Tools and direct open refuses.
5. Bind approval to the exact artifact, definition digest, registry revision and
   host-selected capability set. Revalidate all four before the registry owner
   publishes the admission effect. The requester cannot approve its own protected
   install, and a consumed decision cannot authorize a second effect.
6. Prove lost acknowledgments, injected migration/install failures, process
   restart and worker takeover. Resume from durable receipts without manually
   applying migrations or repeating committed effects.
7. Preserve service-owned application configuration and state across update and
   restart. Registry metadata remains declarative; app data remains in its owning
   database.
8. Keep Claude, Codex, Agy and Grok as independent declarative components. This
   local Hub milestone proves one already extracted app package end to end. The
   four harnesses retain separate definitions and namespaces here; their
   independent package install/update/remove proof follows package extraction in
   Plan 5 rather than being inferred from their embedded source layout.

Exit proof: clean and populated stores pass one independently packaged app's
install/update/remove, injected failure recovery, admission/revocation, restart
and pack inspection. Harness package parity remains an explicit Plan 5 gate.

### 4. Complete Docker as a profile choice

1. Route the existing carrier and managed-window lifecycle through the native
   `exec.docker` placement binding. Keep the same attempt owner, sweeper, thread,
   driver and gateway. Do not depend on the optional userspace Docker component.
2. Keep session mode and interactive-window mode explicit. One request owns
   exactly one measured execution/container identity; a PTY does not imply
   structured ACP or RPC behavior.
3. Record creation intent before dispatch and label containers with exact
   owner/action/attempt identity. Implement start, stop, inspect, reconcile and
   cleanup, including surviving-container recovery.
4. Run the normal installed harness command. Mount the selected project and the
   minimum approved configuration/credential inputs. Keep Bee material and
   writable harness state in attempt/session storage. AppArmor is optional.
5. Expose the same randomized authenticated MCP/hook endpoint to the container;
   intersect profile scope, host policy and dynamic context at admission.
6. Refuse when a profile's required hardening is unavailable; portable profiles
   use non-root execution, dropped capabilities, the daemon's seccomp policy,
   bounded resources and only their admitted mounts.
7. Prove PTY input/output/resize, close, cancellation, create/start failures,
   owner restart, container removal and absence of secrets from argv, records,
   logs and the production pack on Linux Engine and Docker Desktop/WSL.

Run the same four-provider configuration matrix as native placement: ordinary
installed harness behavior and login state remain available through only the
admitted mounts/projections, provider trees remain unchanged, and a local profile
switches to Docker without changing its thread or MCP/hook scope.

Exit proof: changing only `isolation` from Local to Docker preserves the Agent's
identity, project, thread, tools, hooks, terminal and recovery behavior for all
four providers.

### 5. Extract packages, then place and distribute through Hive

1. Prove the native runner without a PTY or MCP shortcut: one admitted headless
   turn and a two-node dataflow settle use the same request, delivery and receipt
   queries as interactive Agents.
2. Freeze accepted schema revisions and extract app and harness closures into
   independently mounted packages. The host assembly and minimal standalone host
   must behave identically; reject missing requirements and duplicate definition
   IDs. Production `src` consumes packages through declared dependencies.
3. Complete destination admission and remote placement for child, carrier,
   gateway and PTY. Prove destination restart, same-name rejoin, Mac sleep,
   revoked attachments, lost launch acknowledgments and remote approvals without
   inferring authority from mesh membership.
4. Transfer content-addressed immutable package data through supervisor-selected
   native-mesh operations. Reuse the Hub plan and receipt types; do not create a
   second installer or transport.
5. The destination independently resolves policy, reviews capability changes,
   admits and installs. Transfer package bytes and declared filesystem resources;
   never transfer credentials, grants, PIDs, live mounts or database ownership.
6. Transfer a saved Agent profile only with its definition/profile revision,
   options and declared MCP scope. The destination re-resolves its own harness,
   policy, credentials and dynamic context; source login state, human identity and
   authority never ride with the profile.
7. Add retry/restart recovery around content chunks and install receipts. A fat
   storage Bee is a role expressed by installed components and admitted
   interfaces, not a special topology.
8. Prove one app and one harness move to a second node, install, launch, restart
   and update while the source can disappear after transfer.

Exit proof: independently mounted packages behave the same as the host assembly;
another Bee remotely runs an admitted Agent and gains usable components from
immutable admitted content with no core edit or authority leakage.

### 6. Finish governed overlays and self-edit

Use one path for user edits, Agent edits and installed overlay content:

`stage -> inspect -> submit -> decide -> apply -> receipt -> rollback`

1. Store the staged candidate durably with base registry revision, entry digests,
   exact dependency/artifact closure, parameter bindings, source, migration
   bodies/effects, declared capability changes and target scope. Staging grants
   nothing.
2. Show a review that distinguishes code/data changes, capability changes and
   protected core targets. Bind an inbox item to the exact candidate digest and
   effect.
3. The governance owner decides. The registry owner alone performs compare-and-set
   activation against the reviewed revision. A stale review conflicts and cannot
   silently replan.
4. Record applied revision, changed definitions and inverse data required for
   rollback. Rollback is another authorized compare-and-set operation.
5. Recover from lost apply acknowledgments, process restart and worker takeover
   using durable receipts. Refuse self-approval, replayed decisions and any
   candidate whose artifact, closure, migration or reviewed revision changed.
6. Expose stage, inspect, status and submission through narrow Agent MCP tools.
   Agents never receive direct registry publication authority.
7. Replicate approved declarative overlays through the same package/content path.
   Service-owned databases and thread data keep their existing owners.

Acceptance includes two concurrent apply attempts against one base revision,
replayed and stale approvals, a direct Agent publication attempt, owner restart
between commit and reply, and rollback of supported migration effects. A running
owner keeps its admitted old code until the documented authorized restart or
rejoin loads the new revision.

Exit proof: an Agent prepares an ordinary edit, the user reviews it, the owner
applies it once, protected changes require the configured approver, stale edits
refuse, and rollback restores the measured prior definitions.

## Global promotion checkpoints

Global Bee is updated only from a clean immutable integration commit. Docker does
not hold back a qualified native Agent build; later work continues in isolated
branches.

| Checkpoint | User-visible result | Required work |
|---|---|---|
| Native Agents | Correct offline folder state plus four working managed harnesses, profiles, threads and recovery | Plans 0 and 1 |
| Local Components | Correct folders/displays and admitted local Hub components | Plans 2 and 3 |
| Docker Agents | The same four profiles work through native Docker | Plans 1 and 4 |
| Connected Bee | Public two-node Hive, remote Agent placement and cross-node app/harness delivery | Plans 2, 3 and 5 |
| Editable Bee v1 | Cross-node component delivery and governed overlays | Plans 1–6 |

Each promotion runs:

1. `make lint` and focused behavioral acceptance;
2. source and packed user journeys, including standalone source/pack isolation;
3. one full `make check` with the exact pinned runtime, including
   `tests/native_binary.py`, `tests/recovery.py` and the detached lifecycle gate;
4. a fresh standalone build and offline/restart/recovery checks;
5. production-pack inspection for tests, fixtures, credentials and local state;
6. an installed upgrade that preserves registry history, admitted overlays and
   every owned database, then proves a fresh owner loaded the new executable;
7. an atomic six-file install with a recorded rollback receipt.

The six installed files are `bee`, `bee.LICENSES.txt`, `bee.go.mod`,
`bee.go.sum`, `bee.provenance.json` and `bee.runtime-patches.tar.gz`.
Every promotion preserves all databases, profiles, conversations, workspaces and
displays. Running owners may retain loaded code; acceptance of a new build uses a
fresh owner.

## Ownership and runtime boundary

Four implementation lanes may run concurrently: Agents, Docker, topology and
Hub. Distribution begins after topology and independently packaged Hub components
pass. Governed overlay work can begin after local Hub admission is stable and the
registry compare-and-set primitive is released.

Every unit has one editing owner, one bounded diff and one named executable exit
proof. Read-only audits can run in parallel. The integration owner accepts only
immutable commits with focused evidence, resolves conflicts, runs the release
gate once and performs global installation. Work that does not close a user
journey or an exit proof is deferred.

Any runtime semantic change is a separate runtime PR assigned to `skhaz`. Bee may
test against a pinned candidate, but it does not merge runtime PRs or carry a
private replacement API. Runtime changes are limited to reusable primitives;
Bee-specific policy stays in Bee.

## Final hardening

After all six journeys pass together:

- remove dead POC, fallback and superseded release paths;
- verify no test-only entries or fixtures are in production packs;
- measure cold/warm startup, idle CPU/goroutines/memory and bounded shutdown;
- run Linux, WSL, macOS, Docker Engine/Desktop and two-host Hive acceptance twice;
- audit migration from existing global databases and injected rollback failures;
- update implementation docs and `bee.wippy.ai` so claims and MIT notices match
  the tagged executable exactly.

ACP, pi RPC and additional provider transports follow v1 as independently
installable components. The v1 plan does not claim those semantics from a PTY or
delay the six release journeys on them.

No architecture-count test is a release gate. No database is deleted to make a
migration pass. Design proposals become implementation status only after their
public journey and executable acceptance exist.
