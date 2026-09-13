# Work journal

Shared, append-only log for every agent working on Bee. One entry per unit of
work: date, author, what changed, what was proven, what is next, and what
others must not touch. Newest entry last. Decisions live in the design docs;
this file says who is doing what right now so a new agent can join without
asking.

The same facts are recorded in the wolfden journal "Bee Harness"
(`journal_id 01a06e56-ba58-7c5a-bd69-b7feb109a05d`, graph `bee-harness`, node
`root`); open a cursor there with your own `agent_id` and append a fact for
every entry you add here.

## How to join

1. Read `docs/README.md`, `docs/BUILD_SEQUENCE.md` and `docs/HIVE_PROTOCOL.md`.
2. Read the last five entries here and the "Open lanes" table.
3. Claim a lane by appending an entry before editing; name the files you own.
4. Prove with `make lint`, `make test` and the proof named by the lane before
   you append a "done" entry.

## Open lanes

| Lane | Owner | Files | Proof |
|---|---|---|---|
| Thread authority, records, persistence (build sequence steps 2 to 5) | Claude | `src/threads/**`, `tests/lua/threads/**`, `tests/modules/threads/**` | `make test`, `make threads-module` |
| Hive protocol: root index, types, catalog, interfaces, client, telemetry | Claude | `src/hive/_index.yaml`, `src/hive/*.lua`, `src/hive/telemetry/**`, `tests/lua/hive/**`, `tests/modules/hive/**` | `make test` |
| Hive protocol: supervisor host, supervisor, hello, admission, guards, two-runtime fixture | Astra | `src/hive/supervisor/**`, `tests/hive_protocol.py`, `tests/fixtures/hive_protocol/**` | `tests/hive_protocol.py` |
| Hive transport, remote Terminal, presenter delivery, launch wiring, runtime patches, native manifest | Astra | `src/core/launch/**`, `src/core/terminal/**`, `runtime/**`, `wippy.build.json` | `make hive-*-check` |
| Driver contract, kit, transports, provider bindings and fixtures (build sequence step 7) | Claude | `src/driver/**`, `tests/lua/driver/**`, `tests/fixtures/drivers/**` | `make test` |
| Harness catalog, carrier and launch admission (build sequence step 9, harness lane) | Claude | `src/harness/**`, `tests/lua/harness/**`, `bee:harness_activation`, `bee:launch_policy_managed` and `bee:launch_spawn_policy` in `src/_index.yaml` | `make test`, `tests/architecture.py` |
| Resource authority and credential broker (build sequence step 6) | Claude | `src/resources/**`, `src/credentials/**`, `tests/lua/resources/**`, `tests/lua/credentials/**`, host entries and policies in `src/_index.yaml`, granted mode, projections and the sweeper in `src/placement/native/**` | `make test` |
| Placement contract and native placement (build sequence step 8), shared persist ledger | Claude | `src/placement/**`, `src/persist/**`, `tests/lua/placement/**`, placement policies in `src/_index.yaml` | `make test` on the pinned runtime; `tests/lua/placement` against the runtime PR 694 binary for group cleanup |
| Website | Claude | `build/site/**`, `install.sh`, `install.ps1` | `build/site/deploy.sh` |
| Embedded cache, Builder and release proof | Codex cache lane | Isolated runtime and Builder checkouts; cache handoff/evidence only in shared Bee | Runtime race tests, Builder checks, fresh offline Bee executable |

## Entries

### 2026-09-08 Claude: thread authority (step 2) done

Implemented `bee.threads.records`, `bee.threads.service`, evolved
`bee.threads.persist`; migrations 2 `thread_authority` and 3 `work_lifecycle`;
contracts `authority` and `lifecycle` with local bindings. Proven by 25 Wippy
tests under `tests/lua/threads` (140/140 in `make test`), `make threads-module`,
the journal proofs, pack and architecture. Details in `docs/THREAD_AUTHORITY.md`
section 9. Test support entries use `meta.type: test_support`.

### 2026-09-08 Claude and Astra: Hive protocol agreed

Three rounds produced `docs/HIVE_PROTOCOL.md`: six terms (Principal, Owner,
Operation, Request, Grant, Session), supervisor identity from the PID's node
and host components, exposure `meta.hive: open | approval | policy` with host
ceilings `hive.expose.<mode>`, interfaces with `operation_ref`, two session
transports, supervisor-pushed epochs, `bee.launch:supervisor` as the per-node
launch owner, six build steps. Step 1 split: Claude owns the root `bee.hive`
index, types, catalog, client and telemetry; Astra owns `bee.hive.supervisor`
and the two-runtime fixture. Neither edits the other's files; Astra supplies
its root entry blocks for Claude to integrate.

### 2026-09-08 Claude: Hive step 1, my side, in progress

Writing `bee.hive:types` (Call, Request, Reply, Grant, Session, Frame, Hello
decoders), `bee.hive:catalog` (snapshot, resolve, resolve_call,
apply_interface, summaries), `bee.hive:client` (`open():call(owner, target,
input, options)` to the local supervisor by LOCAL name, replies accepted only
from that PID on `bee.hive:supervisor_host`), and `bee.hive.telemetry`
(`presence`, `stats`, `catalog_list` as `open` operations). Suites under
`tests/lua/hive`. Not started: Sessions and grants (step 3), approval and
policy admission (steps 2 and 4).

### 2026-09-08 Codex/Astra: transport proof and enrollment boundary

Wolfden cursor `jc_1HYZK1CTT9212`, agent `codex-bee-hive`; checkpoint seq 36.
Remote desktop acceptance on `100.70.10.28` proves destination Bash execution,
resize, F12 and fresh-client reattachment to the retained shell. Presenter
queues are bounded and remote I/O does not block desktop input. Research
`runtime/research/peer-fence.patch` and `trust-owner.patch` pass internode race
checks, actual two-process trust/revoke/retrust with delivered relay traffic,
Load-time trust with real discovery, and a clean pinned candidate build.
These patches are not selected by the shared build manifest; global Bee is
unchanged. Public enrollment, discovery and workspace selection remain unfinished.

Full candidate `make check` passed core TTY source/pack checks (six rejoins,
crash recovery, 30–65 ms exits), then stopped on the concurrent Hive-client
strict-type errors. Claude is fixing that client; Codex leaves its files alone.
The full suite must be rerun once shared source is coherent.

Codex additionally owns `native/hive/identity/**` for durable machine identity,
distinct from Hive, runtime node and workspace identity. Root fixed corrupted
seed acceptance, trailing JSON, missing ID and formatting/error disclosure;
package race checks pass. The active Agy filesystem refinement owns `lock*.go`,
platform tests and README; root owns `identity.go` and `identity_root_test.go`.
Filesystem/Windows ACL review is incomplete. Do not edit this package concurrently.
Supervisor/admission integration remains upcoming work in the assigned Astra lane.
Detailed local continuation: `/tmp/bee-delivery-events-checkpoint.md`.

### 2026-09-08 Codex: embedded cache build lane in progress

Wolfden cursor `jc_JR2WJFEDZH68Y`, agent `codex-bee-cache`. Implementation is
isolated in `/tmp/runtime-cache-seed` (`feat/application-cache-seed`) and
`/tmp/builder-cache-seed` (`feat/embedded-cache`). Bee proof uses the published
checkout `/tmp/bee-github-audit`. Shared Hive files, runtime experiments and
`wippy.build.json` remain with their existing owners.

The runtime reads an immutable cache seed through its existing fingerprint and
artifact validation. Builder runs strict lint, exports the cache, then relinks
the executable with those bytes. Focused manager race tests prove valid seed
hits avoid type checking and writable cache writes; changed source, native
types and checker configuration cause recomputation. Earlier simulated fresh
startup measured 7541 ms without cache and 284 ms with lint-generated cache.
Those measurements do not yet prove the embedded executable.

Next: export edge cases, consolidated runtime/Builder checks, actual fresh
offline Bee proof and timings, and a focused upstream PR for Rodrigo review.

### 2026-09-08 Codex: embedded cache local proof complete

Runtime `0554e488a5`, Builder `cd304ef` and Bee integration `0791075` are committed
in the isolated cache checkouts. Builder validates the frozen application through
strict runtime lint, exports complete cache artifacts and relinks with the seed.
The runtime keeps strict checking on, invalidates changed source/dependencies and
native types, and shares the writable cache with staged update validation.

The final Bee binary reached a complete desktop in 335 ms median across five
fresh-state launches (323–478 ms), all with zero local cache files. Its offline
Docker acceptance passed every default app, Settings recovery, Terminal and F12.
Runtime race checks and changed-code lint pass; Builder `make check` and actual
hello cache/argument/base tests pass. The local Hub fixture additionally proves
update activation reuses the validation cache without rewriting files on first
launch, and failed updates preserve the selected deployment.

Evidence and binary: `dist/release-local/embedded-cache/PROOF.md`. Continuation:
[embedded cache handoff](EMBEDDED_CACHE.md). Wolfden cursor `jc_JR2WJFEDZH68Y`.
The user reported 90% GitHub quota usage. No Actions, pushes, releases or Hub
uploads were performed. Runtime review by Rodrigo and dependent PR publication
remain pending. Other agents retain the shared native manifest and runtime/Hive
experiments; this lane did not change the installed Bee.

### 2026-09-08 Codex/Astra: identity decoder and durability checks

Wolfden checkpoint seq 39. Root reproduced duplicate JSON version-field
acceptance and added explicit duplicate-field rejection. Root identity tests
pass under the race detector. `identity.go` now calls the platform path-based
permission check and propagates directory-sync failure after publication without
deleting the identity. The filesystem agent still owns `lock*.go`, platform tests
and README; final full-package/Windows review is pending. No release readiness
or public enrollment claim. Claude retains the shared Hive client/type lane.

### 2026-09-08 Codex/Astra: filesystem review checkpoint

Wolfden checkpoint seq 41, cursor `jc_1HYZK1CTT9212`. The Agy filesystem writer
finished; root now owns review of the complete `native/hive/identity/**` slice.
Removed a process-wide umask change and corrected test fixtures to create
explicitly private directories. The existing-insecure-directory regression
proves refusal without permission repair or identity creation. The full package
race suite and vet pass on Linux. Package README now reflects actual behavior.

Windows acceptance remains pending: existing-directory ACL validation currently
repairs permissions; creation and validation need separate paths. ACE parsing,
reparse handling and publication durability need platform review and execution.
The package is not wired into public enrollment. Public discovery and workspace
selection remain unfinished; no release or full Bee-suite claim. Claude retains
Hive client/types and thread ownership. Following journal seq 40, validation is
local with no GitHub requests.

### 2026-09-08 Codex/Astra: supervisor host admission prerequisite

Wolfden finding seq 42. Direct `spawn_monitored`, `spawn_linked` and
`spawn_linked_monitored` omit `process.host` in the runtime candidate; plain
`spawn`, `exec` and context-bound spawners check it. Do not treat the dedicated
supervisor host as a proven authentication boundary yet. Agy Gemini 3.8 Flash
owns a new isolated runtime regression file; root reviews downstream routing and
owns any fix. Shared Hive Lua and the native manifest remain unchanged.
Current strict lint still fails in the Claude-owned Hive client.

Identity Windows creation now supplies protected ACLs at directory/lock creation;
existing objects are validated without permission repair. Unsupported ACE layouts
and reparse points are refused. Linux race/vet pass; Windows regression tests
compile only. Windows publication durability and actual Windows execution remain
unverified. Root retains identity ownership.

### 2026-09-08 Codex/Astra: host check fixed, desktop gate pending

Wolfden checkpoints seq 44–45. Agy finished the runtime regression; root
reproduced all three denied-host admissions and added `process.host` checks to
the direct monitored/linked spawn variants. Full process-module race tests and
vet pass. Function generation-host tests pass under race. The MPL patch and
regressions are in `runtime/research/process-host-admission.patch`; route review
and remaining gates are in `runtime/research/PROCESS_HOST_ADMISSION.md`.

Clean pinned candidate build passed using local Git sources and cached Go
dependencies, with no GitHub requests. Temporary manifest:
`.bee-host-candidate.build.json`; binary `.wippy/bin/bee-wippy-host`, SHA-256
`8006ebbb09e0de665ccd1072f86ee34029171d508bede04f5b15e41b3c7b9f81`.
The shared native manifest and global Bee are unchanged.

The actual candidate desktop command uses `NATIVE_WIPPY`, not `WIPPY`.
Both baseline and candidate currently fail boot at `bee.hive:types:150:19`;
the source uses reserved `interface` as a local variable name. Root left the
Claude-owned Hive files untouched. Candidate log:
`/tmp/bee-host-candidate-desktop-check.log`. No new desktop acceptance claim.
All associated processes are finished. Next: resume shared acceptance once
Hive syntax/types are fixed, then supervisor composition/hello and public
machine enrollment, workspace discovery and remote Terminal selection.

### 2026-09-08 Claude: lint silently skipped two Hive files; cause found

`interface` is a reserved word in Wippy's typed Lua and `wippy lint` reports
nothing for an entry whose typed parse fails, so `bee.hive:types` and
`bee.hive:catalog` were never type-checked and their importers saw `any`.
Cause: the parse-error path in `cmd/wippy/cmd/lint.go` counted the error but
never rendered it. Fixed in runtime PR https://github.com/wippyai/runtime/pull/691
with a test; details in `docs/handoffs/LINT_SILENT_SKIP.md`. In Bee: renamed
the locals, split the primitive helpers into `bee.hive:bounds`, fixed the type
errors that then surfaced. A canary sweep confirms every library under `src`
is checked now.

### 2026-09-08 Codex/Astra: isolated actor admission proof in progress

Wolfden entry seq 47. Root owns `tests/hive_admission.go` and the additive
`make hive-admission-check` target. Agy Gemini 3.8 Flash owns only
`tests/fixtures/hive_admission/**` while writing the fixture. It must exercise
actual denied actors on an empty supervisor host, then an authorized spawn,
observed exit and denial during the restart vacancy. Shared Hive source is
excluded from this fixture. Runner vet passes; acceptance is pending delivery.

`docs/HIVE_SUPERVISOR.md` records the proposed peer establishment and replacement
rules; no callable supervisor API is claimed. Current broad core host grants
still need narrowing when supervisor composition is implemented. The runtime
patch by itself does not establish exclusive supervisor-host authority.
Claude retains the shared Hive client/types and thread lane.

### 2026-09-08 Codex/Astra: real actor host-admission proof passes

Wolfden milestone seq 49. Agy finished; root now owns the complete isolated
`tests/fixtures/hive_admission/**` fixture and Go runner. Root removed an `any`
bypass, gave the attacker an explicit minimal scope, required target-host
permission refusal, and removed a reply-before-EXIT assumption and timing sleep.

`make hive-admission-check NATIVE_WIPPY="$PWD/.wippy/bin/bee-wippy-host"` passes
strict fixture lint and real actor execution. The same final fixture against
the unpatched runtime fails with `NEGATIVE ADMISSION VIOLATION` in phase one.
Five direct and two context-bound forms are denied while the supervisor host is
empty, an authorized child runs there, and denial repeats after its observed
exit. Logs: `/tmp/bee-hive-admission-root-final.log` and
`/tmp/bee-hive-admission-baseline.log`. This does not load production Hive source.

The peer establishment/dispatch proposal is in `docs/HIVE_SUPERVISOR.md`, indexed
in the documentation map. Production scope composition, process-function bridge
restrictions, two-runtime hello, enrollment, discovery and public remote Terminal
selection remain unfinished. All task processes are finished; no manifest
selection, staging, commits or global installation. Claude retains shared Hive
client/types and thread work.

### 2026-09-08 Claude: Hive step 1, my side, landed

`bee.hive:bounds`, `bee.hive:types`, `bee.hive:catalog`, `bee.hive:client`,
`bee.hive:supervisor_host` and `bee.hive.telemetry` (`presence`, `stats`,
`catalog_list`, all `open`) are in `src/hive`, with host policies
`bee:hive_telemetry_policy`, `bee:hive_catalog_policy` and the ceiling
`bee:hive_exposure_policy` in `src/_index.yaml`. Proven by 15 Wippy tests
under `tests/lua/hive` (155/155 in `make test`): envelopes and digests,
ceilings under narrowed scopes, malformed declarations, interface narrowing,
telemetry bounds, and the client against a real fake supervisor process on
the supervisor host. Seam for Astra: topics `bee.hive.request`,
`bee.hive.reply`, `bee.hive.hello`, `bee.hive.epoch`; LOCAL name
`bee.hive.supervisor`; `types.decode_call` for local calls and
`types.decode_request` for forwarded requests; `catalog.snapshot`,
`catalog.resolve`, `catalog.resolve_call`, `catalog.apply_interface`;
replies `{ok, error, value, grants}`. Runtime PR 691 (lint hid parse errors)
assigned to Rodrigo.

### 2026-09-08 Claude: seam adjusted after Astra's round 5

`ResolvedCall` now carries the validated `Operation` (measured, limits,
schemas); the stats output schema is fully bounded; forwarded requests
require method `node_supervisor`, audience equal to the owner node, empty
delegations and a deadline the assertion cannot outlive (decoder tests
added). Host policies `bee:hive_supervisor_policy`, `bee:hive_dispatch_policy`
and `bee:hive_supervisor_spawn_deny` are in `src/_index.yaml`; the
`bee.hive:supervisor` process and `supervisor.service` blocks wait for
Astra's `src/hive/supervisor/**`. The `interface` reserved-word bug that broke
Astra's desktop gate at boot is fixed. `docs/HIVE_PROTOCOL.md` records the
spawn-variant host-check gap Astra found (journal 42, 44, 49). 155/155.

### 2026-09-08 Claude: step 3 delivery contract agreed; implementation starting

Round 7 with Astra produced `docs/THREAD_DELIVERY.md`: obligations versus
subscriptions versus projections, claim batches with their own identity,
owner-runtime incarnation (not waiter-owned, not per thread), dispatch intent
before release, reconciliation with explicit marks, one outstanding page per
subscription acknowledged by `page_id`, waits with register-recheck and a
final authoritative check, recap folded from records only. Migration 4
rebuilds `bee_thread_records` to admit `delivery.mark` and `request.answered`
only. `bee.threads.records` already decodes both families and enforces the
message outcome rules (requests and progress carry no outcome; a reply needs
`in_reply_to` and an outcome).

### 2026-09-08 Claude: step 3 units 1 and 2 landed (migrations 4 and 5, owner incarnation)

Migration 4 `delivery` rebuilds `bee_thread_records` with the kind CHECK
extended to `delivery.mark` and `request.answered` (foreign keys off on the
migration connection, `foreign_key_check` before commit, rows copied
unchanged) and adds owner, obligations, claim batches, deliveries, dispatch
intents, subscriptions and subscription pages; migration 5 `projection` adds
the checkpoint table. The ledger now applies one migration per transaction.
`bee.threads:owner` (process.service on the module's new `process_host`
requirement, default `bee:workers`) advances the owner-runtime incarnation
once at start; `bee.threads.persist:owner` establishes and reads it. Proven:
159/159, rebuild keeps rows and lifecycle references byte for byte, a broken
reference rolls the rebuild and its ledger row back, migration 1 checksum
unchanged. Next: obligations on message commit, claim batches, capacity
reservation for marks and answers.

### 2026-09-08 Codex: peer exchange review and embedded-cache coordination

Wolfden seq 54. The isolated `bee.hive.supervisor:peers` draft now passes
17 native Wippy cases, including independently reproduced lost-final-answer
recovery, completed-initial replay, reflection denial and bounded monotonic time.
The owner must still supply fresh random challenges and invalidate old grants
on a completed replacement. No public discovery or admission service is claimed.
Draft and review workspace: `/tmp/bee-supervisor-draft` and
`/tmp/bee-supervisor-review`. Production integration follows the running full
foundation gate; remote desktop is being checked with the host-admission candidate.
Two unrelated thread-ledger failures in the writer's reused staging workspace
remain recorded; those databases were preserved.

Read the final embedded-cache handoff: dependency graph artifacts are included,
strict types remain enforced, changed dependencies use normal checking, and
staged updates reuse writable validation cache. The measured final desktop
median is 335 ms, not the earlier 262 ms candidate. That distribution excludes
shared Hive/UI work; preserve its isolated checkouts and coordinate release pins.
The installed global Bee remains unchanged.

### 2026-09-08 Codex: foundation and peer integration verified

The running full `make check` finished successfully on the host-admission
runtime candidate. `make hive-desktop-check` also passed: two actual runtimes,
destination Bash, resize, F12 and fresh-client reattachment to the retained shell.
Logs: `/tmp/bee-supervisor-foundation-check.log` and
`/tmp/bee-host-desktop-current.log`.

After that gate, integrated the reviewed pure peer library under
`src/hive/supervisor` and its 17 Wippy cases under `tests/lua/hive_supervisor`.
Post-integration strict lint, shared unit tests, pack and source/pack architecture
audits pass. The full desktop suite predates this unused library addition;
no supervisor process wiring changed. Next is the supervised hello and open
telemetry dispatcher, with two-runtime rejection/replacement checks before
public enrollment and the workspace selector. Cache release pins remain untouched.

### 2026-09-08 Claude: step 3 units 1 and 2 landed (obligations, claims)

`bee.threads.service:authority` creates one obligation per recipient on
every message commit, bounds obligations at 2048 per thread, reserves one
record per open request and per live claim, and settles a correlated reply
(`request.answered`, plus the exact live claim by the same actor as
delivered). New namespace `bee.threads.delivery` with contract `delivery`
(`claim`, `dispatch`, `ack`, `release`, `expire`, `reconcile`); claims are
batches per recipient, self-service only, with the owner incarnation and a
five-minute lifetime; release only before dispatch intent; expiry to
uncertain; reconciliation as an owner or lifecycle decision recorded as a
mark. Host policy `bee:thread_delivery_client_policy`. Proven 167/167 in a
fixture that omits `src/hive/supervisor` and `tests/lua/hive_supervisor`,
which are Astra's in-progress files and currently fail to parse
(`bee.hive.supervisor:main:21`); `make test` on the shared tree is blocked
until that is fixed. Requirement from the user for step 9: a `default` agent
binding resolved by the host's driver catalog so an application can call "an
agent" without naming a harness, and applications that ask for no window
stay off Start.

### 2026-09-08 Claude: step 3 done (delivery, subscriptions, waits, recap)

Units 3 to 5 landed after units 1 and 2: subscriptions with one outstanding
page (`subscribe`, `page`, `ack_page`, `unsubscribe`, `resume`), `wait` with
the `bee.threads.delivery:waiter` service and post-commit notifications from
the method boundary, and `bee.threads.projection` with the recap checkpoint
(`recap_read`, `recap_update`, `recap_rebuild`). Contracts `delivery` and
`projection` with local bindings; host client policies added. Proofs:
`make test` 215/215, module isolation with all namespaces, pack and
architecture at 224 entries, journal and Test Status. Details and
deviations in `docs/THREAD_DELIVERY.md` implementation notes; module
overview in `src/threads/README.md`. Next in my lane: step 5 needs the
cross-node send path (Astra's transport); until then, the Hive supervisor
entry blocks whenever Astra's files are ready, and step 7 driver kit.

### 2026-09-08 Codex: first running Hive supervisor route proven

Wolfden seq 60 resolves the earlier supervisor parse blocker. The shared strict
lint and all 215 Wippy tests passed in `/tmp/bee-hive-supervisor-shared-final.log`.
`make hive-supervisor-check` passed Go race/vet and two real native runtimes in
`/tmp/bee-hive-supervisor-native-final.log`: node-qualified EVENTUAL discovery
with no supplied peer PID, telemetry in both directions, wrong-resource refusal,
sibling denial, fresh-PID restart and graceful shutdown. Both nodes use one
frozen source snapshot. The candidate remains `.wippy/bin/bee-wippy-host`.

Implemented under `src/hive/supervisor`: `admission`, `dispatch`, function adapter
`execute`, and process `main`, alongside the peer library. The internal process
accepts `{configured_nodes = {...}}` from trusted boot on the protected host;
fixture-only grants select naming/catalog/telemetry authority. Limits: 64 routes,
eight per caller/peer, eight executing workers. Timeouts retain worker capacity
until completion. Pending identical retries reuse their route; changed input
conflicts. No auto-start service or public CLI enrollment is enabled. Initial
execution permits only the three reviewed open telemetry operations. Policy,
approval, thread remote operations and durable effect dedupe remain unimplemented.

The next shared pack attempt hit three errors in the concurrently added
`bee.driver:profile`; root left that lane untouched. Earlier shared thread filter
failures are resolved by Claude's step 3 completion. Current owned slice and
remaining activation gates are documented in `docs/HIVE_SUPERVISOR.md`.

User clarified multiple independent clients switching browsing targets and
retaining views from different nodes; optional virtual displays likewise mix
origins. One app can have many viewers without duplicating execution. Native
controller/observer mounts already supply the transport primitive, but Bee's
broker still admits only controllers. `docs/WORKSPACE_ATTACHMENTS.md` records
the minimal ownership split and observer/virtual-display acceptance requirements;
these features are not claimed implemented.

Supervisor checkpoint follow-up: the final shared lint/215 tests and frozen-source
native two-node gate pass. `make pack` now succeeds after the concurrent driver
type edits; the architecture audit currently refuses `bee.driver.kit:definition`
because the driver namespace inventory has not yet been added to its allowlist.
Log: `/tmp/bee-hive-supervisor-pack-final.log`. Root left driver ownership intact.

### 2026-09-08 Claude: step 7 done (driver contract, kit, Claude and Codex)

`bee.driver` (binding schema types, `meta.driver` profile decoder with exact
shapes and conservative defaults, the `driver` contract with prepare,
dispatch, normalize), `bee.driver.kit` (JSONL framing with fragment
carry-over and a 1 MiB bound, POSIX quoting, observation builders that split
long text), `bee.driver.transport:stream_json`, and `bee.driver.claude` and
`bee.driver.codex` (protocol normalizers, declarative launch specs, contract
bindings). Fixtures captured today from the real CLIs under
`tests/fixtures/drivers/claude/stream-json-2` (plain with deltas, tool, tool
failure, permission denied, api error) and `tests/fixtures/drivers/codex/exec-json-1`
(plain, tool with transient reconnect errors, tool failure), sanitized, with
manifests. Proven 230/230: every observation decodes, answers come only
from the terminal envelope, a truncated stream is uncertain, denials and
api errors are evidence, launch specs never enable bypass flags. Runtime
fact: registry `meta` drops list values, so profile declarations live in a
`registry.entry` data payload (`bee.driver.<harness>:profiles`) referenced
from the binding's `meta.profiles_ref`; any descriptor with lists must do the
same. Test fixtures reach tests through a `fs.directory` entry
(`bee.driver:fixtures`) staged by `tests/workspace.py`.

### 2026-09-08 Codex: client node validation and final supervisor checkpoint

The minimal `bee.hive:client` lookup check now requires the returned supervisor's
native node to match the caller's node, in addition to the dedicated host check.
The isolated native two-node proof passes at
`/tmp/bee-hive-supervisor-isolated-final2.log`: discovery, bidirectional telemetry,
resource refusal, sibling denial, deliberately installed foreign-PID local alias
refusal, recovery and supervisor restart. The fixture freezes Hive, its actual
pure canonical encoder and a minimal host; it does not load driver/application
or thread database components. Earlier full-source two-node acceptance also passed.

Correction to the earlier discovery inference: advertising an EVENTUAL alias did
not make the client resolve a foreign PID in this setup. Those failed probe logs
are retained. The final negative case uses explicit fixture-only permission to
install a foreign PID under the local alias, and proves the client rejects the
returned node; it does not claim a distributed-name precedence exploit.

Latest shared lint, all 230 Wippy tests, pack and source/pack architecture pass
(250 entries) in `/tmp/bee-hive-supervisor-integrated-final2.log`. A full
`make check` is running in `/tmp/bee-hive-supervisor-full-check.log`. Preserve its
live session rather than starting another run. Installed Bee, native manifest,
release pins and the isolated cache build remain unchanged. Public supervisor
activation still needs protected boot/scope integration and enrollment; clients
still need multi-owner layouts and bounded observer admission.
Full foundation check execution handle: `36849` (Codex session).
The full check `36849` subsequently ended (exit 2) at the newly added concurrent
`bee.harness.catalog:catalog` namespace, absent from the current architecture
allowlist. It is **not live**. Complete a stable-source full gate after that
owner updates its inventory; the isolated supervisor proof remains green.

### 2026-09-08 Claude: harness catalog and threads capabilities

`bee.harness.catalog` (`classify` pure, `catalog` registry IO) reads one
pinned generation of `harness.driver` bindings, resolves `meta.profiles_ref`
to the `harness.profile` declaration, validates `data.driver`, the
association, the driver contract with three bound functions and protocol
support, measures entry and declaration digests labeled `scope: entry`, and
marks ambiguous `driver_id`s. Activation comes from `bee:harness_activation`
(`data.bindings`), separate from compatibility and from admission. Fixtures
`bee.harness.catalog:{fake_binding,fake_profiles,orphan_binding}` carry
`meta.test_support: true`; `tests/workspace.py` excludes that flag from
packs. The catalog suite proves replacement and removal move the generation
without changing a snapshot already taken.

`bee.threads:capabilities` (library `capabilities_report`) reports schema
revisions, carried migrations, bound contracts checked against the registry
definitions, enforced limits and the interim delivery limits (self-service
only, no delegated or cross-thread replies, no cross-node send, no telemetry
subscribe, one outstanding page, caller may shorten but not extend the wait
budget). Waiter bounds moved to `bee.threads.delivery:waits`.

`registry.find` ignores keys without a `.` or `meta.` prefix; `bee.hive:catalog`
and the harness catalog now filter with `[".kind"]` and `["meta.type"]`.
Architecture allowlist now includes `bee.harness` and `bee.harness.catalog`
(Astra's full check `36849` stopped on that gap; a fresh full gate is due).
Proof: `make test` 241, `tests/architecture.py` 255 entries, `make pack`.

## Supervisor host policy continuation (Codex, seq 67)

Ordinary host/broker/desktop policies restrict host selection to `bee:workers`;
core deny covers supervisor entries and host. Eight scoped Wippy regression
cases are integrated under `tests/lua/host_policy`. No supervisor autostart yet.
The frozen full gate reached the Process Manager smoke check and failed because
`bee:workers` moved below the visible service rows; the test now navigates End.
That screen also showed the thread waiter service repeatedly failing, requiring
thread-owner investigation. Current-tree `make test` stops at strict lint in
`bee.threads:capabilities_test:40` (`expected string[], got Report`). Independent
validation of host-policy tests is running in the existing frozen snapshot;
log `/tmp/bee-host-policy-frozen.log`. Public enrollment/discovery still pending.

Seq 68: frozen Wippy suite passed **246 tests** including host-policy cases.
The broad-grant case now also checks monitored/linked spawn and exec, with
positive controls; rerun log `/tmp/bee-host-policy-frozen-final.log` (session
49583). Corrected UI smoke is running as session 31142. Agy is proving native
service-config startup of the actual supervisor in an isolated draft, session
6704; prompt/report `/tmp/bee-service-bootstrap-{prompt.txt,report.md}`. Startup
scope inheritance is part of that proof; no production autostart is enabled.

Seq 70: extended policy suite **246 passed** and corrected `tui_smoke` passed.
Full frozen `make check` is running as session 63812, log
`/tmp/bee-foundation-supervisor-frozen-final.log`. Bootstrap writer session 6704
is live. Native startup applies process-entry security, but the resolver adds
policies to inherited scope; the service proof must check negative rights too.
Documented this in `docs/HIVE_SUPERVISOR.md`; no production service activation.

Thread-owner action: actual current-source headless boot reproduces waiter
restart failure: `bee.threads.delivery:waiter:11: register waiter: not allowed to
register name: bee.threads.waiter`. Evidence `/tmp/bee-service-state.log` uses
isolated databases (path recorded in `/tmp/bee-service-state.path`). The waiter
process has no explicit startup security configuration. Root has not edited the
thread lane; it needs an exact name-registration/send grant and actual service
boot acceptance. This is separate from the narrowed `process.host` permission.

Seq 72 startup refinement: use `process.service` → `lifecycle.security` for
host-selected actor/policies. The native lifecycle controller forks and seals a
service frame and refuses startup on security resolution failure. This keeps
host grants out of reusable process entries and is applicable to the waiter
fix too. Hive fixture still running as 6704; full foundation gate as 63812.

### 2026-09-08 Claude: meta list note retracted; executor probe; capabilities exposed

Retraction: the runtime does not drop list values from entry `meta`. A
child agent proved it in-process (loader, normalize, store, Lua `registry.get`),
with the pinned binary under `wippy run` and a packed `.wapp`, and with
sqlite history across two boots; the Hive interface tests read
`meta.hive_interface.allow[]` already. `docs/REGISTRY_EXTENSION.md` now states
the meta/data split as a layout rule. Likely origin of the false note: a
`bounds.object` guard rejecting a list-valued field.

Executor probe (scratch, not committed) against the pinned runtime, child
`sh -c 'echo $$; sleep 300 & echo $!; wait'`: children share the runtime's
process group and session; `close()` and `close(true)` kill the `sh` and the
`sleep` grandchild survives, reparented; a child ignoring TERM dies after the
10 s grace, grandchild survives; when the owning Wippy process exits without
`close` the direct child is cleaned up, grandchild survives. The native
executor sets no `SysProcAttr` and signals the direct pid only. Whole-tree
cleanup is impossible through the runtime API today. A runtime branch
`feat/exec-process-group` (option `process_group`, group signalling on
signal/close/owner exit, `proc:pid()`) is in progress for a PR; placement
consumes it and does not emulate it in Bee.

`bee.threads:capabilities` is now a Hive `open` operation with a bounded
output schema; `bee:hive_exposure_policy` and `bee:hive_dispatch_policy`
list it; the telemetry suite checks it appears in `catalog_list`. The harness
catalog reads bindings, declarations, method targets and the activation entry
from one `registry.snapshot()`; `catalog.read(pinned, limit)` marks a
truncated read `complete: false` and `usable` resolves nothing from it. Suite
proves a replacement applied between pinning and reading does not reach the
pinned read. Astra round 10 accepted: native placement next, then the carrier;
default agent = host default with workspace override naming `binding_ref` and
`profile_id`, resolved at admission; headless apps simply export no desktop
descriptor. Proof: `make test` 251, architecture 257 entries source and pack,
thread module, pack.

Native service bootstrap integrated and verified: `make hive-supervisor-check`
now runs direct/restart acceptance and two-runtime service startup. Root added
assertions in the staged actual supervisor to verify its actor, positive naming
and dispatch rights, and negative unrelated-name/function/db/spawn/host/scope
rights. Ordinary probe denial covers actor-name registration, not registry
publication. Strict Lua lint, Go vet and race acceptance pass; log
`/tmp/bee-service-bootstrap-integrated.log` (24.967s total). No production
service activation. Full frozen foundation run remains session 63812.

Next native bridge proof is running in Agy session 82436. Prompt
`/tmp/bee-native-bootstrap-bridge-prompt.txt`; eventual report
`/tmp/bee-native-bootstrap-bridge-report.md`. It must connect protected launch
configuration to supervisor activation after registry/host readiness using
native lifecycle APIs, without moving trust into registry overlays or adding a
second router. Full frozen check session 63812 reached navigation after passing
Terminal source/pack and Classic checks. No public activation yet.

Seq 76: headless acceptance now parses structured service failure events after
joining its log reader. Workspace readiness and exit 0 cannot hide a failed
background service. Current source fails this strengthened gate with the exact
waiter name-registration denial; `/tmp/bee-headless-service-health-final.log`.
Thread production code remains with its owner. Frozen full check 63812 predates
this assertion; its result cannot establish current service health by itself.

Seq 77: invitation endpoint helper is running in Agy session 61011, report
`/tmp/bee-endpoint-candidates-report.md`; pure bounded candidates from actual
listener addresses, LAN/IPv6/overlay aware, no probing or port allocation.
Native bridge session 82436 continues. Runtime component Start precedes entry
loading, so it cannot assume Lua factories/policies are already ready.

Full frozen foundation check 63812 **exited 0**, log
`/tmp/bee-foundation-supervisor-frozen-final.log`, including final Test Status
source/pack. This verifies the earlier snapshot, not current complete health:
the new headless service-health assertion still fails the waiter permission.
The supervisor service-bootstrap addition passed separately (seq 74).

Waiter candidate fix verified in isolated source/pack headless boot:
`/tmp/bee-waiter-bootstrap-review.patch`, log
`/tmp/bee-waiter-bootstrap-review.log`; shared thread production untouched.

Endpoint helper integrated under `native/hive/endpoints`; race tests and vet
pass after rejecting unknown modes and refusing result overflow. Public caller
integration and remaining API review pending. Native bridge report is NOT an
activation proof: its phase test manually marks registry ready and never starts
the actual supervisor. Do not adopt the proposed transaction bypass based on
that test. Actual protected dynamic activation remains unresolved.

Endpoint review additionally validates zones before IPv4 unmapping and rejects
link-local/broadcast overrides consistently; race tests and vet pass. Native
bridge followup is running as session 27490, prompt/report
`/tmp/bee-native-bootstrap-real-proof-{prompt.txt,report.md}`. It must prove
actual boot/activation or identify the exact gap; manual readiness and empty
service Stop tests are explicitly insufficient. Shared runtime untouched.

Endpoint inventory now filters scoped interfaces instead of refusing the whole
machine; explicit scoped listener/override inputs still fail. A regression
preserves `100.70.10.28:32123` beside `fe80::1%eth0`. Race tests and vet pass.
README is concise and labels public enrollment integration as unfinished.

Waiter startup fix is now integrated in production and the standalone module
host (seq 83): exact registration name plus send, assigned through lifecycle
security. Initial current check encountered new placement DB default directory
missing in the headless fixture; fixture now creates its local `.wippy` before
boot. Rerun session 36908, `/tmp/bee-waiter-integrated-final.log`. No placement
or thread protocol/storage behavior changed.

Current strict unit suite passed **259 tests** (session 6315), including the
new waiter scope regression: own name/replies allowed, foreign registration,
host/spawn/db/scope authority denied. Log `/tmp/bee-waiter-policy-unit.log`.
Native actual bootstrap proof 27490 remains live; no completion claim.

Native reload audit: process-service Manager.Update emits ServiceUpdate, but the
supervisor command switch has no matching update case; its own ServiceUpdate is
an outgoing state notification. Existing manager test checks emission only.
Do not claim live input/policy replacement from that event. Real reload/rollback
proof remains necessary; documented in HIVE_BOOTSTRAP.md. Runtime untouched.

### 2026-09-09 Claude: placement contract, native placement, persist ledger

`bee.persist` (`ledger`, `database`) is the one checked migration ledger:
threads now opens through it with its own table and label, the threads
suites and `tests/thread_storage.py` unchanged (exact ids, names, checksums
and failure texts). `bee.storage:store` keeps its workspace ledger for a
separate unit.

`bee.placement`: values (`LaunchRequest` with owner incarnation, exact
binding and profile digests, grants by `grant_ref`, nonsecret environment
and host references, optional `session_ref`, `required_cleanup`), exact
decoding with canonical digest, execution and cleanup state machines,
contract `placement` (prepare, start, status, stop, reconcile, cleanup,
evidence, attach). `bee.placement.native`: receipts in an owned SQLite
store, `prepare` records intent after admitted-root and measured-capability
checks and fails closed with `UNSUPPORTED_CAPABILITY` before anything is
materialized, `start` spawns the runner and waits for its acknowledgment,
the runner creates the home under a derived key, resolves environment and
working directory, starts the child (own process group when the runtime
measures `process_group`), records pid, pgid, start ticks and boot id,
pumps bounded acknowledged output, accepts deduplicated input, signals with
grace escalation and records the observed exit. `stop`, `reconcile` and
`cleanup` prove presence or absence from identity and keep uncertainty
otherwise. The receipts database joins the workspace storage boundary.

Runtime facts found: `proc:wait()` invalidates the handle when called (a
runner cannot wait and keep writing or signalling), so the runner waits
only after both streams end, or through `proc:done()` where a runtime
offers it (runtime PR for `done()` in progress); `fs.directory` needs
`auto_init`; the typed dialect drops a constructor field written as
`(a or b) :: T` (go-lua PR 43) and mistypes a field mutated through a path
(go-lua PR 42); runtime PR 694 adds `process_group`, group signalling and
`proc:pid()`.

Proof: pinned runtime `make test` 259, architecture 302 entries source and
pack (the count includes entries other lanes added the same hour), thread
module, thread storage, pack. Against the PR 694 binary the
placement suites pass 9 of 9 in 1.3 s including the grandchild removed with
the group and absence proven from identity after runner loss; on the
pinned runtime the same suites pass 7 of 7 with the group cases absent and
`process_group` launches refused at `prepare`.

Root actual native listener proof passes: `/tmp/bee-root-service-bridge` loads
real Bee Hive entries through StandardComponents and registry.LoadState. A
native listener supplies process-service input/security in memory; the actual
supervisor registers on its protected host. Race test passed, bounded shutdown
passed; `/tmp/bee-root-service-bridge.log`. This is local startup only, with
production hardening/reload/disabled-mode still required. Do not integrate its
Update stub (delegates unsupported Manager.Update). Agy job 27490 exited 1 with
response timeout and no report; root proof is independent.

Root actual native activation proof now covers enabled, disabled and foreign
entry cases. Enabled starts actual supervisor; disabled has no supervisor name,
service or cluster trust handle; foreign ID fails admission. Race pass:
`/tmp/bee-root-service-bridge-bounds.log`. Update explicitly refused pending a
verified replacement path. Current-Hive-source rerun is session 47603 (the
seq 91 journal body contains an uncertain session reference; 47603 is correct),
log `/tmp/bee-root-service-bridge-current.log`.

Reusable native Hive activation component implementation is running in Agy
session 14485, starting from root's passing actual boot proof. Draft/report
`/tmp/bee-native-service-component-{draft,report.md}`; prompt
`/tmp/bee-native-service-component-prompt.txt`. Exact activation ID, strict empty
entry data, immutable host config, real lifecycle ownership and rollback/reload
acceptance required. No production native manifest or activation wiring yet.

Root continuation verified session 14485 remains live; no draft/report yet.
Attachment source still retains one controller recipient/mount per application;
runtime mounts support separate observation rights. Updated
`WORKSPACE_ATTACHMENTS.md` with input endpoint versus authenticated principal,
and `HIVE_BOOTSTRAP.md` with the user's governed-edit requirement: protect the
supervisor/policy dependency closure as well as activation, and never let a
candidate replace its own admission enforcement. These remain design constraints,
not implemented governance or public observer support. Scoped diff check passed.

Root review of the first native component draft reproduced an enabled-start
deadlock: listener `verifyRequiredResources` calls `registry.GetEntry` while
`LoadState` holds the writer lock. Frozen reproduction and timeout stack:
`/tmp/bee-native-service-component-review`,
`/tmp/bee-native-service-component-root-review.log`. Disabled/foreign-ID cases
pass under race in `...-root-negative.log`. Agy 14485 is still running and has
revised lookup into service Start; that revision remains unverified. No component
has been integrated. Journal seq 95 records this evidence. The user's registry
overlay terminology and editable registry/Hub app clarification are now explicit
in `HIVE_BOOTSTRAP.md`; protection follows authority, not storage location.

Revised draft moves lookup into service Start. Root frozen review2 now passes
actual enabled/disabled/foreign boot under race (3.643s), and a real registry
update replaces the supervisor with a fresh PID (2.539s):
`/tmp/bee-native-service-component-root-review2.log` and
`/tmp/bee-native-service-component-root-replacement.log`. Full review remains
open; notes `/tmp/bee-native-service-component-root-review-notes.md` cover policy
defaults, bounds, dependencies and test assertions. Journal seq 96. No production
integration. Agy 14485 remains live; root default-policy probe is session 90526.

Latest: session 14485 exited 1 with response timeout and no report. Root default
configuration probe 90526 failed: enabled constructor accepts incomplete policies
but actual supervisor never registers (`...-root-default.log`, 5.179s). Focused
Agy hardening now runs as session 64758 from the same isolated draft, using
`/tmp/bee-native-service-component-hardening-prompt.txt`; log
`/tmp/bee-native-service-component-hardening-agy.log`, expected report
`/tmp/bee-native-service-component-hardening-report.md`. Journal seq 97. This is
continuation after confirmed exit, not a restart on an observation timeout.

Root froze the first run's final suite at
`/tmp/bee-native-service-component-suite-review`: race pass 9.224s, vet pass,
and an added exact staged strict-Lua lint probe passes 1.134s. Logs
`/tmp/bee-native-service-component-root-suite-race.log` and `...-root-lint.log`.
The missing-resource test still ignores the load result and checks absent name
after 200ms, so these passes do not settle the hardening review. Journal seq 99.

Independent Agy session 21286 extracts identity's filesystem/locking mechanics
into an internal private-file helper with identity as its first consumer:
`/tmp/bee-privatefile-extraction-{prompt.txt,agy.log,draft,report.md}`. Isolated
work only, unchanged identity representation/lock, no new config schema or SQL.
This prepares protected machine configuration while component hardening 64758
continues. Neither draft is integrated.

Root strengthened frozen tests beyond the first suite: rollback observes actual
supervisor remove/register bus events before rejection, with original PID
retained (race 2.082s, `...-root-rollback-evidence.log`). Nonempty two-node input
and caller-slice mutation are now checked exactly in staged strict Lua. That
requires EVENTUAL naming: cluster-disabled fixture correctly failed after the
input assertions. An explicitly enabled native client-role mesh on loopback,
automatic ports and ephemeral keys passes (race 3.250s,
`...-root-input-mesh.log`). This proves native input/naming in one runtime,
not public enrollment or remote workspace selection. These root additions live
in `/tmp/bee-native-service-component-suite-review` for integration review.

Latest component review: removing activation metadata exposed a native host
startup race. `Lifecycle.Requires = []string{HostID}` fixes it; five race runs
pass 5.103s (`...-root-host-order-fixed.log`). Full fixed hardening suite has one
remaining test mismatch: wrong-kind host leaves the activation unstarted behind
its required dependency (`unknown`), while the test expects `failed` from Start.
Logs `...-root-hardening-final.log`; frozen source
`/tmp/bee-native-service-component-hardening-review`. Do not claim full green.
Agy 64758 returned partial output at its 12-minute limit (exit 0, no report).
Privatefile 21286 completed with `/tmp/bee-privatefile-extraction-report.md`;
review its Tx API and actual guarantees before integration. No new production
package or activation has been installed.

Root integrated `native/hive/service` and its README. Enabled configuration now
requires explicit native host policy selection; fixture-based defaults were
removed. No production activation entry or native manifest selection. The
Makefile `hive-service-check` boots repository source, with separate fixture,
input, admission and lifecycle suites; no historical `/tmp` fixture dependency.
Final organized race+vet gate passes 23.332s in
`/tmp/bee-native-service-organized.log`. Full native `make check` also passes in
`/tmp/bee-native-service-module-check.log`; go.mod/go.sum were not edited.
`HIVE_BOOTSTRAP.md` now describes this integrated but unselected component.

Privatefile is not integrated: root proved raw `Tx.Write` replaces an insecure
0644 document (`/tmp/bee-privatefile-root-write.log`). Simplification runs in
Agy session 55434, using `/tmp/bee-privatefile-simplify-prompt.txt`; log/report
`/tmp/bee-privatefile-simplify-{agy.log,report.md}`. Remove the exposed transaction
and close/raw-write surface, keep bounded Read and atomic ReadModifyWrite with
identity as the actual consumer. Continue toward protected machine configuration;
public enrollment, discovery and remote workspace selection remain unfinished.

### 2026-09-09 Claude: placement amendments from Astra round 12

Measured `exit_observation: independent | eof_gated` (a handle with
`done()` is independent); `LaunchRequest.required_exit_observation`
defaults to `independent` and `prepare` refuses it on an `eof_gated`
runtime, so managed harness launches stay closed until `done()` is pinned
while bounded fixture commands declare `eof_gated`. `exit_source: runner |
reconcile` is recorded; `cleanup` removes a home only when the required
scope is proven gone: direct process by observed exit or proven leader
absence, group by no member answering `kill -0 -- -pgid`, contained tree
never. Admitted roots carry the widest access the host allows and
`prepare` checks caller, root, subpath and access; `grant_ref` is recorded
as correlation data only; `capabilities` reports
`resource_authority: host_configured`, `delegated_resource_grants: false`,
`credential_broker: false`. Input writes left unacknowledged when a runner
is lost are uncertain and never replayed by the runner. Proof: pinned
`make test` green with placement 7 of 7; PR 694 binary placement 9 of 9
including cleanup after group absence and after identity-proven leader
absence.

### 2026-09-09 Claude: carrier contract in threads, runtime done() PR

`docs/CARRIER.md` fixes the replay and lifecycle rules from Astra round 13.
In threads: record family `attempt.prepared` and lifecycle `prepare_attempt`
(the attempt exists with its pinned plan before any placement effect;
`start_attempt` moves `prepared` to `running`; a prepared attempt may end
by receipt without starting; turns open on prepared attempts); migration 6
`carrier` rebuilds records and attempts and adds `bee_thread_carriers`;
slice `bee.threads.carrier` with contract `bee.threads:carrier` (`claim`
fenced epoch, `commit` records plus checkpoint in one transaction under
epoch and revision with event-key deduplication, `checkpoint` read) and
action `bee.threads.carrier`; `authority.commit_observation` is the shared
dedupe-and-commit used by `record` and `commit`. Provenance travels in the
observation's `raw_ref` as `bee.carrier.provenance@1:...`; control records
are `bee.*` extension observations with source `bee`, submittable only
through `commit`.

Runtime PR 695 (`feat/exec-done-channel`): `proc:done()` one-shot channel
with `{code, signal, error}`, non-consuming; `wait()` after `done()`
returns the recorded code; one reap across `done`, `wait`, `close`; binary
`/home/wolfy-j/kickside/runtime-exec-done/bin/wippy`. Placement measures
`exit_observation: independent` on it.

Proof: `make test` 261, `tests/thread_storage.py`, thread module (staging
now includes `threads/carrier`), pack, architecture 312 entries.

### 2026-09-09 Claude: carrier phase 1, round 14 amendments, combined runtime build

Astra round 14 applied in threads: typed `CarrierProvenance` on `commit`
records, event keys derived by the authority and persisted in
`bee_thread_carrier_events` with the record and checkpoint; `raw_ref`
refused on carrier records; control records limited to
`bee.carrier.write@1` and `bee.placement.attempt@1`; `carrier_epoch`
fences `request_turn`, `end_turn` and `receipt`; placement `attach` takes
the caller's generation and refuses a stale one; framing bound is a
parameter and the checkpoint carry bound is 16 KiB with an `event_cursor`
for partial commits; `docs/CARRIER.md` carries the launch-policy rules and
the test-only fault entry rule.

`bee.harness.carrier`: `provenance`, `checkpoint`, `settle` (pure),
`policy` (host launch policy with executable bindings, `eof_gated` only
under `fixture: true`), `machine` (plan, open in the agreed order, resume
under a new epoch from the stored checkpoint, output to checkpointed
commits with acknowledgment after commit, exit then bounded drain then
settlement, close with placement observations and cleanup, input writes
under control records), `process` (production, no hooks). Test-only
`bee.harness.catalog:carrier_faulted` wraps the same run with a barrier.
Fixture: `tests/fixtures/harness/bin/claude` replays captured
`stream-json-2` files; bound through the suite's fixture launch policy, not
`PATH`; `tests/unit.py` passes its location as `BEE_FIXTURE_BIN`.

Proof (pinned): `make test` 267; carrier suite: agreed record order with
`attempt.started` before the first stream observation, settlement
`succeeded`/`pong` from the terminal envelope, `failed` on the api-error
capture, `uncertain` on a cut stream, recovery after crashes at
`placement_started`, `committed` and `turn_ended` with one
`attempt.started`, one `turn.end`, one `receipt`, one ended turn signal,
epoch 2 after resume and the old epoch refused. Thread storage, thread
module, pack, architecture 320 entries. Combined runtime build (PR 696,
integration of 694 and 695, which surfaced and fixed two executor defects:
group signalling after the leader is reaped, and pipes closed by `Wait`)
runs harness and placement 25 of 25.

Not yet driven end to end: crash between two events of one chunk and after
a partial frame (need a fixture larger than one chunk), the write path
(`BEE_FIXTURE_READ` exists in the fixture, the suite does not use it yet),
and an old carrier writing after replacement (proven at the contract level
only). Managed-harness enablement stays gated on the pinned combined
runtime and those proofs.

### 2026-09-09 Codex: private file persistence integrated; launch activation boundary

Wolfden seq 105 records the protected-file extraction now in
`native/internal/privatefile` and the existing machine identity consumer.
Identity format and `.identity.lock` are unchanged. The helper exposes bounded
read and locked read-modify-write, with no raw transaction write API. Invalid
existing permissions and empty/corrupt identity documents are refused without
replacement. Same-account native processes remain outside this protection.

Verified prior integration logs: `/tmp/bee-privatefile-integrated-check.log`
records successful `make -C native check` (Linux race tests and vet), and
`/tmp/bee-privatefile-integrated-windows.log` records successful
`make -C native privatefile-windows-check` (compilation and vet only). Windows
execution and directory crash durability remain unverified.

`docs/HIVE_LAUNCH_STATE.md` now separates this implemented primitive from the
absent machine configuration schema/store and public launch/enrollment commands.
It also records the commit/activation recovery requirement: save enrollment,
reconcile both native transport trust and Lua supervisor admission, and observe
connection readiness separately. Failed activation retains the committed decision
for retry; a stale completion cannot override revocation. The current Lua
supervisor still takes an immutable startup allowlist. These are requirements
for the next implementation, not a callable live-update API.

Root retains native launch/configuration, supervisor transport/admission and
remote Terminal integration. Ordinary `bee` to the remote workspace selector
and retained Terminal remains the required public acceptance gate.

### 2026-09-09 Claude: all carrier recovery proofs closed

Astra round 15 details applied: output is honoured only from the runner
address the placement's own reply names, stale generations are dropped
without acknowledgment, and only sequences the durable checkpoint covers
are re-acknowledged; the runner answers `write_status` and announces
itself on attach; pending writes live in the checkpoint and a resuming
carrier records `accepted`, dispatches an `unknown` write for the first
time, or marks `uncertain` when no runner answers; settlement waits for
pending writes until the drain ends; the receipt follows the turn end and
cleanup evidence may follow the receipt; takeover completes at the
replacement's `claim` commit (documented in `docs/CARRIER.md`);
`bee.harness.carrier:capabilities` reports the 16 KiB frame bound.

Carrier suite now drives every crash point: a frame split across chunks
(`BEE_FIXTURE_SPLIT`) with a crash after the commit; a crash between
events of one chunk (`partial_commit` under a batch of 2); a frame beyond
the bound settling `uncertain` with one `framing` notice; a write path with
both boundaries (`write_intended` before dispatch, `write_dispatched`
before the acknowledgment) verified by the child echoing exactly one read;
a live old carrier fenced with `CONFLICT` when it writes after the
replacement's claim while both run (`BEE_FIXTURE_PACE`); and the earlier
placement-start, commit and turn-end crashes. Proof: pinned `make test`
271; thread storage; thread module; pack; architecture 321 entries;
combined runtime build (PR 696) harness and placement 29 of 29.

### 2026-09-09 Codex: machine configuration store and second-launch reproduction

Integrated `native/hive/config` after reviewing Agy's isolated draft. Version 1
stores a revision, optional nonsecret enrollment reference and remembered
workspace/project/runtime-state locations. Reads create nothing; updates use the
protected file lock and reject stale revisions, corrupt documents and invalid
metadata changes. No public launcher consumes it yet; it stores no credentials,
permissions, PIDs or live-state flags.

Root regressions first failed on the draft: two workspace IDs sharing a runtime
state directory were incorrectly refused, and invalid UTF-8 was silently
substituted by JSON decoding. Both now pass. The field is explicitly
`RuntimeStateDir`; it does not identify or authorize a workspace database.
Removed error-string matching so callback errors and post-publication sync
uncertainty propagate intact. Root review evidence:
`/tmp/bee-config-root-review.log` (two failures),
`/tmp/bee-config-root-simplified.log` (race/vet pass).

Shared-tree proof: `make -C native check` passes (configuration race 1.638s,
all native packages and vet); `/tmp/bee-config-integrated-check.log`.
`make -C native config-windows-check` compiles Windows tests and runs vet;
`/tmp/bee-config-integrated-windows.log`. No Windows execution claim.

User reproduced ordinary `bee` failing with the same busy application lock from
both `/mnt/c/Users/Wolfy-J` and its parent on Antares. The runtime defaults to
`UserConfigDir/bee`, independent of the project directory. Public owner lookup
and automatic client attachment must happen before attempting that owner's
exclusive state lock. Clients need automatically selected, independently owned
layout/reconnect storage; connecting must not lock the host's runtime state or
compete for another client's writable store. `docs/HIVE_LAUNCH_STATE.md` records
this required behavior and clearly labels it unimplemented. Do not suggest lock
deletion or a second writer as the fix. Root retains this launch/reuse lane.

### 2026-09-09 Claude: two-stage takeover proven

Astra round 16: claim fences thread authority, the attachment fence
completes the execution channel. Placement `attach` now sends the new
generation to a live runner and returns only after the runner acknowledges
it (`attach.fenced` evidence; `uncertain` on no answer); the runner answers
a refused write with the sender's own generation; the carrier ignores
acknowledgments for writes already settled and records acceptance
deterministically. New case: an old carrier paused after committing a
write's intent (test-only `pause_after` barrier), a replacement claims,
attaches and reconciles (runner answers `unknown`, first dispatch), then
the old carrier dispatches its admitted write: refused by the runner, its
attempt to record the refusal fails with `CONFLICT`, the child echoes
exactly one read, and the thread holds `w9:intended,w9:accepted` once.
`docs/CARRIER.md` and the placement README describe both stages. Proof:
pinned `make test` 272, thread storage, thread module, pack, architecture
321 entries; combined runtime build harness and placement 30 of 30.

### 2026-09-09 Codex: local client lifetime seam verified in source

The physical native `terminal.host` cannot simply be reused for a second
independent terminal: its constructor binds `os.Stdin`, and `OnComplete` calls
`supervisor.TriggerShutdown`. The existing desktop-client fixture instead runs
two `bee.client:main` actors on `bee:workers`, with separate native viewport
grants and client stores. Wippy exposes `tty.Port`/`Binding`, virtual viewports,
physical `Surface` rendering and input-event normalization for the display seam.

`docs/HIVE_LAUNCH_STATE.md` records a local display-connection candidate and its
required separate-OS-process proof. The terminal-facing `bee` process may be
thin while its client actor and layout state remain hosted in the retained
runtime. This avoids demanding a second registry/runtime just to attach. It
must not become an actor router or enable LAN clustering on fresh local launch.
No public attachment command or local socket listener has been implemented by
this source investigation. Automatic host start/reuse, private endpoint
admission and client profile allocation remain required. Preserve actual
host/client permissions and native viewport ownership in that implementation.

### 2026-09-09 Claude: resource authority and granted placement mode

`bee.resources` (owner-local SQLite through `bee.persist`): `associate`
binds a workspace name to a root the host admits with the widest access the
host allows, replacing at the next revision; `grant` binds the
authenticated subject, an audience, the association revision, the root
digest, subpath, access, purpose, an optional attempt scope, an expiry and
the workspace authorization epoch; `revoke`, `revoke_all` (epoch advance),
`list`; `resolve` re-checks all of it for a placement holding
`bee.resources.resolve` and refuses with `REVOKED`, `EXPIRED`, `DENIED`,
`CONFLICT` (replaced association or changed root, re-admission) or
`RESOURCE_NOT_LOCAL`. Actions `bee.resources.manage`, `.grant`, `.resolve`
with host policies; the resolve policy is attached to placement service
entries only. The subpath rule moved into `bee.threads.records:bounds`
so placement and resources share one definition.

Placement: `bee.placement.native:resource_mode` (host-selected
`host_configured | granted`); in granted mode `prepare` resolves every
grant for the owner it admitted with the attempt as scope, the authority's
root and subpath replace the caller's, resolved grants are recorded with
the attempt, `start` re-resolves before spawning the runner
(`grant.refused`), `reconcile` re-resolves a live attempt and stops it
cooperatively when a grant no longer holds (`grant.revoked`, enforcement
pending until the exit is proven); `capabilities` reports the mode,
`delegated_resource_grants` and `revocation_enforcement: stop_on_reconcile`.
The receipts store of resources joins the workspace storage boundary.

Proof: resources suite (managers only, host ceiling, replacement revision,
subject from authentication, wrong subject/audience/attempt refused,
expiry, revoke, epoch advance, replaced association, changed root entry,
foreign node); placement granted cases (caller root replaced, downgrade
with a non-grant ref refused, a grant scoped to another attempt refused,
expiry between prepare and start refused at start, revocation during use
stops the child on the group-capable runtime). Pinned `make test` 277,
thread storage, thread module, pack, architecture 346 entries; combined
runtime build harness, placement and resources 35 of 35. Runtime PRs 691,
694, 695, 696 and go-lua PRs 42, 43 now carry review requests to skhaz.

### 2026-09-09 Codex: isolated local display prototype under revision

Agy's first `client/display` draft is isolated in
`/tmp/bee-local-display-2aXi5X`; none of it is in shared `native/` or the global
executable. It accepts a trusted caller's already-admitted native local viewport
and connection; the wire cannot select an actor, application, handle or policy.
Its native TTY tests are a mechanism proof, not two actual Bee clients.

Root review in `/tmp/bee-display-root-review` reproduced failures recorded in
`/tmp/bee-display-root-review.log`: a closed update channel spins, invalid input
shapes are acknowledged although Bee drops them, and canceled input remains
blocked in network Write. Additional source concerns include unbounded pending
requests, sequence/write-order separation, blocking Close, malformed handshake
panic and unbounded recursive JSON structure. Initial Agy test success therefore
does not justify integration.

Agy is revising under live exec session `23987`, using
`/tmp/bee-local-display-review-prompt.txt`; output is
`/tmp/bee-local-display-revised-agy.log`, with final report expected at
`/tmp/bee-local-display-revised-report.md`. First session `94488` completed.
Revalidate the active handle before waiting; do not restart it because output
is temporarily quiet. Required simplification is one serialized cancellable
in-flight request, immediate connection closure for uncertain delivery and
bounded parsing. Preserve native empty/partial snapshots, exact input shapes,
producer lifetime and correct licenses. Root must review before integration.
Automatic public client attachment, endpoint admission and profile allocation
remain unfinished; the user's second-launch lock-busy case is still the gate.

### 2026-09-09 Claude: credential broker, projections, bounded enforcement

`bee.credentials` (owner-local SQLite through `bee.persist`): `define`
(manager) names a credential from a source the host admits in
`bee:credential_sources` (an `env.variable` entry, workspace or `*`,
provider, projection kinds); the digest covers configuration and source
identity, never bytes; redefinition moves to the next revision and
existing projections stop resolving. `issue_projection` (subject from
authentication, action `bee.credentials.issue`) binds audience, attempt,
profile id, profile, binding and launch-policy digests, the provider's
fixed destination (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`), the materializer
identity, an idempotency key, expiry and the workspace authorization
epoch; the same key replays. `check` re-checks without bytes;
`materialize` (action `bee.credentials.materialize`, placement service and
runner entries only) re-checks and returns the value once in a reply
nothing persists, recording a new generation; the source is read at each
materialization. `revoke`, `revoke_all`, `list`, `capabilities`
(`file_projections: false`, `provider_revocation: false`, `refresh: false`,
`write_back: false`, `rotation: next_materialization`).

Placement: `LaunchRequest.projections`; `prepare` checks each projection
for the admitted owner with the attempt as scope; the runner materializes
right before the child starts and places the value in the child's
environment, recording only `credential.materialized` or
`credential.refused` with the projection id; `start` and `reconcile`
re-check projections with grants. `sweeper_service` (actor
`bee.placement.sweeper`) reconciles every live attempt every 30 s through
the owner-independent `reconcile_attempt` and `stop_attempt`, so
enforcement is bounded; `capabilities` reports `revocation_enforcement
{mode: stop_on_reconcile, interval_ms: 30000}` and
`credential_projections: [environment]`. The credentials store joins the
workspace storage boundary. The carrier passes projection ids from its
request into the placement request.

Proof with sentinel secrets: broker suite (host allowlist by workspace,
provider and kind; managers only; digests carry no bytes; subject from
authentication; only the materializer reads; wrong subject, audience and
attempt refused; two generations; replay by key and conflict; expiry,
revoke, epoch advance, redefinition; replies and lists never carry the
sentinel); placement suite (value reaches the child, proven by length;
neither evidence nor the stored request carries the sentinel; a projection
scoped to another attempt refused; revocation during use enforced by the
sweep on the group-capable runtime). Pinned `make test` 281, thread
storage, thread module, pack, architecture 374 entries; combined runtime
build harness, placement, resources and credentials 39 of 39. Documented
in `docs/BUILD_SEQUENCE.md`, `docs/README.md`, the placement and
credentials READMEs.

### Root checkpoint — display revision review (2026-09-08)

Agy display revision session `23987` completed. Root review and corrections are
isolated in `/tmp/bee-display-revised-root`; no display bridge has been integrated
into `native/`. Requests now preflight encoding before consuming a sequence,
reject already-canceled admission, consume acknowledgments once, and report failed
transport writes as uncertain. Short writes fail; cancellation callbacks are
stopped or joined before ownership is released. Removed the unused compatibility
map. The first root cancellation helper hung on repeated cleanup; the corrected
helper uses `sync.Once`. Current `make check` passes race tests and vet; evidence:
`/tmp/bee-display-revised-root-check.log`. The original malformed-handshake panic
and close hang remain recorded in `/tmp/bee-display-root-handshake.log` and
`/tmp/bee-display-root-close.log`.

Next: complete boundary review, integrate the mechanism, then prove two actual OS
clients using protected local admission. Public lock-busy auto-attachment and
ordinary `bee` to the remote retained Terminal remain incomplete. Machine config
is implemented but still has no public launcher caller. Wolfden checkpoint carries
the same evidence and remaining gates.

### Root milestone — local display mechanism integrated (2026-09-08)

`native/client/display` now contains the reviewed connection mechanism and tests.
`make -C native check` passes; `make -C native display-check
 display-windows-check` passes, with the native TTY test under a dedicated build
tag and temporary test module dependencies. Windows evidence is compile/vet only.
Logs: `/tmp/bee-display-integrated-check.log` and
`/tmp/bee-display-integrated-mechanism.log`. Root also corrected empty paste,
full unsigned sequence decoding and bounded refusal text. No public launcher
caller or automatic lock-busy attachment exists yet.

Next physical-client seam: Wippy's `NewInputReader` requires an actor scheduler
and PID. Prefer adding an event-sink constructor upstream to reuse input parsing,
raw-mode cleanup, mouse coalescing and resize. The sink must enqueue bounded
input promptly: `inputEmitter` holds delivery ownership while invoking it and
`Stop` joins delivery. Awaiting a network acknowledgment inside that callback
would reintroduce an exit hang. This is a proposal; no runtime edit made here.

### 2026-09-09 Claude: credential details from Astra round 18

`bee:credential_sources` entries carry an `audience` (or `*`); `issue_projection`
refuses an audience the host does not admit and every `check` and
`materialize` re-reads the allowlist, so removing a source or audience takes
effect for issued projections. `materialize` records each generation key
once in `bee_credential_generations` with the materializer actor and
refuses a repeated key (`repeat_generation: refused`), so a lost reply is
never repaired by a silent second read; values with NUL, line breaks or
over 8 KiB are refused without being echoed; materializer authentication
is entry-scoped. Placement: broker and authority call failures are
recorded with fixed phrases, executor error text is never recorded,
evidence names `credential.refused`/`credential.revoked` separately from
`grant.*`, `capabilities.revocation_enforcement` reports scheduling delay,
reconcile timeout, per-attempt stop grace and the sweep bound as separate
figures, and the sweeper registers as `bee.placement.sweeper`. Proofs:
audience refusal, removed source refused at materialization, repeated
generation key refused, broken value refused without echo, executor
failure with a projection leaves no sentinel in the reply or evidence,
sweeper registered. Pinned `make test` 282, thread storage, thread module,
pack, architecture 375 entries; combined runtime build 40 of 40. Next:
step 9 admission helpers in the harness lane (launch definitions,
measured resolution, admission obtaining attempt-bound grants and
projections for the authenticated requester, retry-safe start), public
launch wiring stays in Astra's lane, managed launches stay disabled.

### Root in progress — physical client and shared input seam (2026-09-08)

Agy `gemini-3.8-flash-high` is implementing the input-reader seam in isolated
`/tmp/bee-physical-runtime` (exec session `51295`, prompt
`/tmp/bee-physical-input-task.txt`, log `/tmp/bee-physical-input-agy.log`, expected
report `/tmp/bee-physical-input-report.md`). This snapshot preserves the original
runtime worktree. Requested API: a value-event sink constructor sharing the
existing reader, plus completion/error observation and native lifecycle tests.
Recheck the live handle before concluding that work stopped.

Root's dependent Bee draft is `/tmp/bee-physical-client/client/physical`. It uses
the native surface and proposed reader API, with bounded event/byte buffering,
connection cancellation before worker/reader cleanup, and Ctrl+] local detach.
The PTY test stalls host reads after the handshake and checks that local detach
restores the terminal mode. Neither draft is integrated or validated yet; the
input API must land in the isolated copy before compiling the physical test.
The snapshot's module replacement points only to that isolated runtime. No
public build manifest or runtime patch changed in this step.

Physical draft proof update: `/tmp/bee-physical-client-check.log` records a
passing race run (1.018s, session `87503` exit 0). The real PTY test enters raw
mode, stalls server reads after handshake, injects Ctrl+], observes exit within
one second and checks the original terminal mode was restored. This remains an
isolated mechanism test, not two public Bee clients. Agy session `51295` remains
live pending final report. Review its natural EOF cleanup: the current
`readLoop` drops its WaitGroup count before calling `stopWithCause`, so check
concurrent Stop/restart for stale cleanup crossing sessions before integrating.

### 2026-09-09 Claude: launch admission in the harness lane

`bee.harness.launch`: `definitions` decodes `bee.launch_definition`
entries exactly (launch id, title, command names, binding and profile
references, policy reference, default mode, allowed overrides, workdir and
thread policies, credential names, presentation) and digests them;
`admission.resolve` returns a measured plan (definition, binding, profile
and policy digests, catalog generation, mode) with no effects and refuses
overrides the definition does not allow; `admission.admit` runs as the
authenticated requester and, keyed on the request id, settles the thread
by policy, takes the attempt-bound resource grant through
`bee.resources:grant` and the credential projections through
`bee.credentials:issue_projection` in the requester's own authority (no
service actor substitution), and returns the carrier request with durable
identities `action:<request>` and `attempt:<request>`; `admission.start`
spawns the carrier as the requester, resumes when a checkpoint exists and
refuses a settled request. The carrier's open sequence now keys its
thread operations on the attempt and step so a retried start replays
instead of duplicating, and `resume` finishes a placement that was
prepared but never started. `bee:launch_policy_managed` (process group,
independent exit) exists and stays inert; `bee:launch_spawn_policy`
grants only the carrier spawn on the workers host. Public
`launch.resolve`/`launch.start` wiring stays in Astra's lane.

Proof: launch suite against the fixture definition (stable plan digest
that moves with the definition, override refused, unknown definition
refused, admission for the requester with one grant and one projection
bound to the requester and the attempt, replay by request id, thread and
workdir overrides refused when not allowed, another actor refused at the
credential audience, start to settlement `pong`, one action, attempt and
receipt, a settled request refused with `CONFLICT`). Not driven yet: a
start that crashes between placement intent and the checkpoint and is
retried; the replay keys and the resume path cover it by construction
only. Pinned `make test` 285, thread storage, thread module, pack,
architecture 383 entries; combined runtime build harness, placement,
resources and credentials 43 of 43.

### Root checkpoint — input restart fence and candidate (2026-09-08)

Root review copy `/tmp/bee-physical-runtime-root` passes the terminal race suite
plus the retired-session and actual PTY peer-close checks (11.098s,
`/tmp/bee-input-root-final-check.log`) and vet. The regression fails without the
fence in `/tmp/bee-input-unfenced-check.log`: retired EOF cleanup stops a new
session. Physical detach still passes against the corrected snapshot (1.016s,
`/tmp/bee-physical-client-root-check.log`). Unapplied source/tests are saved in
`runtime/research/physical-input.patch`, with status in `PHYSICAL_INPUT.md`.

Agy `51295` is still live. Its copied test draft initially failed compilation;
that file is excluded only from root's snapshot as `input_test.go.agy-draft`.
Review final agent output before importing. New differences include starting
read loops before emitting the initial start event and normalizing EIO to EOF;
the root candidate preserves initial-event ordering and the actual read error.
No public runtime patch selection or physical-client integration yet.

### Root checkpoint — physical candidate now reviewable in repository (2026-09-08)

Agy session `51295` completed exit 0; final report is
`/tmp/bee-physical-input-report.md`. Root retained initial-event ordering and
session fencing, imported applicable final lifecycle tests, and preserved actual
PTY read/cleanup errors. The combined runtime race suite passes (11.122s,
`/tmp/bee-input-combined-final.log`). The refreshed
`runtime/research/physical-input.patch` applies cleanly to the unchanged input
source in `/tmp/bee-hive-runtime` (`git apply --check`, no application performed).

`native/client/physical` now holds the candidate behind `physicalclient`.
`make -C native physical-client-check PHYSICAL_RUNTIME=/tmp/bee-physical-runtime-root`
passes its real PTY stalled-host detach proof and vet
(`/tmp/bee-physical-integrated-check.log`, 1.017s). Extra module dependencies and
runtime replacement stay temporary. Public manifest and launch behavior are
unchanged. Next is owner-side local connection admission and real desktop actors,
then two ordinary OS client processes; the tagged candidate alone is not that
acceptance proof.

### 2026-09-09 Claude: two gates closed, grant idempotency

Launch retry after placement intent and before the first checkpoint is
now driven: a test-only carrier crashes right after placement `prepare`
under an admitted request, then `bee.harness.launch:start` with the same
request id opens again and settles with one action, one prepared and one
started attempt, one turn request and one receipt. The fault it exposed
was real: `bee.resources:grant` created a new grant on every call, so the
replayed `admit_action` carried a different grant reference and the thread
refused it as a different request. `grant` now takes an `idempotency_key`
(unique per subject) with a request digest: the same request replays the
same grant, a different one conflicts; admission keys the workdir grant
on the request id. Sweep progress is proven over three live attempts with
a bound of two: each sweep takes at most the bound, every attempt is
reached within three sweeps, an attempt a sweep settled is not swept
again; terminating the registered sweeper yields a fresh registration
from the process service. Proof: harness, placement and resources 39 of
39 on the pinned runtime; pinned `make test` 287, thread storage, thread
module, pack, architecture 383 entries; combined runtime build harness,
placement, resources and credentials 45 of 45.

### 2026-09-09 Claude: approvals owner, thread ingress, durable outbox

Step 4 is built to Astra's round 19 amendments. Threads gain two record
families, `approval.request` and `approval.transition` (migration 7
`approvals` rebuilds the records kind check), and one narrow ingress,
`bee.threads.approvals:append`: authenticated by the `bee.threads.approval`
action on the thread rather than by membership, one record per call keyed
`approval/<owner_id>` plus the owner's event id through the new generic
`authority.commit_keyed` (replay on identical content, `CONFLICT` on
different content under a used key), no other family and no settlement.
`bee.approvals` owns requests bound to a canonical proposal digest under a
host approver policy (`bee.approvals:approver_policies` names approvers and
the lifetime ceiling; a requester cannot pick approvers or exceed it),
decisions by compare-and-set on the pending revision for that digest
(identical retry replays, anything else `CONFLICT` carrying the committed
outcome), withdrawal by the requester only (a settled request reports what
committed), owner-enforced expiry (a decision on a due request commits the
expiry and refuses; the worker reconciles the rest), consumption of an
approved decision bound to one effect key, a bounded inbox per workspace
with `RESET_REQUIRED` past retention, and a durable outbox whose rows commit
with the change and are delivered by `bee.approvals:worker` through the
ingress under the stable event id `<approval>:<revision>`, acknowledged only
after the ingress reply, leased for redelivery, exhausted after twelve
attempts and returned to the queue by a manager. Two consolidations:
`bee.persist:transaction` now holds the busy-retry write and read used by
threads and approvals, with a `refusal` result that commits its side effects
while failing; `bee.threads.persist:transaction` delegates to it. Proof:
`tests/lua/approvals/service_test.lua` drives two approvers racing to one
decision, expiry, withdrawal after decision, unauthorized readers and
approvers, a changed proposal digest, consumption replay and conflict, the
live worker projecting request and decision exactly once, and over a
separate test store a crash between the thread commit and the outbox
acknowledgement (thread keeps one record, the redelivery acknowledges);
`tests/lua/threads/approvals_test.lua` covers the ingress. Pinned `make
test` 295, thread storage, thread module, pack, architecture 424 entries;
combined runtime approvals, threads, harness, placement, resources and
credentials 104 of 104.

### 2026-09-09 Claude: round 20 owner corrections, permission exchange adapter

Astra's round 20 accepted the owner/outbox split and amended the owner
contract; all amendments are applied. Authority incarnation is established
by a dedicated `bee.approvals:authority` process before any request is
served (`UNAVAILABLE` otherwise); the delivery worker holds only a lease
name and never advances it; `consume` takes the incarnation the consumer
observed and a mismatch is `REVALIDATE` carrying the record, never an
approval or a discard. A thread projection is authorized when the request
is made: the requester must be an active owner or participant, an attempt
proposal names its `action_id` and the thread must have prepared that
attempt under it; the binding is persisted and delivery carries the
attempt context so the thread relinks each record. The ingress derives the
dedupe scope from the calling actor; no payload field selects another
authority's namespace. Consumption belongs to the effect owner holding
`bee.approvals.consume`, recording the consumer. Retention forgets a
request only after lifetime plus the window with every delivery
acknowledged; the dedupe horizon is advertised. The permission exchange is
specified in `docs/APPROVALS.md` and built as the pure module
`bee.harness.permission:adapter`: a `harness.permission_adapter` entry
decoded under `bee.permission-adapter@1` (request fields, allow/deny
response shape, acknowledgment semantics, cancellation behavior, proof
fixture) measured by digest; profiles enable it only with
`permission_exchange: {mode: adapter, adapter_ref, adapter_digest}` and the
catalog marks a missing, untyped or changed adapter incompatible; the
request identity is the observation event key; the proposal binds the
attempt plan digest, not the carrier epoch; idempotency, effect and write
keys are qualified by owner, attempt and request; `prove` accepts only a
capture where the harness keeps waiting and acknowledges; `outcome` sends
nothing after settlement. Both shipped profiles stay `none`; nothing is
wired to the carrier. Proof: approvals suite extended (authority
establishment, incarnation revalidation, attempt binding through the live
worker, foreign thread refused), `tests/lua/harness/permission_test.lua`,
classify adapter pinning, profile decoding. Pinned `make test` 304, thread
storage, thread module, pack, architecture 429 entries; combined runtime
127 of 127 across approvals, threads, harness, driver, placement,
resources and credentials.

### 2026-09-09 Claude: round 21 distinctions, revalidation rule, live acceptance runner

Astra's round 21 accepted the event-key identity and asked for four
distinctions; all are built. Owner: `consume` and the new `revalidate`
compare the effect owner's observed incarnation with the current authority
incarnation, not the one stored with the request; a decision made under an
earlier incarnation returns `REVALIDATE` naming the current one until the
effect owner records its validation under it, and another restart fences
that validation again (proven over the test store across three
establishments). Adapter: `prove` is now `transcript_consistent` and claims
transcript consistency only; acknowledgment is a typed object naming the
observation type and field that echo the correlation (`tool.result` by
`call_id` for the fixture); request fields are dotted paths; `admit_pending`
refuses a second pending request with a reused correlation id. New
`bee.harness.permission:acceptance` decodes the host acceptance record
(`bee.permission-acceptance@1`: binding, profile, adapter and fixture
digests, proof revision) and names the first changed measurement; the
catalog reports per-profile permission eligibility apart from
compatibility, and a `proof_fixture` name authorizes nothing. Live
acceptance: the fixture gained a bash permission mode (stream on descriptor
3, response read from stdin with a timeout; allow continues, deny reports
and ends, uncorrelated lines are ignored, silence times out) with the
synthetic `permission.jsonl` sample; `tests/lua/harness/acceptance_test.lua`
drives it over exec, observes the request before writing, records the
input-write boundary, verifies the correlated `tool.result` after it, and
exercises allow, deny, wrong correlation and no response, then measures the
fixture for an acceptance record. Both shipped profiles stay `none`;
nothing touches the carrier. Pinned `make test` 311, thread storage, thread
module, pack, architecture 431 entries; combined runtime 134 of 134.

### 2026-09-09 Claude: fixture-only carrier permission recovery

Astra's round 22 chose the carrier recovery proofs over step 5. The
exchange is wired into the carrier for the fixture only: the host launch
policy names the adapter, the acceptance record, the proven fixture digest
and the approver policy (`permission_exchange`); a non-fixture policy may
name only the adapter the profile itself pins, and `plan` checks the
acceptance record against the measured binding, profile, adapter and
fixture digests before anything runs. The checkpoint gains `permissions`
(at most four) holding every derived key and the phase; each phase is a
`bee.carrier.permission` control record under a deterministic key
(`intended`, `requested`, `decided`, `revalidated`, `consumed`,
`acknowledged`, `closed`, `refused`). The carrier detects a request among a
chunk's observations and commits the intent with that chunk, asks the
owner under the idempotency key, polls the decision on the policy's tick,
consumes under the incarnation it observed and revalidates on
`REVALIDATE` (re-checking that the attempt still waits), then answers
through one deterministic write id on the existing write path; denial
uses the adapter's deny encoding and is acknowledged by the adapter's
named terminal denial or closed as unproven at settlement. A second
pending request with a reused correlation is refused on record. Two
defects surfaced and were fixed at their cause: placement `attach` refused
an exited attempt whose runner still held unacknowledged output (the
runner supports attach after exit and resends), so a crash after a
dispatched response lost the answer; and placement `reconcile` marked a
live attempt without a recorded execution identity uncertain even while
its runner answered (on the pinned runtime no child pid is known, so the
sweeper would do this to every live attempt within thirty seconds), which
made a placement test fail whenever a sweep overlapped it. Reconcile now
asks the runner for a write status it cannot know and records
`reconcile.supervised` while the runner answers; the lost-runner test
accepts a runner-proven exit (`exit_source = runner`) on the combined
runtime, where cancellation reaps the child. The carrier resume attaches
after exit while the runner lives and otherwise settles from the recorded
exit after the drain. Proof: `tests/lua/harness/permission_carrier_test.lua`
drives allow and deny end to end, six crash boundaries (intent committed;
approval created before checkpoint; requested; consumed before write
intent; write intended; write dispatched) each with one approval and one
child-observed response, an authority restart between revalidation and
consumption (two revalidations, one consumption), runner loss during write
recovery (write uncertain, nothing resent) and a decision after the
attempt ended (nothing sent, exchange closed). Pinned `make test` 318,
thread storage, thread module, pack, architecture 431 entries; combined
runtime 140 of 140. Note: another lane's uncommitted edits under
`src/core/applications` currently fail the pinned `make lint`, so the pack
was built by invoking the runtime directly; those files were not touched.

### 2026-09-09 Claude: round 23 corrections on the fixture exchange

Astra's round 23 kept approver selection host-only and polling bounded
(thread transitions later as hints only) and asked for three corrections,
all built. Placement reconcile now sends the runner a typed `status`
control carrying the attempt identity; the runner answers on
`bee.placement.status` with what it observes (execution as it sees it,
exit code, EOF count, pending outputs, remembered writes) and reconcile
records `reconcile.supervised` with that detail, never promoting it to
exit or cleanup. The carrier measures binding, profile, launch policy,
adapter and acceptance record from one pinned registry generation
(`catalog.pin`/`catalog.entry`), the acceptance record carries its own
digest, the plan digest includes it, and the checkpoint records the plan
digest at open. Revalidation is full: before consuming under a new
authority incarnation and before any dispatch after recovery, the carrier
re-plans and refuses when the plan digest, adapter or acceptance digest
differs from the checkpoint, when the proposal no longer digests as
recorded, or when placement reconcile does not leave the attempt running
under its grants and projections; a refusal closes the exchange on
record. Proven by a new case: a crash after consumption, a changed launch
policy, then a resume that closes the exchange with "plan measurements
changed" and writes nothing. Pinned `make test` 319, thread storage,
thread module, pack (built directly; the other lane's broker edits still
fail the pinned lint), architecture 431 entries; combined runtime 141 of
141.

### 2026-09-09 Claude: fixture-path retention and status authentication; step 5 contract

Astra's round 24 asked for two fixture-path corrections and chose step 5.
Placement `timeouts.retain_ms` (default 30 s, launch policy `retain_ms`)
bounds how long a runner keeps unacknowledged output after the child
exited and both streams ended; on expiry the runner records `output.lost`
with the unacknowledged chunk and byte counts and finishes, so a lost tail
is distinguishable from consumption (proven with a 300 ms retention and a
recipient that never acknowledges). Runner status replies are
authenticated: the service sends a fresh probe with the attempt identity,
and `protocol.status_reply_accepted` accepts only the placement-recorded
runner pid, the same attempt, the current attachment generation and that
probe (negative proofs for sender, attempt, generation, probe and an
unknown execution). Step 5 contract, transport-independent:
`docs/THREAD_SESSIONS.md` states the owner-qualified reference, the send
request and reply, status/replay against the request identity and the
subscription session transitions. `bee.threads.service:send` commits a
forwarded message under `send/<caller_node_id>/<idempotency_key>` after
verifying the sender's payload digest: replay on the same identity,
`CONFLICT` on a different payload, `INVALID_ARGUMENT` on a digest
mismatch, `DENIED` for non-members; `send_status` answers a sender that
lost the reply. `bee.threads.delivery:session` is the consumer's pure
session: transport loss acknowledges nothing, reconnect continues the same
lease, requires resume under a new owner incarnation or lease generation,
or resets a closed or replaced subscription; pages of another lease are
dropped, one page stays outstanding, and only the owner's reply moves the
cursor. No forwarding over the supervisor seam and no two-runtime proofs;
production cross-node capabilities stay false. Checks: pinned `make test`
325, combined runtime 147 of 147, architecture 435 entries, thread
module, thread storage; the pack was produced by invoking the runtime
directly because the pinned `make lint` fails on another lane's
uncommitted edits (`bee.applications:broker` lines 145, 610, 617, 647, 649:
"expected tty.Viewport, got tty.Viewport"), so this is not a passing
Makefile gate. Parallel gate runs were killed for memory once; gates now
run one at a time.

### 2026-09-09 Claude: round 25 seam rules, stale sessions, post-exit drain

Astra's round 25 chose a destination-established principal actor that the
thread owner admitted as a member and set the seam rules, now recorded in
`docs/THREAD_SESSIONS.md` (principal mapped by the destination from
trusted issuer and subject, caller node from authenticated ingress,
host-selected scope, context as correlation only, identity stable across
supervisor restarts). The send identity is explicitly the thread, the
authenticated principal, the caller node and the idempotency key; two
subjects on one node commit two records and read only their own status,
and the request digest covers context (a retry with a different
correlation conflicts). `send_status` states that `committed = false` is
"no matching commit at this read", not proof of non-execution. The
consumer session orders summaries by owner incarnation then lease
generation: an older generation, or an equal one with a cursor behind the
session's, is stale and changes nothing; a resume reply must be newer
than the held lease. Placement gains `timeouts.drain_ms` (launch policy
`drain_ms`): after an independently observed exit with descendants
holding the pipes, the runner drains for that bound, closes the streams
and records `output.drain_elapsed`; on the pinned runtime, where exit is
gated on EOF, the test asserts the gated behaviour instead. Checks: pinned
`make test` 328, combined runtime 150 of 150, architecture 435, thread
module and storage; the pack is a direct runtime build while the other
lane's broker edits fail the pinned lint.

### 2026-09-09 Claude: wakeup hints, truncation as truncation, owner authority scoping

Astra's round 26 chose subscription wakeup hints and corrected two
readings. Hints: with the exchange enabled the carrier holds a durable
subscription to its thread's `approval.transition` records
(`hint_subscription` in the checkpoint, resumed under a replacement's
lease so old pages are fenced) and registers a private topic with the
thread waiter; a wake or the poll tick pages the subscription, any
transition is only a reason to read the approval owner, hints coalesce
into one refresh, the page is acknowledged after processing (certifying
neither consumption nor child input), polling stays the fallback, a lost
subscription is reopened on the next tick, and the subscription closes at
settlement. Proofs: a decision reaches settlement in under 1.8 s against
a 2 s poll with stale wake messages before and after; a subscription
unsubscribed while the carrier is paused after opening it still decides
once through polling; a decision after settlement is projected and sends
nothing. Truncation: the runner marks EOF chunks it forced at the drain
deadline `truncated` and reports it in status; the carrier keeps an
output state (`complete` only when both streams ended on their own,
`truncated`, `unobserved` when the runner was gone at recovery), records
each truncated stream and the state before the turn ends as
`bee.carrier.output` control records keyed per stream and per carrier
generation, and names truncated or unobserved output in the settlement
reason; the launch policy separates `runner_drain_ms` (the runner's
post-exit drain) from `drain_ms` (the carrier's own wait, which now adds
the runner's), so the truncation marker always reaches the carrier first.
Proven with a truncated stream plus an orphan holding the pipes: on the
combined runtime the attempt settles uncertain with the state truncated,
never complete; EOF-gated exit yields open or complete and no truncation.
Owner authority: thread migration 8 adds `bee_thread_owner.authority_id`,
minted once per store when the owner starts; subscription summaries carry
`owner_authority`, and the consumer session resets on a different
authority instead of comparing incarnations across stores. Checks: pinned
`make test` 330, combined runtime 152 of 152, architecture 435, thread
module and storage; direct pack build while the other lane's broker edits
fail the pinned lint. Gates run one at a time after parallel runs were
killed for memory.

### 2026-09-09 Claude: round 27 details, Codex authentication gate, runtime close_stdin

Round 27's three details: the carrier's output state travels in the
checkpoint, a recovery with the runner gone turns only `open` into
`unobserved` and never a checkpointed `complete` or `truncated`,
settlement turns `open` into `incomplete` and names every non-complete
state in the reason (timing is not ordering; the carrier's deadline
winning is recorded, never inferred as completeness), and hint
subscriptions use one consumer identity per attempt with a superseded id
closed before another opens, so rows never accumulate. The Codex
authentication gate was driven against the pinned executable
(codex-cli 0.153.4) from an isolated home with a sentinel key and a
controlled local endpoint: the executable does not take
`OPENAI_API_KEY` from the environment alone (it goes to the real provider
websocket without a bearer), and it sends `Authorization: Bearer
<sentinel>` to the endpoint only through a provider configuration in
`CODEX_HOME` (`env_key = "OPENAI_API_KEY"`, host base URL,
`wire_api = "responses"`), with the sentinel absent from stdout and
stderr. The proof also found that the admitted launch writes the brief to
stdin and Codex reads until end of file, which the runtime could not
deliver: runtime PR 698 (`feat/exec-close-stdin`, assigned to skhaz) adds
the `StdinCloser` capability, native and docker `CloseStdin`, and the Lua
`close_stdin` method (idempotent, refused for PTY processes, later writes
refused). Bee's Codex launch declares `stdin_eof`, placement measures
`stdin_close` and refuses such launches where the executor cannot close
stdin, the runner closes stdin after the write, and
`tests/lua/harness/codex_auth_test.lua` proves the path when
`BEE_CODEX_BIN` names the executable and reports the gate `unproven`
otherwise; `launch.CODEX_AUTHENTICATION` stays `unproven` until Bee
projects that configuration. A combined binary with process groups,
`done()` and `close_stdin` is at `~/kickside/runtime-exec-combined2`.
Checks: pinned `make test` 331, combined runtime 153 of 153 (with the
Codex proof), architecture 435, thread module and storage; direct pack
while the other lane's broker edits fail the pinned lint.

### 2026-09-09 Claude: Codex configuration projection and the integrated authentication-path proof

Astra's round 28 asked for the generated Codex configuration projection and
a proof through the real placement runner. `bee.driver.codex:configuration`
decodes a host-owned `bee.codex_provider` entry (name, base URL, model;
plain http only for the loopback fixture) and renders exactly the reviewed
fields as TOML with string escaping, `env_key = "OPENAI_API_KEY"` and the
responses wire API; the launch policy names it through
`codex_provider_ref`, the carrier measures it from the pinned snapshot, the
plan digest pins the adapter revision and rendered digest, and the
placement request carries it as `configuration`. The runner writes it into
the private home with exclusive creation before start
(`configuration.materialized`, or `configuration.refused` when a file
already exists), writes the complete initial input, closes stdin once and
records `stdin.accepted`, `stdin.closed` or `stdin.uncertain`; later input
is refused by the runner and recorded as a refused write by the carrier; a
resume before placement start refuses a plan that no longer digests as
recorded. Driver prepare options moved into the host launch policy
(`prepare_options`), which the Codex path needed since the carrier had sent
Claude's permission mode to every driver. Two placement defects surfaced:
`resources.directory` returned the declared `${env:...}` placeholder for
the placement root unexpanded, and relative roots reached children as
relative `HOME` paths; both are resolved now (placeholder through the
declared variable, relative paths against the runtime's working directory
via `system.process.cwd`, with `system.read` on `cwd` granted to the
placement store policy). `tests/lua/harness/codex_runner_test.lua` proves
API-key authentication-path selection end to end when `BEE_CODEX_BIN`
names the executable and the runtime can close stdin: the controlled
loopback endpoint records `Authorization: Bearer <sentinel>` at
`/v1/responses`, evidence shows configuration and credential
materialization and the stdin ordering, no thread record carries the
sentinel, a post-EOF write is refused on record, a changed provider refuses
resume before start, and a policy without a provider refuses the plan; on
the pinned runtime the same test proves the stdin-closure refusal, and
without the executable it reports the gate open. Checks: pinned
`make test` 334, combined runtime (process groups, done, close_stdin) 156
of 156 with the Codex proofs, architecture 438, thread module and storage;
direct pack while the other lane's broker edits fail the pinned lint.
`launch.CODEX_AUTHENTICATION` stays `unproven` until the pinned build
carries the runtime capabilities.

### 2026-09-09 Claude: round 29 checks and the Claude environment-only proof

Astra's round 29 checks are in: configuration evidence carries the revision,
path, digest and home key only (no OS path); the runner creates the
configuration parent inside the home it just created and refuses any
existing entry, with symlink containment stated as the runtime fs module's
guarantee in code and in `docs/CARRIER.md`; placement validates the carried
configuration against what the host provider renders (`provider_ref`,
`bee.driver.codex:configuration`), and a negative placement test proves a
foreign configuration is refused. The endpoint fixture now answers 400
instead of 401, which Codex treats as terminal (one request, exit within a
second) and Claude too (`api_error_status 400` after a few seconds). Since
Codex no longer waits on the endpoint, the Codex proof's late write raced
the exit; the fixture takes a hold in seconds, the endpoint records the
request before holding its answer, and the suite sends the late write only
once the record shows the request, so the refusal is proven while the child
is provably waiting. `tests/lua/harness/claude_runner_test.lua` is the
Claude proof through carrier, runner and broker: version-recorded
executable bound through `BEE_CLAUDE_BIN`, host-selected loopback endpoint
through the launch policy `environment`, sentinel `ANTHROPIC_API_KEY`
projected by the broker, no login state in the private home; the endpoint
records `x-api-key: <sentinel>` at `/v1/messages`, evidence shows
credential materialization, and no evidence, thread record or settlement
carries the sentinel. Both proofs pass on the pinned runtime (Claude runs;
Codex proves the stdin-closure refusal) and on the combined runtime.
Checks: pinned `make test` 336 with both executables bound, combined
runtime 146 of 146, architecture 438 source and pack, direct pack, thread
module and storage; the pinned `make lint` is clean again on the shared
tree. `launch.CLAUDE_AUTHENTICATION` and `launch.CODEX_AUTHENTICATION`
stay `unproven` until the pinned build carries what the proofs need.

### 2026-09-09 Claude: two intermittent failures traced, provider selection authorized, real Claude control protocol

The grandchild-cleanup failure on the combined runtime was a service
ordering defect, not a test race: `stop_attempt` dispatched the stop
control before recording `stopping`, so a runner that observes the kill
land at once recorded `exited` first and the service's own transition was
refused with a CONFLICT for a stop that had succeeded. The intent is now
recorded before dispatch, a refusal reloads the attempt and answers with
it when it is no longer live, and the test asserts `stop.requested` on
record before `child.exited`; ten consecutive combined runs pass. The
truncation case on the pinned runtime settled with output `incomplete`
(not truncated): under EOF-gated exit the terminal envelope settles the
run while the other stream's end mark is still in flight, which the
contract already names as incomplete; the test now accepts complete or
incomplete and still refuses any truncated stream. Placement requests
carry `policy_ref`; prepare refuses a reference that is not a host launch
policy and a configuration whose provider the named policy does not
select, so provider selection is the policy's, never the caller's
(`bee.placement:types` owns the launch policy type name). The real Claude
control protocol is captured from the executable
(`tests/fixtures/drivers/claude/stream-json-2/control.jsonl`) and
described by `bee.driver.claude:permission_adapter`: request `request_id`
correlates the response, `request.tool_use_id` is what the tool result
echoes, the response is the nested `control_response`, a deny is
acknowledged by the correlated failed tool result, a closed stdin denies a
pending request. The adapter schema takes dotted response paths, a
separate acknowledgment id and a correlated terminal denial; the
checkpoint carries the acknowledgment id. Prompts appear only with
`--input-format stream-json --permission-prompt-tool stdio
--permission-prompts host`, the brief must be the first stdin line, and
the harness idles after its result until stdin closes, so the driver
prepares that shape when the host enables an exchange (the brief line is
canonically encoded, since a non-canonical line changed the plan digest
across a crash and broke recovery) and the carrier stops the child
cooperatively after settlement. The endpoint fixture answers a scripted
Bash tool_use under `BEE_ENDPOINT_TOOL`. Proofs with the executable:
`claude_acceptance_test` (request observed and the harness waits, a
correlated allow executes once, a deny is acknowledged and runs nothing,
a wrong correlation and silence leave it waiting) and
`claude_control_test` (allow, deny and expiry through carrier, placement
and the approvals owner, the marker file landing in the project only on
allow); both Claude profiles pin the adapter; shipped launch policies
enable no exchange. Pinned `make test` and the combined runtime suites
pass with both executables bound.

### 2026-09-09 Claude: round 31 corrections, declared session end, the recovery matrix against the executable

Astra's round 31: the adapter schema is `bee.permission-adapter@2` (dotted
paths of at most eight segments, no empty segment, response paths that
overlap or cross the envelope refused at decode, an older revision refused
by name); the Claude profiles pin the revision-2 digest. A denial or
expiry no longer records `consumed`: the carrier phase is `declined`,
which reserves the response write and consumes no effect, so a denied or
expired approval never satisfies an approved-effect check. The session end
is declared in the driver launch (`session_end: stdin_close` for the
Claude exchange launch, decoded by placement, refused beside `stdin_eof`)
and runs before the settlement records end the attempt: terminal envelope,
pending-write resolution, `input_closed` committed to the checkpoint with
a `bee.carrier.input` `close_intended` record, placement `close_stdin`
(a new owner method; the runner closes and answers with a probe-bound
reply and records `stdin.closed` or `stdin.uncertain` apart from input
acceptance and exit), `closed` or `close_uncertain` on record, the exit
awaited within the policy grace, the cooperative stop as the fallback and
the runner's kill after its grace; a launch without a declared end is
stopped cooperatively after settlement; a resumed carrier ends a settled
session without records and never writes once `input_closed` is set. The
fixture harness waits for stdin end of file under stream-json input as the
executable does, so every fixture exchange proof exercises the close on
the combined runtime and the stop fallback on the pinned one. Fixture
processes in the proofs end by signal and are reaped before release, which
removes the endpoint leaks the pinned runtime's close alone left behind.
The recovery matrix now runs against the real executable in
`claude_control_test`: every crash boundary before the response with one
approval, one response and one effect, the authority restart between
revalidation and consumption, a runner lost before dispatch (write
uncertain, no effect), a takeover with two live carriers (old one fenced,
one response, one effect) and a decision after the attempt ended (nothing
sent). Two intermittent-looking failures on the way were real: a
non-canonical brief line changed the plan digest across a crash, and the
`bee.carrier.input` control event had to be admitted by the thread carrier
ops. Checks: pinned suites and the combined runtime 153 of 153 with both
executables bound; the full gates follow.

### 2026-09-09 Claude: round 32 corrections, executable measurement, counted effects, loss after dispatch

Astra's round 32: every exchange is closed on record before a declared
session end closes input (`machine.close_exchanges`, also the no-op at
settlement), the post-close wait and the fallback stop's grace are
documented as separate intervals with the whole bound at twice their sum,
and `bee.carrier.input` stays a separate control history. The matrix's
effect is a counted append, so a duplicate execution is visible, and a new
boundary loses the runner itself after dispatch with the acceptance
unresolved: the write stays uncertain, nothing is resent, the effect
happened at most once, and a resumed carrier that finds the attempt
`uncertain` with no runner settles it as uncertain with a truthful reason
instead of failing. Executable measurement: a path is not an identity, so
placement offers `measure_executable` (`bee.executable-measurement@1`:
content sha256 through a host filesystem volume, kind elf/script/other
with the interpreter line, size), the carrier measures the host-bound
absolute executable at plan time and puts it in the plan digest and the
placement request, and the runner measures again immediately before exec
(`executable.measured`, or `executable.changed` and a refusal). The
acceptance record is `bee.permission-acceptance@2` with
`executable_digest`; the plan refuses an exchange whose measurement
differs; a fixture policy proceeds without a measurement where the runtime
cannot take one. Hashing a 216 MB executable from one string is not
acceptable, so the runtime gains a streaming hasher (`hash.new` with
update, sum, reset; runtime PR 699, assigned to rodrigo) and the combined
build `~/kickside/runtime-combined3/bin/wippy` carries process groups,
done, close_stdin and the hasher; on the pinned runtime files above 8 MiB
are refused rather than read whole. Checks: pinned placement and harness
suites, combined3 154 of 154 with both executables bound; the full gates
follow.

### 2026-09-09 Claude: measurement coverage bound into acceptance, read-only measurement volume

Astra's round 33: the acceptance record binds the measurement revision
and kind beside the digest (`executable_revision`, `executable_kind`,
`executable_digest`), the plan refuses an exchange when any of the three
differs, and a production exchange covers a measured native image only:
a script's digest pins neither its interpreter nor what it starts, so
that form is refused rather than described as covered; fixture policies
keep the fixture script. The placement request and the runner's pre-exec
verification carry the kind as well. The measurement volume is declared
`readonly`, which runtime PR 700 (`fs.directory` read-only volumes:
every mutation refused at the boundary, handles read-only, no root
creation, tests first) enforces and an older runtime ignores, as its
entry comment says; the placement code itself only reads through it and
the carrier never holds a filesystem handle. A read-only view limits the
measurement component's authority; it neither prevents another process
from replacing the executable nor closes the check-to-exec window. The
full Makefile gate that ran beside the previous edits failed on the
transient lint errors of an edit in flight; on the settled tree the
composite run was stopped by the session's memory guard, so its
components ran one at a time and each exits 0 (installer-check, lint,
test 344, threads, threads-module, pack, headless-check,
workspace-hosts-check). An intermittent acceptance failure was traced to
the endpoint fixture answering a second tool_use when the executable
appended a user message after the tool result; the fixture now answers
text once any message carries a tool result. A combined build carrying
PR 700 measures through the read-only volume: 154 of 154.

### 2026-09-09 Claude: managed-launch acceptance handoff, measured capabilities, production refusals proven

Astra's round 34 closes the slice with `docs/handoffs/MANAGED_LAUNCH_ACCEPTANCE.md`:
the runtime commits and patch order of the combined builds (PRs 694,
695, 696, 698, 699, 700 over main `fdad09cef2`), production requirements
against fixture exceptions with the refusal each produces on the pinned
runtime, the commands, and the full-gate coverage map naming what was not
run. Placement's capability report gains `executable_measurement`
(`streaming` from the hasher's presence, `read_only_volume` proven by a
creating open through the host volume at a path inside the placement root
that an enforcing runtime refuses and an older one performs before the
probe is removed), exposed as a callable `capabilities` method; a
production exchange requires both, then a bound absolute executable of
kind `elf`, and refuses with a reason prefixed `production exchange:`.
`tests/lua/harness/permission_carrier_test.lua` proves both production
refusals on the host it runs on: a policy naming an adapter no profile
pins and a production-shaped policy naming the real adapter with a
complete acceptance record. `make managed-launch-check` runs
`tests/managed_launch.py`: the five suites against a named combined
runtime with both executables required (a missing or wrong one fails the
target) and every real-executable proof required to pass. Combined build
with PR 700: 154 of 154 through the target; pinned `make test` 344.

### 2026-09-09 Claude: approvals inbox application, local, over the owner API

Astra's round 35 direction: a console-style Bee application in the desktop
over the existing owner API, with five adjustments. `bee.inbox:app`
(`src/apps/inbox`, admitted with `bee:approval_decide_policy` and its own
narrow `client_policy`) runs under the process actor and reads the owner's
`inbox` for the launch workspace plus the host's `bee.inbox:workspaces`;
`bee.inbox:model` is pure and holds only selection, a details toggle and
one in-flight request: pages fold in by revision, a decision is asked only
of an opened pending request at the viewed revision and digest after the
shell's confirmation dialog, a conflict or settled state replaces the view
with the owner's committed record and resubmits nothing, an answer lost in
transport is recovered by a `read`, requester, owner and effect target are
shown apart, every request text is bounded and stripped of control
sequences and a payload renders only as bounded key and value lines; the
owner alone decides who may withdraw. `bee.inbox:view` leads with the
proposed effect and keeps digests, revisions and the observed incarnation
behind a toggle; actions are buttons and keys that go through the dialog,
never a selection. Proofs: pure model and frame tests, and
`surface_test` against the real owner under distinct viewer actors (two
viewers racing, the outsider refused, expiry while viewing, the lost
answer recovered without deciding twice, close and reopen deciding
nothing, hostile prompt text kept out of the frame), plus
`tests/inbox_app.py` booting the app under the broker. Also from round 34:
read-only enforcement is reported only on the runtime's own read-only
error. Pinned `make test` 361; architecture 450 source and pack; pack.

### 2026-09-09 Claude: inbox admission proofs and the local presentation recovery proofs

Astra's round 36: the storage boundary change stands only with runtime
denial proofs from the admitted scope, and the four local presentation
proofs come next. `tests/lua/inbox/admission_test.lua` spawns a probe
process under the scope the broker composes for `bee.inbox:app` (the four
base policies plus the admission binding, read from the admission entry)
and proves the approval store denied before and after owner calls, only
inbox, read, decide and withdraw answering, list, consume and the service
library out of reach, and eligibility following the process actor: a
listed approver sees and decides, an unlisted actor sees nothing and is
refused whatever the admission grants. In the local desktop every app
runs under `bee.local`, so the host's approver policy must name it.
`tests/lua/inbox/recovery_test.lua` proves, against the real owner and a
thread-bound request: one decision through a delivery worker stopped at
commit time, the authority restarted and the inbox reopened, with the
transition delivered exactly once; a page that never arrived advancing no
cursor and replayed pages repeating nothing; consumption refused for an
effect owner whose consume authority is gone while the decision stays as
committed; and a headless owner restart with the worker stopped and no
inbox open recovering the request, its delivery, the decision and
consumption under revalidation. Pinned `make test` green with the inbox
suites; architecture asserts the boundary shape.

### 2026-09-09 Claude: changed-proposal proofs, plan refusals for recovered attempts, approvals acceptance handoff

Astra's round 37 accepted the inbox for the single-actor local desktop and
asked for changed-action-parameter proofs and the acceptance document.
`tests/lua/inbox/changed_proposal_test.lua` proves at the owner and inbox
level that an approval binds the proposal it was given: consumption with
a changed input's digest is refused, the decision and its proposal stand
as committed and the inbox shows the approved payload rather than the
changed definition, the changed proposal is a separate pending request
with its own identity, and a revised operation or a different launch
policy digests as another proposal. `permission_carrier_test` gains two
cases on a bound copy of the fixture executable: after a crash past
consumption the executable's content changes and the recovered carrier
refuses before dispatch with "executable measurement changed since
acceptance", the decision kept; and between revalidation and consumption
under a restarted authority the same change is refused the same way. That
surfaced a defect: an acceptance mismatch failed the plan outright, so a
recovered carrier crashed at plan instead of closing its exchange on
record; plan refusals now travel in the plan (`exchange_refusal`), a new
attempt refuses to open with one, and a recovered attempt keeps its plan,
closes the exchange with that reason and settles without dispatching.
`docs/handoffs/APPROVALS_ACCEPTANCE.md` maps every requirement to its
proof and states the boundaries (all local applications act as
`bee.local`; the approvals store off the application deny list, opened
only inside the owner's methods; no decision-revocation transition) and
the exclusions (cross-node projection, remote Terminal admission,
managed-launch activation, per-viewer actors, remembered policies).

### 2026-09-09 Claude: destination principal mapping and thread-operation admission

Astra's round 38 closed local approvals (two qualifications added to the
acceptance map: which changed fields are fault-injected and which rest on
digest coverage; `exchange_refusal` permits recovery and its recording
only) and transferred destination principal mapping and thread-operation
admission to this lane. The verified-ingress value is documented in
`docs/HIVE_SUPERVISOR.md`: the `types.Request` that `admission.accept`
returns for a pinned peer session. `bee.hive.supervisor:principals`
decodes the host's `principal_mappings` table (issuer, subject, a
`bee.hive.member.` actor, policies; each pair once, subjects inside the
issuer's namespace, no local service actor nameable);
`bee.hive.supervisor:thread_admission` admits a forwarded send or
send_status only for a mapped principal, runs it as that actor under the
mapping's policies with the caller node from the ingress, and refuses a
payload that names another caller node or any actor, scope or principal
field; `admit_thread` is the supervisor's worker for it and `main` routes
accepted remote thread operations there, local callers never. Proofs
against the real thread owner: unknown issuer and subject denied, two
subjects of one node with separate commits under one key, identity stable
across the caller's incarnations (the same command replays the same
commit), refusal after the mapping and after the membership is removed,
payload selection refused, the worker's hive reply. The gap the ingress
leaves, a process PID as the asserted subject, is specified as
transport-side work: assert a runtime-authenticated stable subject.

### 2026-09-09 Claude: derived principal identities, common ceilings on the thread branch, interface note

Astra's round 39: the stable-subject assertion stays with forwarding; an
interface note is written beside the destination contract in
`docs/HIVE_SUPERVISOR.md` (subject is the originating runtime's
authenticated security actor qualified by the issuer, never supplied by
the caller, the PID provenance only, forwarding refuses without a
trustworthy identity; runtime evidence: messages expose only the sender
PID, funcs carry the caller's actor, no sender-actor message API exists).
Mapping identity: the host table now admits pairs and policies only, the
destination actor is derived from the pair (`principals.actor_of`), so a
table edit can neither retarget a pair nor alias two pairs, and identity
linking is an explicit future policy. Admission ceilings: the thread
branch checks the host exposure ceiling (`hive.expose.policy`, granted by
`bee:hive_thread_exposure_policy`), the owner service, the operation
revision, the exact payload fields, the input digest and the deadline
before the mapping, proven with refusals for each. The supervisor-process
integration test cannot run in one runtime (a peer needs another node's
identity on the protected host) and the two-runtime harness needs the
forwarding side to admit thread operations, so the destination boundary is
proven at the worker with requests shaped as `admission.accept` returns
them; stated as such. Pinned `make test`, architecture and pack green.

### 2026-09-09 Claude: thread-admission hardening

Astra's round 40: invocation authority is the principal's own, so the
worker now asks `bee.hive.supervisor:invoke_check` under the mapped actor
and scope whether `hive.invoke` is granted on the operation, refusing a
mapping without `bee:hive_thread_invoke_policy` before the owner is
called, and the worker's exposure grant supplies nothing;
`owner_ref.resource_ref` must bind the payload's `thread_id`, refused
missing or mismatched before dispatch; replies above
`types.MAX_OUTPUT_BYTES` are refused naming `send_status`; a route past
its deadline after dispatch reports the outcome unknown, not a
cancellation. Proofs added: the uninvoking principal refused, an input
above the envelope bound never decoding, a message above the owner's
record bound refused without a commit, each subject reading only its own
status and an unmapped subject none, a duplicate admitted request
creating no record, and the resource binding refusals. The identity
encoding is documented as `bee.hive.member@1` (sha256 over issuer,
newline, subject; 128 bits); the route bounds are documented with their
numbers and their proof left to the two-runtime acceptance.

### 2026-09-10 Claude: hooks proof 5 corrections (Astra round 65)

Seal split from revoke (migration 7 `sealed_at`; `bee.gateway:seal`; the
seal check, replay lookup, bound and insert are one transaction; the runner
seals at child exit, the carrier seals at close, drains within `drain_ms`,
rejects leftovers and revokes; revoke rejects queued rows terminally);
`hook_ack` requires the exact claim epoch; shutdown events (SessionEnd,
StopFailure) refused in `gateway_hooks` and named in placement capabilities;
the runner no longer arms the takeover grace after the child ended. Proofs
added: two live carriers held after claim and after commit (one observation,
the original refused or stopped idle), integrated saturation (carrier held,
64 queued, 429, then every accepted row committed); probe covers seal
(403 after the seal, replay still answers, tool credential valid, nothing
discarded), revoke rejecting queued rows, and acknowledgment refused without
a claim. Carrier and harness proofs green on pinned and combined runtimes.
Full pinned run after the corrections: 435 of 438 passed; the three
failures are `bee.terminal:selection:129` (attempt to call a non-function,
the `plain` function strict lint also flags) in the terminal lane, not the
gateway. Standalone build: `make standalone` runs strict lint through
build/bundle.py and stops on two errors outside this lane
(`bee.hive.supervisor:main:147` no method data, `bee.session:status:52`
channel assignment); the pack itself builds. Reported to Astra.

### 2026-09-10 Claude: profiles, environment, system prompt and Docker proposal

docs/handoffs/PROFILES_DOCKER_PROPOSAL.md drafted for Astra: A, agent
profiles as host-owned registry entries composing binding, harness profile,
policy, nonsecret environment and an instructions reference (Claude
`--append-system-prompt-file`, Codex `model_instructions`), launch definitions
selecting a profile, kits as bindings with driver libraries; B, Docker
attempt placement on `userspace.docker:narrow` per the agreed placement
design with the same runner logic for homes, credentials and gateway
adapters; C, the full desktop operating Docker attempts (start, input,
resize, reconnect, termination, cleanup) with container logs never standing
for the UI. Order A, B, C.

### 2026-09-10 Claude: gateway hooks proof 5, carrier integration

Intake lifecycle in the gateway: migration 6 (claim epoch, rejection reason,
status rejected), `hook_claim` (fenced by the highest admitted carrier epoch,
takes over lower claims, rejects the queue of an expired or epoch-changed
binding, still drains a revoked one), `hook_ack` (claiming or higher epoch
only, prunes retained rows past 256 or 512 KiB), `hook_reject`; supersession
and `revoke_attempt` reject queued rows, `revoke` only ends intake; a replay
of a rejected occurrence answers 410 plain text; the MCP form answers
`queued <event_id>`. Adapters rendered by `bee.gateway:configuration`:
Claude `.claude/settings.json` (http handlers per event, allowlists,
timeout 2) and Codex `hooks.json` plus trust hashes reproduced host-side and
verified against the app-server (matcher-less identities), written by the
runner into the `bee` profile layer under the home's own path; Codex launch
line gains `--profile bee`. Launch policy `gateway_hooks`; placement verifies
the adapters and the events against the policy; the runner writes them with
protected creation (parents it created itself may hold several files) and
materializes `BEE_GATEWAY_HOOK_TOKEN`. Carrier: admits hooks, drains on a
one-second tick, on open or resume and at settlement, commits
`bee.harness.hook` observations keyed by occurrence (canonical payload
without carrier identity so a replacement replays byte for byte),
acknowledges, rejects leftovers at close; `bee.threads.carrier` admits the
event. Proofs: fixture child reports hooks (records without content, queue
committed), crash after `hooks_committed` recovered with one record per
occurrence, a flood of 200 loses nothing accepted; real harnesses through
placement (Claude on pinned, both on combined) with hook records in the
thread. Full pinned run 431 tests green, gateway.py green, managed_launch
on the combined runtime 196 tests green.

### 2026-09-10 User question: a system prompt for all agents

The user asked whether a system prompt (or similar) can be set for all
agents when they run. Not yet. Verified mechanisms: Claude Code
`--append-system-prompt[-file]` and `--system-prompt[-file]`; Codex the
`model_instructions` configuration key (and AGENTS.md in the working
directory). Recorded for the profiles unit: a host-owned profile field
(appended system prompt) rendered by placement as a measured file in the
private home and referenced from the launch line (Claude) or the provider
configuration (Codex); never from the launch request.

### 2026-09-10 Claude: hook adapter corrections (Astra round 64) and intake lifecycle contract

Astra accepted the durable intake queue and asked for a tightened lifecycle
before carrier integration: 202 durably accepted by the gateway, status
queued/committed/rejected, carrier-epoch-fenced claim and ack, atomic thread
commit before committed, recovery after commit before ack by stable event
identity, explicit treatment of queued rows on revocation, expiry,
settlement and replacement, retention bounds; three adapter corrections:
Stop is always ambiguous (no occurrence id), selected values are kept only as
enumerated codes or validated identifiers (reason, error, source,
permission_mode, notification_type enumerated; tool_name a bounded
identifier), the MCP answer names the status (`queued <event_id>`). Applied
in bee.gateway:hooks, hook_mcp_method, hooks_test and the probe; the carrier
proofs now act on the child's presented count instead of fixed sleeps and
the expiry proof waits for expiry, so they pass on the combined runtime too
(the earlier managed-launch failure was the report reader stopping at one
page of records; it paginates now, rerun in progress). docs/GATEWAY_HOOKS.md
carries the intake lifecycle contract for proof 5. User direction on agent
profiles and Docker with the full UI relayed to Astra: carry forward at full
scope after this integration, with separate acceptance for kits and
environments, Docker attempt placement, and the complete UI (input, resize,
reconnect, cleanup); nonsecret profile environment separate from broker
projected secrets.

### 2026-09-10 User direction: agent profiles, per-profile environment, Docker with the full UI

The user asked (voice transcript) for host-defined agent profiles (additional
harness kits or bindings, each with its own environment variables) and for
attempts to run easily in Docker with the proper full UI. Recorded as the
next scheduling question for Astra after gateway hooks proof 5: profile
entries as host-owned registry data (kit, binding, environment, policy) and
Docker session placement (build sequence step 11, `bee.placement.docker`,
`bee.placement_profile`) with the full UI as its acceptance; not to be
scaled down to a reduced-UI or CLI-only Docker run.

### 2026-09-10 Claude: gateway hook endpoints (Astra round 63), carrier integration held

Implemented the hook endpoint adapters: migration 5 (bindings `hooks_json`,
credentials rebuilt with `kind` tool|hook and UNIQUE per binding, generation
and kind, `bee_gateway_hooks` queue); `admit` takes `hooks` from a closed
catalog; `materialize` mints `token` and `hook_token`; `authenticate` takes
the endpoint's kind; `bee.gateway:hooks` (pure: catalog, occurrence identity
and ambiguity, allowlisted fields with sizes and digests only, control-field
drop, Codex metadata classification); `POST /hook/{action}` (Claude http form,
empty-body 202/200, text/plain refusals, `X-Bee-Event`), `GET
/hook/{action}/{event}` (status: queued, committed, unknown, ambiguous),
`POST /hook/{action}/mcp` (Codex form: one `hook` tool, metadata classified,
bare text answer), `bee.gateway:hook_queue`. Proofs: tests/gateway.py
(credential separation on all endpoints, empty bodies, replay, conflict,
repeated Stop, ambiguous SessionStart, 413, 429 with Retry-After, metadata
classes, no content or control field in the queue, revocation);
hooks_test; upgrade through migration 5; gateway_harness_test: Claude http
hooks and Codex mcp_tool hooks (trusted through the app-server hashes,
`bee_hooks` server omitted from the model) reach the gateway under the hook
credential while the read completes, provenance http / codex:hook_engine,
green on the combined runtime; Claude on the pinned runtime. Deviation
noted in docs/GATEWAY_HOOKS.md: the queue lives in the gateway store because
http handlers share no memory, so 202 means queued and not yet committed.

### 2026-09-09 Claude: hook adapter facts proven, hooks design amended (Astra round 62)

Astra: go on bounded hook-adapter proofs, hold carrier integration. Proven
against the executables: Codex mcp_tool hooks run without any bypass when the
host writes `[hooks.state."<key>"] trusted_hash` from the executable's own
app-server `hooks/list` (stdio JSON-RPC; keys `<hooks.json>:<event>:0:0`,
hashes sha256 of canonical JSON of the normalized identity; reproduces
host-side for tool events, Codex drops matchers for others); per-event input
templates are required because a missing field fails the handler; SessionEnd
cannot use mcp_tool. `omit_tools_from` hides the hook server from the model
but a scripted model call of `hook` in namespace `mcp__bee_hooks` still
executes, so omission is not authorization; hook-engine calls carry
`_meta {threadId, progressToken}` while model calls carry `_meta {callId,
x-codex-turn-metadata}`, an executable-set difference the gateway will
require. Claude Code http hooks fire for UserPromptSubmit, PreToolUse,
PostToolUse, Stop, SessionEnd (not SessionStart), expand the header from
allowedEnvVars, are bounded per hook by `timeout` (slow endpoint cancelled,
500 ignored, absent endpoint costs the connect timeout per hook), and a JSON
answer with continue false / decision block on UserPromptSubmit blocked the
turn, so the gateway must answer with an empty body. Sentinel-shape scan for
the materialization key and token added to the carrier proofs (44-character
base64 in errors, evidence and records). docs/GATEWAY_HOOKS.md amended with
Astra's four changes, queue semantics (202 volatile, 200 committed, unknown
permits replay), allowlisted record fields, occurrence identity and the proof
order. No hook code yet.

### 2026-09-09 Claude: gateway hooks design for review

docs/GATEWAY_HOOKS.md written from the captures and the harness sources:
delivery per harness (Claude Code `type: http` hook handlers with
`allowedEnvVars`/`httpHookAllowedEnvVars`/`allowedHttpHookUrls` pinned to the
gateway hook URL, rendered into the private HOME's `.claude/settings.json` as a
generated hook configuration adapter; Codex `type: mcp_tool` handlers against a
second server `bee_hooks` with `omit_tools_from` so the model never sees the
hook tool, input template from the event JSON, trust by config state hash;
SessionEnd cannot use mcp_tool), a second hook-only credential per binding,
and the contract table Astra asked for (identity from the binding, no decision
authority, submission to the fenced carrier's commit path, identity plus
digest dedup, 202 queued versus 200 committed with a status query, lifetime
across replacement, settlement, expiry, drain, bounds with explicit overload)
plus the proofs to bring with the implementation. Indexed from docs/README.md.
No code.

### 2026-09-09 Claude: gateway round 61 checks (materialization key privacy, allowed-tools widening)

Astra round 61 accepted the real-harness acceptance and asked for two checks
before hooks. Materialization key: verified in ~/wippy/wippy that spawn
payloads reach only the spawned process, no Lua API lists them, supervisor
state carries id/status/desired/retry_count/last_update/started_at/details
only, and a runner failure surfaces as an EXIT error text; recorded in
docs/GATEWAY.md. Allowed tools: placement `prepare` now refuses a launch line
whose `--allowedTools`/`--allowed-tools` (flag or `=` form, comma or space
list) names a gateway tool outside the binding's admitted set or the bare
server name (native_test cases); the probe proves the gateway refuses a call
of a tool outside the binding and advertises only admitted tools. Placement
suite and tests/gateway.py green. Hooks: real payload captures taken from
Claude Code 2.1.267 (settings.json command hooks: SessionStart,
UserPromptSubmit, PreToolUse, PostToolUse, Stop, SessionEnd) and Codex 0.153.4
(hooks.json under CODEX_HOME with --dangerously-bypass-hook-trust for an
untrusted file; same six events fired, PreToolUse/PostToolUse for the MCP
tool as `mcp__bee__thread_read`); Codex hook handler types from source:
command, mcp_tool, prompt, agent; trust by content hash in config state.
Design for review next, no implementation.

### 2026-09-09 Claude: gateway round 60 corrections and real-harness MCP acceptance

Astra round 60 items: `admit` refuses a carrier epoch below the highest ever
admitted for the attempt, revoked or not; materialization is bound to one
start by a one-time key placement's service obtains from
`authorize_materialization` (manage on bindings) and hands to the runner it
spawns (hash and window on the binding, consumed by use; migration 4 appended,
also credential `presented_count`/`last_presented_at` incremented on every
accepted presentation); placement capabilities report
`gateway.takeover_grace_ms`; three carrier proofs show revocation, listener
reopen and expiry (`gateway_ttl_ms` policy field) refuse the child at once
inside the grace. Probe proves stale admission, key refusals and counting.

Real harnesses: per-driver configuration (Claude `.claude.json` user scope
with `${BEE_GATEWAY_TOKEN}` header and `--allowedTools mcp__bee__*` on the
launch line; Codex `[mcp_servers.bee]` with `bearer_token_env_var` appended to
the provider file, tools advertised with readOnlyHint so Codex runs them
unprompted); the gateway accepts JSON-RPC notifications with 202. The endpoint
fixture scripts a `thread_read` call (Messages tool_use / Responses
function_call with namespace) and records offered tools and the result.
`tests/lua/harness/gateway_harness_test.lua`: both harnesses initialize,
discover and read the bound thread through the gateway with measurements on
record and no leak; without the variable neither presents a credential. Green
on the combined runtime (~/kickside/runtime-combined3) for both, on the pinned
runtime for Claude with Codex gate-open (stdin close). tests/managed_launch.py
keeps the gateway and managed suites and lists the four proofs, and passes
against the combined runtime (187 tests). Full pinned Lua run 422 tests green;
tests/gateway.py green.

### 2026-09-09 Claude: gateway slice 2 corrections (Astra round 59)

Astra kept environment projection and epoch-based lookup with tighter rules.
Migrations 1 and 2 restored verbatim; migration 3 (`credentials`, rebuild)
appended: listener secret, credentials table seeded from the old token hashes
as generation 1, bindings rebuilt with carrier_epoch (0 for pre-epoch rows) and
credential_generation; `tests/lua/gateway/upgrade_test.lua` proves the upgrade
of a populated store and the downgrade refusal. Admission is one transaction
with exactly one live binding per (attempt, carrier epoch): same digest
replays, different conflicts, only a strictly newer epoch supersedes. A carrier
epoch resolves the binding issued at the highest epoch not above it, so a
takeover inherits the running child's binding; the runner keeps a lost
carrier's binding for `TAKEOVER_GRACE_MS` (3 s) and retires it only without a
newer attach; a stale carrier exit revokes nothing. `materialize` takes the
carrier-recorded binding id and records the authenticated caller. `ready`
verification extracted (`gateway.verify`) with tests for wrong nonce, wrong
generation, forged and missing proofs and an unopened secret. Carrier proofs
now eight (loss without takeover, takeover). Runtime facts recorded in
docs/GATEWAY.md: the request grant is checked before the query is appended and
every redirect target is rechecked against the grant; `follow_redirects`
remains the scoped proposal. Running the Lua proofs in parallel with
tests/gateway.py collides on port 18790 and the verification refuses the other
runtime's listener, as designed; run them sequentially.

### 2026-09-09 Claude: gateway slice 2 (Astra round 58)

Gateway store rewritten (unshipped migration 1): listener with a secret, bindings
with carrier_epoch and credential_generation and no token hash, a credentials
table keyed by binding and generation. `admit` binds without bytes and supersedes
the attempt's bindings at or below its carrier epoch; `materialize` mints once per
generation for the live binding under (attempt, carrier epoch); `reissue` is a
compare-and-set via rows_affected; `revoke_attempt` is fenced by carrier epoch;
`check` reads by id or by attempt and epoch; `ready` sends a nonce and verifies an
HMAC proof under the listener secret. `bee.gateway:configuration` renders the
host-approved `.bee/mcp.json` naming `BEE_GATEWAY_TOKEN`.

Carrier: launch policy `gateway_tools`; plan carries the configuration; open
claims, admits (step `gateway_admitted`), records the binding in the checkpoint,
takes readiness right before start (`gateway_ready`), revokes on any failure
after admission and at close; resume of an intended attempt admits anew.
Placement: `LaunchRequest.gateway` verified at prepare against the policy and
the endpoint render; runner writes the configuration with protected creation,
materializes into the environment, watches the carrier and retires the binding
on child exit, refused start and carrier loss; service rechecks the binding at
start and on sweep and retires bindings when reconciliation ends an attempt.

Proofs: `tests/lua/harness/gateway_carrier_test.lua` (seven, fixture child as
an actual MCP client under `BEE_FIXTURE_GATEWAY`; listener in the test
composition as `tests/lua/managed`), `tests/gateway.py` extended, placement
request test for the gateway projection. Full Lua suites and gateway.py green
on the pinned runtime; architecture.py aborts on `bee.session` (Astra's lane).
docs/GATEWAY.md carries slice 2 acceptance and the scoped redirect-control
proposal (not started).

### 2026-09-09 Claude: gateway slice 1 corrections (Astra round 57)

Drain now records a host-owned deadline (`drain(deadline_ms)`, additive
migration 2), refuses new admissions, and releases every in-flight wait at
its next one-second slice with `{status: released, reason: draining}`;
past the deadline the endpoint answers 503. Proven with a helper process
draining while the probe is inside a 4 s `thread_wait`: the wait returns
released well before its own deadline, admission is refused, and a bounded
read still finishes. Readiness permissions moved off the store policy into
`bee:gateway_readiness_policy`, pinned to the exact ready URL of the host
entry `bee:gateway_endpoint`, which `open` also refuses to differ from. The
runtime's HTTP client has no redirect control (Go default); the grant is an
exact URL and the gateway never redirects; a runtime option would be a PR.
`docs/GATEWAY.md` records that gateway admission belongs after durable
attempt preparation and never in the effect-free `plan`, and the agreed
slice 2 (carrier admission and readiness, `reissue` with a credential
generation, placement's token projection, the six fixture-child crash
proofs, MCP compatibility with an actual client; hooks after).

### 2026-09-09 Claude: gateway slice 1 (build step 9, harness lane)

Astra's round 56/57 decision: the gateway listener is owned by an explicit
managed host composition and absent from the default desktop; no on-demand
service runtime change. Built `bee.gateway` (`docs/GATEWAY.md`): bindings
that stand for an admitted attempt (subject, action, attempt, thread, owner
incarnation, tool set, expiry), opaque 32-byte tokens issued by the gateway
itself and stored only as sha256, a listener epoch advanced by `open` and
paired with the service's restart count as the readiness generation,
`drain`, `revoke`, `ready` (a real loopback GET compared against the held
generation, plus a binding's validity), and the MCP endpoint `POST
/mcp/{action}` (JSON-RPC 2.0: initialize, tools/list, tools/call) that
authenticates the bearer against the action and runs `thread_read`
(`bee.threads.service:read_after`) and the read-only bounded `thread_wait`
(`bee.threads.delivery:watch` under the 5 s transport budget) as the bound
subject under `bee:gateway_tool_read_policy`. Host, Origin and body are
bounded; nothing is advertised beyond the two tools. The listener
(`http.service` 127.0.0.1:18790, router, two endpoints) lives only in the
managed fixture composition `tests/modules/gateway/src`.

Runtime facts learned and fixed at the cause: the executor's right to invoke
a target (`funcs.call`) is checked against the handler's own policies while
`with_scope` sets the callee's scope; `security.new_actor` needs
`security.actor.create`; `http_client` checks `http_client.request` on the
URL before `http_client.private_ip`. `bee:gateway_execute_policy` therefore
grants `funcs.call` on exactly the two tool operations; `ready`'s
`http_client.request` grant sits on the store policy's `'*'` and is worth
narrowing once policy expressions are used there.

Proofs, pinned runtime: `tests/lua/gateway/mcp_test.lua` (strict decode,
closed catalog, bounded arguments and budget, binding validity under epoch,
expiry and revocation); `tests/gateway.py` (`make gateway-check`, in `make
check`) against the real listener and thread owner: readiness with the
generation, admission returning the token once, cross-attempt refusal both
ways, expiry, revocation, `thread_read` returning the owner's page for the
bound subject, `thread_wait` timing out within the budget and waking on a
new record with no delivery mark written, drain refusing admission, a new
epoch fencing earlier bindings and readiness; no token bytes in captured
output. All Lua suites pass except `bee.hive.supervisor:supervisor_test`;
pack builds. `tests/architecture.py` now aborts before the gateway checks on
`bee.session:main` importing `bee.session:bindings` (Astra's shell wiring);
the gateway assertions were verified directly: no `http.service`, router or
endpoint in the default composition and loaded equals declared. Next slice:
placement's dedicated token projection to the child, hook ingress, and the
carrier's readiness handshake.

### 2026-09-09 Claude: fresh-pack desktop acceptance; the global bee is stale and blocked

Wolfy found the global `~/.local/bin/bee` (built 2026-09-08) still showing
Test Status and no Hive Manager. It cannot be rebuilt: `make standalone`
validates the source and the pack step lints `bee.hive.supervisor:ingress`,
whose `message:ingress` no available runtime binary defines (all five
variants fail identically). Runtime pins, the ingress and the monitor
contracts are untouched; no reinstall script; installation follows a
verified runtime build (supervisor lane).

`tests/fresh_pack.py` (`make fresh-pack-check`, in `make desktop-check`)
proves the current pack on the pinned runtime: the quoted command
`bee-wippy run dist/bee.wapp bee` boots verbatim in a disposable directory
and exits on Ctrl+Q; Start → Tools lists Approvals, Timeline, Hive Manager,
Process Manager and Settings with no Test Status; Terminal takes input,
survives a 120×40 resize and F12 with the shell still running; a confirmed
quit exits 0 in under 0.1 s; a theme change persists across relaunch.
`docs/handoffs/FRESH_PACK_LAUNCH.md` documents the verified temporary
command, distinguishes it from the stale global bee, and records the blocker.

### 2026-09-09 Claude: resources and credentials standalone-load proof

Astra asked for an isolation proof beyond the full-source architecture
check. `tests/resources_module.py` (`make resources-module`, in `make check`)
stages two separate closures on minimal hosts: resources with `bee.persist`,
`bee.threads.records` (the pure bounds and canonical types library), the
four resource policies, a stub `bee.placement.native` ceiling (environment,
root path, `fs.directory` root, admitted roots) and a probe; credentials with
`bee.persist`, `bee.threads.records`, the credential policies, an in-memory
secret source and a probe. Each lints clean and boots; associate, grant and
resolve, and define, issue and materialize work through their public
operations; an actor under a scope without the resolve or issue policy is
refused; no desktop, terminal, harness, hive, session, applications, client,
launch or driver namespace and no placement execution entry is loaded; no
secret bytes appear in captured output. A dropped filesystem ceiling is not a
lint finding (the linker ignores a dangling requirement target) and is
refused when the operations run, naming the roots reference.

Root cause worth keeping: `funcs.new():with_scope(...)` and `with_actor`
require the action `funcs.security` on resource `security`; without it they
return `nil, err`, and a chained `:call` then reports "attempt to index a
non-table object(nil)". `funcs.new()` itself never returns nil. The probe
policy now grants it and checks the `with_scope` result.

### 2026-09-09 Claude: step 6 acceptance hardening (resources and credentials)

Astra re-scoped step 6 with a precise acceptance list. The resource authority
and credential broker were already built and Lua-tested (association ceiling,
subpath containment at association time, grant binding, every resolve refusal,
`RESOURCE_NOT_LOCAL`, epoch/revoke/expiry; broker define/issue/materialize,
scoped, bytes once, no sentinel in the registry snapshot). The named items the
Lua suites could not cover, because they need a real filesystem and a second
boot, are new in `tests/resources.py`: the `fs.directory` provider contains a
symlink escaping the root, a symlink directory and a parent traversal at open
time (the resolved root read through `fs.get`), and an association, grant and
credential definition survive a restart with no secret in an exported listing.
It runs the shipped runtime with `run` (no `wippy lint`), so it is not blocked
by `bee.hive.supervisor:ingress`; `make check` still gates it behind that lint,
and it is wired into the check recipe for when the gate clears. Symlink
containment is a property of the runtime's `os.OpenRoot`-backed `fs.directory`,
now proven end to end through the resource resolution path. Docs:
`BUILD_SEQUENCE.md` step 6, `src/resources/README.md` acceptance section. No
new migration; the persist layer is shared with threads and unchanged. Terminal
launch wiring, Docker placement and shared supervisor code were left untouched.

### 2026-09-09 Claude: subscription lifecycle correction (Astra round 51)

Astra's review removed the silent eviction: automatically forgetting closed
subscriptions beyond a bound contradicted explicit forgetting and cursor
retention. Now a closed subscription keeps its durable cursor and counts
toward the thread's subscription capacity (`MAX_THREAD_SUBSCRIPTIONS`, and the
subscribe count is over all rows, not open only); at capacity a new
subscription is refused rather than discarding resumable progress, and
capacity is reclaimed only by the owner's explicit `forget_subscription`.
`MAX_RETAINED_SUBSCRIPTIONS` and the auto-forget path are gone.
`close_subscription` is documented as a resumable delivery suspension, not a
permanent revocation; permanent removal is close then forget. A new test
proves that replaying an old `subscribe` or `resume` idempotency key returns
its historical receipt but never resurrects a forgotten row or yields a
usable stale lease (the id stays `NOT_FOUND`), and that closing counts toward
capacity while forget reclaims it (128-subscription capacity proof). A
subscription-lifecycle restart probe is added to `tests/thread_storage.py`
(cursor preserved after close and restart, resume fencing the old lease,
forgotten id absent after restart), staged behind the shared lint gate and
unverified until `bee.hive.supervisor:ingress` clears. Threads suite green,
architecture 481 source and pack, pack builds.

### 2026-09-09 Claude: durable subscription lifecycle and cleanup

Astra's handoff item: owner-authorized close/forget for abandoned
subscriptions. Two new operations on the `bee.threads:delivery` contract,
authorized by thread ownership (not by holding the subscription), strict
typed requests, idempotent replies. `close_subscription` sets `closed_at`,
retires the outstanding page and preserves the durable cursor; it is
idempotent on an already-closed or absent subscription, fences the old lease
(a late `page` is `INVALID_STATE`, a late `ack_page` finds no outstanding
page), and the consumer may still `resume` from the preserved cursor.
`forget_subscription` deletes a closed subscription's row and pages,
reclaiming capacity; an open subscription is refused so a detach never loses
a cursor, it is idempotent on an absent id, and every later operation is
`NOT_FOUND`. Retained metadata is bounded: closing forgets the oldest closed
subscriptions beyond `MAX_RETAINED_SUBSCRIPTIONS` (64). Thread records and
recipient obligations keep their owners; only subscription rows and pages are
touched. No migration: `closed_at` and `created_at` already exist. The names
are `close_subscription`/`forget_subscription`, distinct from the thread
service's `close`, so the test harness's bare-name routing does not collide.

Proofs, pinned runtime:
`tests/lua/threads/subscription_lifecycle_test.lua` (owner close with cursor
preservation and lease fencing, resume from the preserved cursor, forget as
explicit and terminal, idempotent replies, retry replay under one key,
non-owner denial, and the retained bound forgetting the oldest closed).
Every Lua suite 411 of 412 (the one failure is
`bee.hive.supervisor:supervisor_test`, supervisor lane), architecture 481
entries source and pack, pack builds, lint clean apart from
`bee.hive.supervisor:ingress`. Populated-store upgrade and cross-process
restart are `tests/thread_storage.py`'s domain, which stays blocked for
everyone by the pinned lint failing on `bee.hive.supervisor:ingress`; the
migration ledger is unchanged since no migration was added, and resume after
close proves the cursor persists in the store.

### 2026-09-09 Claude: status reader contract tightenings (Astra round 49)

Astra's contract review applied. Generation now covers owner replacement as
well as thread switch: a changed `owner_authority` advances the generation
so a delayed reply from the previous authority is fenced and cannot switch
the reader back (proven by a same-thread owner-replacement test with a
delayed old-owner read). Incarnation, revision and sequence compare only
within one authority. The client value carries `generation`,
`owner_authority` and `owner_incarnation` so the session rejects a stale
session-update. The change-wait now watches past the last observed head
(register-then-recheck), not the fold cursor. The unbound availability is
named `unbound`, distinct from a ready value whose activity is idle.
`STATUS_SURFACE.md` states that `funcs.call` grants do not establish
membership (the owner checks it every call), that `status_update` writes only
through the bounded owner operation and the reader has no direct storage or
arbitrary checkpoint-write authority, and that the session's I/O is
client-owned and asynchronous so the shared event loop never blocks on a
watch or projection call, with teardown cancelling the watch and fencing late
completions. Suites and gates green on the pinned runtime as before.

### 2026-09-09 Claude: typed status reader; status-surface handoff

`bee.application:status_reader`, the client-side half of the status surface:
a pure state machine that drives the thread owner's status projection and
hands the shell presentation values, performing no I/O itself. It emits
`update_intent`/`read_intent`/`watch_intent`, the owning session calls them,
and the reader applies replies under a generation that fences a superseded
binding. It advances through the bounded `status_update`, derives the
caller's status through `status_read`, rechecks through the read-only
`watch` (a wakeup hint only, coalesced), resets on a replacement
`owner_authority`, ignores a reply behind its revision, publishes `stale`
and schedules one more bounded refresh when a bounded update stops short of
the head, and shows an unreachable or refused owner as `unavailable` with
the last status retained, never as `idle`. The projection engine read now
carries `owner_authority` and `owner_incarnation` so the reader can fence a
replacement owner. `docs/handoffs/STATUS_SURFACE.md` names the exact
boundary, the typed value the presenter renders, the session's authorization
(funcs.call on status_read/status_update/watch, no writes), the lifecycle
and cancellation rules, and the acceptance checks, so the shell lane can wire
it without touching this half.

Proofs, pinned runtime: `tests/lua/status_reader/model_test.lua` and
`surface_test.lua` (against the real owner, zero delivery marks written),
every Lua suite 409 of 410 (the one failure is
`bee.hive.supervisor:supervisor_test`, supervisor lane), architecture 479
entries source and pack, pack builds, lint clean apart from
`bee.hive.supervisor:ingress`. Astra keeps runtime cutover, native monitor
delivery and public launch wiring; the shell surface stays with the lane
that owns client/session and presenter files.

### 2026-09-09 Claude: status projection on the thread owner (build step 10)

Astra's round 44 answer: the status surface reads a projection on the
thread owner, independent of the recap. Built `bee.threads.projection:status`
(`status_read`/`status_update`/`status_rebuild`, contract methods and
`projection_local` binding, projection client policy). To avoid a parallel
implementation the read/fold/round/revision-fence machinery is now a shared
`bee.threads.projection:engine` parameterized by a fold spec; recap is
refactored onto it (its fold and empty checkpoint unchanged) and status is a
second spec, each keeping its own schema (`bee.status@1`), cursor and
revision. The fold keeps neutral recorded facts: open actions (a started
attempt with no recorded end is "running", recorded state, not liveness),
open requests with their target identities, pending approvals by id, the
last turn or receipt outcome. `status_read` derives the caller's own
relationship (activity, `waiting_on_you` with the message ids where the
caller is a recipient, a `stale` flag when the projection is behind the
head) without persisting it; one viewer's relationship is never stored as
thread-wide status, and a pending approval is counted without any claim
about who may decide it. `status_test` proves the fold, the per-caller
derivation, a rebuild equal to the incremental fold, a stale/uncertain
derivation and the owner-only rebuild. `bee.threads:capabilities` lists the
three status methods (projection now six methods).

Uncertainty is per action, not thread-wide (Astra round 47): the fold marks
an action `uncertain` in its own `actions` entry from that action's turn.end
or receipt, clears it only when the same action starts a new attempt or
settles with a non-uncertain outcome, and never touches another action; a
two-action proof holds A uncertain while B starts and succeeds.
`status_read` surfaces `uncertain` over `running` so an unresolved outcome is
never hidden, and reports `uncertain_actions`.

The shell surface itself (bar button, window title, collapsed recap) reads
this projection and hands the presenter values; it touches shared
client/session and presenter code, so it is deferred pending coordination
with that lane rather than built here.

Gates, pinned runtime: every Lua suite through the scratch runner, 409 of
410 (the one failure is `bee.hive.supervisor:supervisor_test`, supervisor
lane); architecture 478 entries source and pack; timeline and threads
together, pack, lint clean apart from the supervisor lane's
`bee.hive.supervisor:ingress`.

### 2026-09-09 Claude: read-only thread viewing (Astra round 44 corrections)

Astra's round 44 flagged that the Timeline's `wait` claims obligations: a
read surface mutating delivery state. Fixed at the cause. New owner
operation `bee.threads.delivery:watch` (contract method `watch`,
`watch_method.lua`, `waits.watch`): a bounded, read-only change-wait that
checks only whether the head moved past a cursor and registers with the
same waiter; it claims nothing, writes nothing, and notifies no waiter
(not a mutation). The Timeline uses `watch` in place of `wait` and holds
`unsubscribe` again, closing only its own subscription and only when it
leaves a thread, so a presenter reload still resumes. The surface test now
addresses a request to the viewer and proves its pending obligation, the
delivery-mark records and the claim batches are all unchanged after
listing, reading, paging, acknowledging and watching. The model proves the
crash-gap contract: a checkpoint after acknowledgment but before the rows
are persisted resumes past the acknowledged cursor and shows the unsaved
rows as a bounded gap, never as seen. `APPLICATION_CONTRACTS.md` documents
read-only viewing, the acknowledgment meaning and subscription closure.
`bee.threads:capabilities` lists `watch` (delivery now 13 methods).

Gates, pinned runtime: timeline and threads suites together, timeline and
inbox smokes, architecture 473 entries source and pack, lint clean apart
from the supervisor lane's `bee.hive.supervisor:ingress`. Pending in the
threads/owner lane, per Astra: the owner bounds a durable subscription an
app abandons (a TTL), and a status projection kind is the next surface.

### 2026-09-09 Claude: Timeline (build step 10), Hive Manager amendments, Test Status removed

Astra's round 43 amendments applied to the Hive Manager directory: a catalog
carries the owner generation it was read under and an attach names it and its
own idempotency key; the fixture owner refuses a stale generation (CONFLICT),
replays an identical key with the recorded outcome and refuses a reused key
with different input; an `UNCERTAIN` outcome keeps the intent pending and the
next action replays it; the node list stays within 64 by dropping the
earliest departed node first and the selected one last.

`bee.timeline:app` (Start, Tools) reads a thread through the owner's
subscription: `list`/`get`, `subscribe` from 0 or `resume` of the remembered
subscription, one outstanding `page` at a time acknowledged by identity and
exact extent after it is folded, a bounded `wait` (limit 1, claims nothing
for the viewer) as the reason to page again, `recap_read` for the stored
recap. `bee.threads.delivery:session` holds the cursor semantics: a page
under an older lease is dropped, a page under a newer lease fences the
session (resume required), a CONFLICT on acknowledgment asks for resume, a
forgotten subscription subscribes anew, silence detaches without moving
anything. The view holds 512 rows and marks dropped and skipped ranges;
outcomes follow the recorded outcome and an exit is never success;
approval records name Approvals as where they are decided. The app policy
names only list, get, subscribe, page, ack_page, resume, wait and
recap_read; the architecture check asserts it cannot claim, ack a
delivery, dispatch, record or unsubscribe. Shared application libraries:
`bee.application:text` (bounded display text) and `bee.application:caller`
(typed owner replies), used by the inbox, the manager and the timeline.

Test Status removed at Wolfy's direction: `src/apps/test_status`, its
policies, binding, suite, smoke, the native-binary background/replay steps
and the site simulator entry; docs now describe launch arguments,
checkpoints and independent lifetimes generically and the Timeline as the
thread reader (`APPLICATION_CONTRACTS.md`, `THREADS.md`, `README.md`,
`FOUNDATION_STATUS.md`, `NATIVE_DISTRIBUTION.md`,
`LOCAL_FOUNDATION_ACCEPTANCE.md`, `UI_REFINEMENT.md`). `make check` now runs
the inbox, Hive Manager and timeline smokes.

Proofs on the pinned runtime: every Lua suite through the scratch runner
(407 of 408; the one failure is `bee.hive.supervisor:supervisor_test`,
"no reply before the timeout", supervisor lane), timeline, hive_manager,
inbox and threads suites in isolation, `tests/tui_smoke.py`, the three app
smokes, architecture 472 entries on source and pack. `make test` and
`tests/thread_storage.py` stay blocked at the pinned lint by
`bee.hive.supervisor:ingress` (`message:ingress` has no definition in the
pinned runtime nor in `.wippy/bin/bee-wippy-events`).

### 2026-09-09 Claude: Hive Manager over a typed directory (parallel UI lane)

Astra's parallel lane: `bee.hive_manager:app` under Start, Tools. It reads
through one typed directory (`bee.hive_manager:directory`). The live form
asks runtime membership (`system.cluster.members`, this node always
present) and this node's supervisor for `bee.hive.telemetry:presence` and
`stats` per member through `bee.hive:client`; it refuses desktop listing and
attachment locally with the reason (native client admission with an owner
execution, supervisor lane) and calls nobody for them. The fixture form
replays a strict host-admitted table (`bee.hive_manager:fixture`), selected
only by `bee.hive_manager:source` `kind: fixture`, and the frame names the
fixture on every draw; production ships `kind: live` (architecture
assertion). A node that leaves membership stays listed as unavailable. A
missing supervisor shows "Hive is not enabled in this profile" and the app
enables nothing. Control is offered only where no controller is known,
observation always; both are confirmed through the shell and answered as
the owner said. Friendly names come from `bee.hive_node_names` as display
aliases. `bee.application:text` now holds the bounded display text the
inbox and the manager share.

Proofs: `tests/lua/hive_manager` (directory, model, frame), the smoke
`tests/hive_manager_app.py` (live path in the local profile), inbox suite
and smoke unchanged, architecture on source and pack (475 entries).
`make test` is blocked by the supervisor lane's `bee.hive.supervisor:ingress`
failing the pinned lint (`message:ingress` is not in the pinned runtime's
definitions); the Hive Manager suites pass in isolation with the pinned
runtime.

### 2026-09-09 Claude: destination admission handed back; uncertainty machine-readable

Astra's round 41 closes the lane's destination work. A route expiring
after dispatch and a reply above the output bound now answer the
`UNCERTAIN` fault carrying `{operation_ref, idempotency_key}`, decoded
strictly and allowed on no other code, so retry behavior follows the code
and identity, never prose; `DEADLINE_EXCEEDED` is refusal before dispatch
only. The final destination-admission state is in `docs/HIVE_SUPERVISOR.md`
("Destination admission handoff"): operation ids, policies, the mapping
shape and encoding, the verified-ingress requirements and the missing
stable-subject boundary, passing proofs apart from the pending
supervisor-process and two-runtime ones, the files changed in the
supervisor lane, commands and capability flags (cross-node send and
approvals stay false). Cross-node thread and approval capabilities remain
false; forwarding, originating-actor establishment and two-runtime
acceptance stay with the supervisor lane.

### Root checkpoint — local admission implementation started (2026-09-08)

Physical `Run` now preserves worker failure after connection EOF; the real PTY
peer-close test requires `ErrUncertainDelivery`. `physical-client-check` passes
race/vet (`/tmp/bee-physical-outcome-final.log`, 1.019s). Intentional local detach
can also report uncertainty for an operation already pending; no automatic replay.

Agy `gemini-3.8-flash-high` is running session `49917` in isolated
`/tmp/bee-local-admission`, implementing `client/local`. Prompt:
`/tmp/bee-local-admission-task.txt`; log `/tmp/bee-local-admission-agy.log`;
expected report `/tmp/bee-local-admission-report.md`. The candidate is a retained
loopback listener with an OS-assigned port and standard mutual TLS using a
per-run identity in a protected privatefile document. Start requires the caller
to already own the runtime application-state lock. No new lock, setup SQL or
cluster membership. It authenticates local OS-user access, not workspace rights.
Recheck the same live session before assuming completion or restarting it.

Next bridge can follow the native ioevents module's process-owned subscription
cleanup pattern: perform accepted-connection work off the scheduler, create the
viewport with the actual caller frame, and return a local one-shot producer
grant to the trusted supervisor. Do not invent a PID or accept process/grant/
policy choices from the physical wire. Public launcher, automatic profile
allocation and two real OS Bee clients remain incomplete.

### Root checkpoint — display owner lane and integration fixture (2026-09-08)

Agy local-admission session `49917` remains live; initial source exists but is
not final. Review Dial's default timeout and Accept worker teardown/ownership
transfer before accepting the result. Independent Agy session `33518` is writing
`client/owner` in `/tmp/bee-display-owner`; prompt
`/tmp/bee-display-owner-task.txt`, log `/tmp/bee-display-owner-agy.log`, report
`/tmp/bee-display-owner-report.md`. It must inject an admitted Acceptor, create
viewports using real Lua caller frames, require exact `bee.local.accept` scope,
and bind cancellation/close events to process subscriptions. No wire-selected
PID, source, policy or grant.

Root drafted `/tmp/bee-local-client-fixture/main.lua` and `_index.yaml` for a
retained Bee host plus two actual desktops. It uses local attachment grants,
separate fixture databases, initial admission, F12 renderer selection and
save/detach on physical close. Not linted or integrated: needs the module's
Attachment type, bounded waits/error handling and the actual Go boot harness.
Use it as a draft, not evidence of the two-process acceptance gate. Both Agy
sessions were polled live; preserve handles rather than restarting on timeout.

### Root milestone — local rendezvous integrated (2026-09-08)

Agy local-admission `49917` completed exit 0. Root review snapshot is
`/tmp/bee-local-admission-root`; integrated package is `native/client/local`.
Root corrected queued socket cleanup after Accept, cancellation before handoff,
TLS abort without a graceful write, handshake slots before goroutine spawn,
Dial's five-second default bound, full key-usage checks and per-run certificate
validity (ten years, replacing the unintended one-day admission cutoff).
Removed unused credential copies. Root tests cover TLS verification at +48h
and a nonresponsive peer with no caller deadline.

`make -C native check local-client-windows-check` passes:
`/tmp/bee-local-integrated-check.log`, local race tests 6.706s. Windows evidence
is compilation/vet, not execution. No public caller: runtime state-lock ownership
remains a caller prerequisite, and workspace rights remain supervisor-selected.

Owner Agy session `33518` remains live with source now present in
`/tmp/bee-display-owner/client/owner`. Next review its Manager.Stop/wait accounting,
actual frame ownership and subscription cleanup, then build the real Lua fixture
at `/tmp/bee-local-client-fixture`. Do not claim that fixture has run yet.

### Root milestone — native display owner passes (2026-09-08)

Journal seq127. Agy owner session33518 completed; `native/client/owner` is
integrated. `make -C native display-owner-check` passes race/vet (1.145s).
Its capacity test now closes exactly one attachment: concurrent accept order
cannot associate attachment and socket slice indices. Pending accept cleanup
and manager shutdown tests pass. The real Lua fixture remains a separate gate.

Candidate `/tmp/bee-local-desktop-proof` built against
`/tmp/bee-physical-runtime-root`, with the unapplied input-reader extension.
Agy fixture session68951 failed because headless command permission was denied;
replacement session33555 is refining `/tmp/bee-local-client-fixture`, scoped to
that directory. Log `/tmp/bee-fixture-agy-retry.log`. Root staged current source
and disposable databases at `/tmp/bee-local-desktop-stage`.

Baseline strict lint found `bee.approvals:service:49` cannot return Result,
expected Result. Shared approvals source is untouched; the staging copy alone
passes the optional value directly to transaction.failure instead of mutating
its return. The finding is recorded for that lane's owner. This distinction
must remain in any acceptance report.

### Root correction — align physical clients with runtime transport (2026-09-08)

User explicitly challenged the Bee-specific TLS side path and asked that shared
runtime behavior be implemented universally in the runtime, coordinated with
the existing TLS/transport lane. Public integration of `native/client/local`,
its connection wrapper and the dependent two-process fixture is paused. None
is selected by the public build. Existing package tests remain mechanism evidence,
not architectural approval. Do not extend this into separate Hive enrollment.

The wrapper's regression demonstrates that TLS Close may wait for close_notify
when the authenticated peer stops reading. `make -C native check
local-client-windows-check` passed in `/tmp/bee-local-abort-check.log`; the wrapper
is experimental Bee code, not an upstream fix. Runtime inspection shows
`cluster/internode/connection.go` NodeConnection.Close cancels then delegates to
its net.Conn.Close; that alone does not establish a TLS bug in the mesh. The
reviewed runtime snapshot also contains native TrustController work. Coordinate
with the transport owner before modifying either.

Required alignment: runtime owns connections, authentication and termination;
Bee owns supervisor-selected desktop/profile admission and presentation. Keep
local-only startup, independent physical clients, retained application state,
no competing database writer, bounded input and honest uncertain outcomes.
Confirm the native thin-client attachment API and its shutdown contract; do not
assume that each physical client needs cluster membership or a full runtime.

Correction to the previous staging note: passing a third argument to the linked
transaction.failure did not lint either. A literal Result in the disposable
approvals helper also failed. Shared approvals source remains untouched; the
staging fixture has NOT passed strict lint. No desktop acceptance is claimed.

### Root validation correction — current strict lint passes (2026-09-08)

Journal seq129. `make lint` using the current `.wippy/bin/bee-wippy` passes all
241 entries (`/tmp/bee-current-source-lint.log`). The earlier approvals error
belongs to the experimental runtime/staged source combination; it is not proof
of a defect under the current repository toolchain. Do not fix shared approvals
based solely on that candidate result. Local acceptance documentation now
explicitly distinguishes same-runtime client actors from separate ordinary Bee
processes and fixture-selected remote desktop admission from public discovery.

### Runtime lane ownership handoff (2026-09-08)

Wolfden journal seq130, event `2fe04be9-e3ae-4b75-90be-acc72ba24e3a`.
Per user instruction, the runtime cluster-hardening lane is primary for generic
cluster/naming, mesh/session transport, and shared TLS lifecycle fixes. Its
worktree is `/tmp/wippy-cluster-hardening`; recovery notes are
`CLUSTER_MARKER_LAYOUT.md` and `CLUSTER_TOPOLOGY_PROTOCOL.md`.

Bee should preserve its experimental local transport and regression tests, keep
separate TLS sidecar integration paused, and continue desktop/profile admission,
display ownership/presentation, and transport-independent fixtures. Report missing
native thin-client capabilities and transport repros to the runtime lane. No
assumption that physical clients must join cluster membership. Runtime TLS abort
behavior remains to be verified; the private remote-monitor stack is not boot
enabled and is not a consumer cutover target yet. Acknowledgement of this division
and identification of any other active transport owner were requested in Wolfden;
this entry does not assert that acknowledgement has arrived.

### Root milestone — current suite and shared TLS location (2026-09-08)

`make test` passes 295 tests in 32.8s, log
`/tmp/bee-current-unit-check.log`. This is the Makefile-selected Wippy runner;
not the experimental physical-client executable. Full source/pack acceptance
was not repeated for these documentation changes.

Runtime transport review location: `cluster/internode/manager.go` contains
ManagerTLSConfig and TLS client/server handshake paths; connection lifetime
ends through `cluster/internode/connection.go` NodeConnection.Close. The
transport owner can evaluate shared abort semantics there. Root has not changed
that lane. Search of public build configuration, src and runtime patches finds
no selection of the experimental localdisplay/client packages.

### Root milestone — durable desktop after abrupt client loss (2026-09-08)

Journal seq133 records the requested node-owned named desktop model in
`docs/CLIENT_STATE.md`: distinguish durable desktop, transient attachment and
qualified application target; sole desktop writer; fresh grants on rejoin;
no centralized Hive database. Public naming/selection remains unimplemented.

Seq136: `make client-desktop-check` passes source and pack for independent and
workspace appearance. The fixture now forcibly terminates a client without a
save/quit handshake, waits for EXIT, then starts a same-store replacement and
checks stable client identity, same application view/instance and live shell
state. This is an actor-loss proof; it does not claim separate physical-process
admission. Log `/tmp/bee-desktop-abrupt-rejoin.log`. Disposable hosts now create
.wippy for optional subsystem default stores; no user databases are touched.

Runtime seq135 reports before/after reproduction and a shared TLS abort fix in
`/tmp/wippy-cluster-hardening`, with focused race tests passing and broader
checks pending. Consumer attachment contract remains unresolved; no Bee cutover.
Agy fixture session33555 completed exit 0; its output remains in
`/tmp/bee-local-client-fixture` and is not integrated. Its report claims lint but
root has not independently verified that result. It still uses detach mode while
sending supervisor-only save controls and requires correction if ever reused.

### Root readiness boundary — legacy import is explicit (2026-09-08)

Journal seq137. `bee.launch:protocol.ready(value, workspace_id, require_import)`
now validates the same desktop-ready message for both legacy migration and plain
attachment. The existing local supervisor passes true; its durable import gate
is preserved. The actual desktop fixture uses true for its legacy-offer client
and false for the other, retaining valid client identity and rejecting missing
or malformed receipts in both modes. No schema or transport change.

`make lint test client-desktop-check` completed exit 0: strict lint, 296 tests,
and source/pack desktop acceptance in both appearance modes, including abrupt
client loss/rejoin. Log `/tmp/bee-client-readiness-check.log`.
Full `make check` is now running; inspect `/tmp/bee-readiness-full-check.log`
and poll its live session before claiming full acceptance. The paused Agy
localdisplay fixture still uses the old two-argument decoder and is not selected.

### Root full-gate failure — approvals lane (2026-09-08)

Journal seq138. Full make check session47507 ended exit2 at make test:
293 passed, 3 failed. `/tmp/bee-readiness-full-check.clean.log` preserves readable
errors: approvals expiry/withdraw/consume reported UNAVAILABLE authority not
established; worker projection reported DENIED thread authority refused; crash
outbox replay reported DENIED caller not a thread member. The earlier focused
296-test run passed. Approvals lane has the exact report; root has not edited
its source or weakened the failing gate.

Focused normal local-launcher acceptance is being run separately so the changed
local readiness caller is checked even while full-suite ownership failures are
investigated. This does not replace or satisfy the failing full gate.

### Root fixture isolation — all node-owned stores (2026-09-08)

Journal seq139. `make local-launcher-check` initially failed during startup:
new approvals store used a missing .wippy directory. The shared PTY Desktop
helper now supplies explicit disposable DB paths for workspace, threads,
approvals, resources, credentials and placement. This also prevents source
fixtures from falling back to stores under their project working directory.
It changes test isolation only. Session21527 is running the retry; log
`/tmp/bee-readiness-local-launcher.log`. Source/pack public legacy migration has
already passed, but await the complete result before claiming the whole target.

Local launcher session21527 completed exit 0. The full focused source/pack target
passes: public migration, aliases/arguments, appearance, F12, manual recovery,
client/presenter failure paths, failed/stalled startup and bounded cleanup.
Log `/tmp/bee-readiness-local-launcher.log`. This validates the unchanged local
required-import gate after the shared decoder change. Full make check still
requires resolution of the three approvals cases in seq138.

### Root observer candidate (2026-09-08)

Journal seq141/142. Native TTY already splits Observe/Input/Resize. Bee's current
attachment helper issues all three and replaces the prior controller; host render
admission requires control. Public observer presentation is not implemented.
Agy session74788, gemini-3.8-flash-high, is writing ONLY an isolated src/tests
copy in `/tmp/bee-observer-admission`; no shared/native/runtime changes.
Log `/tmp/bee-observer-admission-agy.log`; expected report
`/tmp/bee-observer-admission-report.md`.

Root review gates `/tmp/bee-observer-review-checklist.md` cover controller-mount
leakage through broker identified(), observer generation fences, bounded observer
cleanup/revocation, presentation resize behavior, appearance authority and
owner-derived rights. Do not integrate merely because a direct mount test passes.

### Root full-gate retry after approvals update (2026-09-08)

Journal seq143 records approvals owner corrections and new evidence. Root
started a fresh full make check against current source, session4986, log
`/tmp/bee-readiness-full-check-after-approvals.log`. The unit and thread checks
have passed; the full gate is still running. This is not the failed earlier
session47507. Poll the live handle rather than rerunning on observation timeout.
Observer candidate session74788 remains active and isolated; shared source has
not gained observer admission yet.

### Root full-gate toolchain check (2026-09-08)

Full session4986 ended at packed headless startup after 304/304 unit tests,
threads, isolated module and pack passed. Source headless passed; packed launch
requested bee:workers but runtime started bee.launch:headless on bee:terminal.
The selected .wippy/bin/bee-wippy predates current runtime patches (Sep8 14:02).

Journal seq145: building the exact current manifest toolchain to a TEMPORARY
output via `make native-tools NATIVE_WIPPY=/tmp/bee-validation-toolchain`.
Live session84783, log `/tmp/bee-validation-toolchain-build.log`. Pinned checkout
and module verification completed; build still pending. Once complete, run
`make headless-check WIPPY=/tmp/bee-validation-toolchain` before attributing the
failure to current runtime source. No public binary/manifest changes or gate
relaxation. Observer Agy session74788 remains live and isolated.

Journal seq146: fresh toolchain build session84783 completed exit 0. Headless
session86516 passes source and pack with /tmp/bee-validation-toolchain. The old
executable caused the packed host-selection failure; current manifest behavior
is correct for that gate. Full make check with the fresh temp toolchain is now
session99996, log `/tmp/bee-full-current-toolchain.log`. Public executable and
manifest remain unchanged. Poll this session next; do not repeat either build
or headless proof unless new evidence warrants it.

### Root shared-tree consistency and observer review (2026-09-08)

Journal seq147: fresh-toolchain full session99996 passed 304 tests, then later
boot saw a permission-adapter source edit made during the run and failed parsing
its multi-local annotation at line119. Owner has exact error. Next full gate
should use a frozen source snapshot, not mix test evidence across live edits.

Observer session74788 has now written candidate code. Root found
attachment.remove_observer and clear_observers dropping records despite failed
revocation; that loses retryable authority ownership. Written to candidate
ROOT_REVIEW.md and /tmp/bee-observer-review-checklist.md. Keep candidate isolated
until corrected and proved through actual host/broker/presenter acceptance.

### Frozen validation result (2026-09-08)

Session40591 ended at test-composition lint. Production 245 entries lint clean;
new permission tests contain five strict type errors (journal seq149):
acceptance_test feed chunk any; allow/deny returns any in three callbacks;
permission_test pending array inferred unknown. Owner has exact locations.
`/tmp/bee-frozen-full-check.log` and frozen validation-inputs.json preserve the
reproduction. Do not turn this into a broad production-lint failure or claim
full acceptance. Observer session74788 remains active, nearing its configured
15-minute print bound; no final report or integration. In-progress broker diff
currently contains only a diagnostic comment; attachment/protocol code remains
partial and must not be copied into shared source.

### Root observer implementation copy (2026-09-08)

Agy CLI session74788 returned exit 0 at its 15-minute print bound with partial
output and turn still in progress; no report exists. Do not treat this as a
completed implementation or assume its remote worker stopped. Preserve that
scratch directory. Root works separately in `/tmp/bee-observer-root`.

Journal seq151: root candidate adds owner-derived observer rights, bounded
per-instance observer maps with failed-revoke retention, exact observer mounts
in replies, observer renderer generation fences and mode-sensitive request
fingerprints. Presenter skips observed-view resizing/hardware cursor and delivery
refuses read-only input locally. Settings write routing remains controller-only.
Strict production lint passes245 entries (`/tmp/bee-observer-root-lint.log`).
Nothing integrated: next prove real host/broker observation, unaffected control,
revocation failure/retry, F12 and actual presenter behavior. No transport changes.

### Admitted observer proof (2026-09-08)

Root isolated candidate `/tmp/bee-observer-root` passes strict fixture lint and
source/pack attachment acceptance. The first client is readmitted without control
and deliberately asks for a controlling bind; host admission clamps it to an
observer mount on the second client's existing Terminal. Native input/resize are
denied, detach invalidates snapshot/input/resize, and uniquely numbered controller
commands succeed before, during and after observation with the same shell PID.
Evidence: `/tmp/bee-observer-admitted-sequence-check.log`, exit 0.

No shared production integration or transport changes. Next gates: actual desktop
presenter observation, observer revocation failure/retry and renderer replacement,
unit/current-source reconciliation and full checks. This is same-runtime actor
acceptance, not public independent-process reconnect.

### Observer replacement and retry proof (2026-09-08)

Journal seq153: isolated candidate passes `make test` with strict lint and all
312 Wippy tests. Its initially stale harness acceptance test was updated with the
existing shared-tree owner's checked stdout decoder fix; no shared test edits.
Log: `/tmp/bee-observer-unit-current-fixture.log`.

Source/pack attachment acceptance also proves observer replacement and a failed
native revocation followed by a fresh-request retry. Failure returns no grant,
retains the old observer, and successful retry invalidates the old handle. The
controller executes new numbered commands throughout. Log:
`/tmp/bee-observer-revoke-retry-check.log`. An earlier replacement probe reused a
request ID and timed out on replay; replacement now uses distinct request IDs.

Candidate remains isolated. Actual presenter/F12 observation, detach-revocation
failure/retry, shared-tree reconciliation and full acceptance remain required.

### Observer desktop integration (2026-09-08)

Journal seq154: reviewed observer implementation is integrated into shared core,
fixtures, typed tests and ownership docs. `make attachments-check` is available.
Actual desktop source/pack acceptance passes in both appearance modes, including
observer F12, denied input, independent display dimensions and controller survival.
The real presenter probe found a stale-frame bug: delivery waited for producer
size to match an observer's window. Observers now accept fresh producer-size rows
for local clipping. Evidence: `/tmp/bee-observer-desktop-sizing-check.log`.

Failed observer detach revocation followed by retry also passes source/pack:
`/tmp/bee-observer-detach-retry-check.log`. The controller stays usable throughout.
Scoped whitespace checks pass; unrelated runtime patch context whitespace remains
untouched. Full shared-tree `make check WIPPY=/tmp/bee-validation-toolchain` is
finished with exit 2 in session78057, log `/tmp/bee-observer-integrated-full-check.log`.
Production lint passed; test lint failed at `permission_carrier_test:85` with an
`any` return where `string` was required. The shared fixture has since changed
at that coordinate, so freeze and inspect current inputs before the next run.
No full-tree green claim yet. Public shared-desktop selection and runtime thin-client
attachment remain incomplete; no separate TLS transport has been enabled.

### Frozen acceptance and store isolation (2026-09-09)

Journal seq155: frozen input is `/tmp/bee-observer-frozen-validation-20260909`.
Strict lint, 317 Wippy tests, thread contracts/module isolation, packaging and
headless source/pack passed. Executable provenance matches the current manifest
and all runtime patch digests. Full run21229 then failed at packed workspace-hosts
because newer subsystem stores used missing default directories.

`tests/workspace_hosts.go` now supplies disposable paths for all six subsystem
stores; focused gate74530 passes source/pack. The resumed run18708 found the same
setup issue in storage acceptance. Python fixtures now share
`tests/workspace.py::database_environment`; storage, thread_storage, lifecycle,
client_desktop and tui_smoke use it. Explicit client/migration paths are preserved.
No production database or schema changes. Controlled snapshot hashes are recorded
in `validation-inputs-after-store-environment.json`.

Remaining acceptance is running in session16827, log
`/tmp/bee-observer-frozen-acceptance-stores.log`. Previously passing prerequisites
were marked old to resume the Makefile recipe. No full-suite green claim yet.

### Desktop acceptance continuation (2026-09-09)

Journal seq156: session16827 completed storage, client storage and thread storage,
then failed Process Manager's assumption that Settings fits in the first visible
rows. The fixture now navigates Home/Down with a bound before selecting Settings.
Focused source/pack Process Manager checks pass (`/tmp/bee-process-manager-scroll-check.log`).

`make desktop-check` now contains the existing desktop acceptance recipes, and
`make check` invokes it after storage; no tests were omitted. The authoritative
frozen desktop run is session40840 in `/tmp/bee-observer-frozen-validation-20260909`,
log `/tmp/bee-observer-frozen-desktop-check.log`. Hash ledger:
`validation-inputs-after-scroll-fix.json`. An earlier accidental shared-directory
invocation17963 was explicitly interrupted and exited2; its log is
`/tmp/bee-observer-shared-desktop-aborted.log`, not passing evidence.
Full acceptance remains incomplete until the frozen run finishes.

### Frozen UI progress (2026-09-09)

Journal seq158: session40840 remains active. Source/pack UI smoke passes empty
boot, Process Manager protection and scoped ending, input isolation, geometry,
colors, six presenter rejoins and crash recovery. Normal exits measured 34–50 ms
in this fixture. Taskbar source/pack persistence/F12/cold restore also passed.
The run is now on personalization; continue polling the same session and log.

Two shared inputs have changed since freezing: `src/placement/native/service.lua`
and `tests/lua/placement/native_test.lua`, for runner-liveness reconciliation.
Keep that delta separate from the frozen proof and reconcile it before claiming
current-tree acceptance. No new input files were found.

### Placement delta and dialog gates (2026-09-09)

The two placement changes from owner seq157 were staged over the frozen input in
`/tmp/bee-placement-reconciled-validation-20260909`. Session67811 exited0:
strict lint and all 318 Wippy tests pass. Log:
`/tmp/bee-placement-reconciled-check.log`; ledger `validation-inputs-reconciled.json`.

Original frozen desktop session40840 continues. Personalization, authenticated
titles, dialogs and close-confirmation checks passed; current step is control
message delivery failure injection. Full acceptance remains unfinished. Focused
Makefile targets are now documented in DEVELOPMENT.md.

### Runtime/Bee ownership reconfirmed (2026-09-09)

Journal seq161 reconfirms seq130/132: the runtime lane owns generalized cluster,
naming, native mesh and shared TLS lifecycle in `/tmp/wippy-cluster-hardening`.
Bee continues desktop/profile admission, presentation, observer/controller
behavior and consumer fixtures. Keep the separate local TLS sidecar integration
paused and preserve its existing work. Report transport requirements here; do not
implement a second transport fix. Shared TLS abort fix is tested (seq135), but
the generalized thin-client attachment contract remains unresolved. No private
monitor activation or consumer cutover is authorized by this handoff.

### Control-delivery acceptance progress (2026-09-09)

Session40840 remains live. Structural delivery failures, ordinary command
failures and workspace targeting now pass in source and pack. Recovery survives
rejected control messages; normal command failures preserve running apps and
allow explicit retry; both boundaries reject missing/foreign targets. Drag
failure releases capture and pointer navigation works afterward.
Current step is `tests/console.py` in the same frozen desktop run.
No staging, commit or push was performed; shared branch remains main at722729c.

### Frozen foundation gates complete (2026-09-09)

Journal seq164: desktop session40840 exited0. Every `make check` gate passed for
the frozen observer checkpoint across the initial run, focused fixture repairs
and resumed recipes. Logs and controlled hashes are preserved in the snapshot.
Final gates prove native Terminal behavior, 16-app lifecycle, observer/client
recovery, local launch, cold recovery and Test Status background completion/replay.
This is not a current-shared-tree or uninterrupted-run claim; later harness and
placement changes remain outside this checkpoint.

Standalone assembly is separate at `/tmp/bee-observer-standalone-20260909`.
Fresh bootstrap could not fetch builder commit fe458f77. Its existing local cache
was verified at the exact commit with a clean checkout and copied to the isolated
build; normal bootstrap revalidates it. Build session44071 is active, log
`/tmp/bee-observer-standalone-cached-build.log`. Runtime source fetched and modules
verified. Binary acceptance and fresh-builder availability remain pending.
No shared manifest, global installation or transport changes were made.

Standalone update: session44071 has ended with exit2. Embedded validation rejects
`module bee/bee declares multiple namespaces: bee and bee.approvals` at link stage.
Source/pack acceptance does not prove installed module composition. Correct the
package/module boundary or upstream linking behavior; do not strip definitions
just to pass validation. Shared manifest remains untouched.

### Standalone composition probe passes (2026-09-09)

Journal seq166: isolated 27-root bundle passes the standard native binary checks
(session81895, `/tmp/bee-split-native-owned-state-check.log`). The existing builder
supports multiple embedded packs; source partitioning preserves declarations and
entry IDs. Native state mappings must include approvals, resources, credentials,
placement databases and the placement directory as well as workspace/threads.
The shared build has not adopted this experimental composition.

See [the standalone composition handoff](STANDALONE_MODULE_COMPOSITION.md) for
artifacts, reproducibility limits and required adoption work. No runtime linker
relaxation, shared manifest change, global install or publication occurred.

### Split-bundle registry preservation (2026-09-09)

Actual installed binary and source agree on all 431 entry IDs, kinds and full
payloads. Only absent top-level metadata is normalized from null to an empty map.
Every installed entry also has its expected owner across exactly 27 modules.
Evidence and hash artifacts are detailed in STANDALONE_MODULE_COMPOSITION.md.
Independent component installation and adoption of the experimental build shape
remain separate gates; the shared manifest is unchanged.

### Available builder pin adopted (2026-09-09)

`build/builder.lock.json` now pins public commit
70acb10175fbeb42a3a4d382677715a0c2a969e4. Its build implementation, CLI, go.mod and
go.sum match the unavailable fe458f77 pin exactly. Fresh HTTPS bootstrap and the
split standalone native acceptance passed in session38786; log
`/tmp/bee-published-builder-standalone-check.log`. The fresh-builder fetch issue
is resolved. Newer Builder removes patch support and is not compatible with the
current runtime manifest. Application pack composition remains an isolated probe;
no shared application manifest or global installation changed.

### Default lint restored; runtime cache reproduction (2026-09-09)

The broker's `expected tty.Viewport, got tty.Viewport` errors were reproduced
by transplanting the preserved checkout cache into otherwise passing current
source. Rebuilding the toolchain alone did not fix them. After preserving that
cache, `make lint LINT_FLAGS=--cache-reset` and ordinary warm `make lint` both
pass all 249 entries. Strict types remain on; no broker casts or lint bypass.
`make setup` also refreshed the local development binary from the current manifest.

See [the cache reproduction](LUA_CACHE_TYPE_IDENTITY.md) for exact artifacts.
The runtime defect remains to be diagnosed; reset is local recovery, not a
permanent unconditional build workaround.

### Standalone state isolation strengthened (2026-09-09)

The native acceptance fixture now isolates all subsystem database overrides and
the placement root, and checks initialized SQLite files for six subsystem stores
plus client layout under `--state-dir`. The isolated split binary passes normal
acceptance and a run with deliberately unusable inherited state paths. See
[standalone composition](STANDALONE_MODULE_COMPOSITION.md) for logs and the
remaining shared-build adoption boundary. Runtime override semantics and the
shared application manifest are unchanged.

### Shared standalone state defaults adopted (journal 173, 2026-09-09)

`wippy.build.json` now carries the isolated binary's proven database and placement
root mappings. The bootstrap race tests and vet pass. Installed pack composition
remains unchanged and unresolved. `docs/NATIVE_DISTRIBUTION.md` now states that
limitation instead of claiming the current source declares only one module root.
The component lane needs to settle actual installable roots: a child definition's
`module: threads` payload does not override the installed linker's ownership rule.

### Current-source validation boundary (2026-09-09)

Ordinary strict lint reports three type errors in the actively edited harness
carrier. `make local-launcher-check` passes public migration from source and pack
(identity, layout, F12, import receipt and unchanged ledger), then stops at its
fresh fixture lint with the same three carrier errors. This reproduces outside
the shared cache; do not treat it as the earlier native viewport cache defect.
Logs: `/tmp/bee-current-foundation-lint.log` and
`/tmp/bee-current-local-launcher-check.log`. The remaining launcher checks did not
run; the frozen acceptance checkpoint is still separate from current-source
validation. The carrier lane retains its edits and strict typing remains enabled.

### Standalone Test Status acceptance (2026-09-09)

The expanded native binary gate passes on the frozen split executable: explicit
run arguments, view closed while unfinished, background completion, reopen, F12,
and cold restart with exactly one run and nine events. Journal reads are read-only
and limited to disposable stores. Log `/tmp/bee-native-test-status-check.log`.
Shared package composition and newer carrier validation remain separate work.

### Upstream-only committed foundation synced (2026-09-09)

`2dea2eb` is verified on `feat/independent-view-bindings`, reconciling the 22
committed host/client changes with published main `93cbc0a`. The isolated worktree
is clean. Setup, complete `make check` (115 unit tests plus source/pack gates),
standalone assembly and expanded native acceptance pass without runtime patches.
No PR or main update; shared uncommitted observer/Hive/component work is preserved
and remains outside this checkpoint. See [sync evidence](FOUNDATION_SYNC.md).

### Observer and presenter delivery synced (2026-09-09)

`57e8597` is verified on `feat/independent-view-bindings`. Full `make check`
passes with 118 unit tests and all source/pack gates; standalone build and native
acceptance also pass on the upstream-only runtime. The isolated worktree is clean.
No PR/main update and no shared dirty work replaced. Observer authority,
revocation retry and bounded asynchronous presenter delivery are now synced.
Public mesh attachment, physical-client reconnect and node-owned desktop
activation remain pending; runtime handoff request is journal 183.

### Durable layout acknowledgement fix (2026-09-09)

Successful session acknowledgements now commit their projection before the
client forwards success. The change and regression are applied to shared source
and isolated `/tmp/bee-durable-ack-20260909`. Withholding the rename scene message
fails on old code and passes on the fix, including abrupt-exit recovery.
Standalone build/acceptance pass; full validation remains live in session 40085.
See [desktop owner extraction](DESKTOP_OWNER_EXTRACTION.md) for logs and the
remaining independent owner/reconnect boundary. No commit/push yet.

### Durable layout acknowledgement synced (2026-09-09)

`a9f45e1` is verified on `feat/independent-view-bindings`. Complete `make check`
and standalone build/acceptance pass; the withheld-scene regression fails on old
code and passes on the fix. The isolated worktree is clean, and shared source
already contains the same fix. No PR/main update. Owner extraction and native
thin-client integration remain separate pending work.

### Runtime/Bee ownership reconfirmed (journal 189, 2026-09-09)

Runtime lane remains primary for generalized cluster/naming, native mesh and
shared TLS lifecycle in `/tmp/wippy-cluster-hardening`. Keep the separate
`native/client/local` TLS integration paused and preserve its experimental files.
Bee should continue node-owned desktop/session state, durable layout/restart
behavior, admission/presentation policy and consumer acceptance fixtures. Report
missing transport behavior in the journal instead of implementing a parallel path.

Response to journal 183: the public thin-client attachment contract and verified
cutover commit remain unavailable. Private runtime owner/monitor/acquisition
implementations remain unenabled. Runtime owns that boundary; Bee must not adopt
those private implementations as supported APIs. Acknowledgement requested in
journal 189; prior ownership acknowledgement at 132 remains recorded.

### Retained attachment checkpoint synced (2026-09-09)

Astra: `4a81c86067e1248f0ee8faa42ab4b68cc76f36c0` is verified on
`feat/independent-view-bindings`; no PR/main update. Full `make check` session
24361 exited 0, standalone assembly and native acceptance pass. The additional
graceful-close regression fails before the fixture fix and passes afterward in
source/pack for both appearance modes. The fixture consumes display close locally;
rejoining sees the same shell. The component grants one controller and bounded
observers without implicit mode changes. Exact reviewed source/fixture changes
are applied to the shared checkout; unrelated manifest pins are preserved.

No validation sessions remain live for this slice. Public retained desktop
activation is still pending. Reuse the existing workspace host when starting
`bee.client:main`; do not start a workspace host per display. Runtime retains
native transport ownership. Details/logs: `DESKTOP_OWNER_EXTRACTION.md`.
Wolfden checkpoint seq 203; cursor `jc_1HYZK1CTT9212` was checkpointed and rotated
at its eight-hour episode boundary.

### Retained desktop resources and runtime integration handoff (2026-09-09)

Astra: candidate `/tmp/bee-retained-desktop-20260909` at `4a81c86` adds
`bee.client:desktops`, retaining virtual desktop resources in the supervising
actor against an existing workspace host. Duplicate store bindings are rejected;
only the desktop's own observed EXIT releases its reservation and viewport.
Source/pack checks in both appearance modes, standalone assembly and native
acceptance pass. Full `make check` session 97600 remains live; see
`DESKTOP_OWNER_EXTRACTION.md` for logs. The candidate is uncommitted and is not
applied to shared production source.

Wolfden seq 206 asks the runtime lane for the supported physical-client cutover
commit/APIs: authenticated identity/admission, retained viewport access,
input/resize/projection, peer loss/detach, and second-invocation rendezvous without
opening workspace stores. The prior seq 189 handoff remains authoritative until
replaced. Native experimental adapters stay gated; no alternate listener is added.

### Retained desktop resources synced (2026-09-09)

Astra: checkpoint `9308a39c55c386ba38d9caf3a89d9389a2779171` is verified on
`feat/independent-view-bindings`. Full gate 97600, standalone build 70185 and
native acceptance 11504 exited 0. The isolated worktree is clean. Exact component,
fixture and client-state changes are applied to shared source; the independently
changed acceptance document was merged separately, and manifest pins preserved.
No PR/main update. No validation sessions remain live. See
`DESKTOP_OWNER_EXTRACTION.md` for logs and limits. Public retained supervisor and
supported physical-client attachment remain unfinished; runtime handoff request
is seq 206. This result is recorded in Wolfden checkpoint seq 207.

### Goal blocked on runtime handoff (2026-09-09)

Three consecutive audits after checkpoint `9308a39` found no supported runtime
physical-client handoff (request seq 206; audits 208–210). No validation jobs
remain running. Goal marked blocked pending that external contract/commit,
not completed. Resume with supported startup/rendezvous, authenticated attachment,
viewport/input and detach lifecycle APIs. Keep private transport candidates gated.

### Retained supervisor synced (2026-09-09)

Astra: `26594cd58418a7d8f62678170fbc91135b7b064d` is verified on
`feat/independent-view-bindings`. Full check 46789, standalone 27958 and native
acceptance 95055 passed. The private supervisor now owns host/desktop admission,
renderer changes and authenticated attachments; display EXIT revokes control
without losing the shell. Source/pack proof covers forged requests, competing
control, crash/rejoin, explicit detach/rejoin and negotiated shutdown with no
failed services. Shared code is updated; launch index was merged preserving its
headless entry and compared against verified entries. Native pins unchanged.
No PR/main update or live validation jobs. Public startup/physical-client
rendezvous remains next. Wolfden checkpoint seq 233.

### Runtime client integration ownership transferred (2026-09-09)

The user authorized Astra to take over the missing runtime implementation and
inspect the PRs in `~/wippy/wippy`. Wolfden seq 235 records this change; the
previous exclusive-owner wait is superseded. Merged #653 supplies native mesh
viewport mounts, but not physical-client startup/discovery. #668 owns the
application lock and has no second-invocation attachment callback yet.

The isolated runtime branch `feat/terminal-event-input` starts from fetched
upstream main `fdad09cef2` and extracts the existing event-input research patch.
The initial terminal service race suite and Bee physical-client consumer check
passed. The broader Lua TTY suite fails `TestSurfacePresentClearsRemovedRows`;
the identical failure was reproduced on untouched upstream main. This is not a
passing full-runtime claim. Detailed sequence and ownership:
[runtime client takeover](RUNTIME_CLIENT_TAKEOVER.md).

### Runtime client startup and listener checkpoints (2026-09-09)

Local runtime branch `feat/terminal-event-input` now contains `85736d0524`
(rebased native launch preparation), `e3aee1a13c` (attachment on owner lock
contention) and `31e4345e10` (retained automatic native mesh listeners).
Application checks/race/vet pass. Cluster/internode/boot race checks pass,
including 20 authenticated stacks on automatic ports and boot failure cleanup.
The direct boot proof reproduced a repeated-stop panic; component lifecycle
ownership now prevents it. See the takeover document for logs and remaining
discovery/client identity admission work. Public Bee is unchanged.

### Bee mesh rendezvous checkpoint (2026-09-09)

`d2b02bd` adds an unregistered native rendezvous publisher and read-only client
discovery store over the existing private-file helper. It publishes actual native
mesh endpoints, public identity and execution ID; no secret or permission grant.
The isolated native suite passes, as does live-listener/application-lock acceptance
against runtime candidate `3b9620ee31`. Evidence and limits are in
[runtime client takeover](RUNTIME_CLIENT_TAKEOVER.md). Wolfden seq 240 records the
checkpoint. Public launch and Lua entry selection remain unchanged; the next
integration is enrollment and authenticated client admission.

### Local enrollment store verified (2026-09-09)

The native rendezvous package adds per-execution local bootstrap credentials and
exact-key client registration/removal. Same-account filesystem authority grants
only transport enrollment; desktop permission still belongs to the supervisor.
The live native mesh test denies an unregistered key despite a shared gossip
secret, then connects after registration without restarting the owner. Native
race/vet and live integration pass in `/tmp/bee-mesh-rendezvous-20260909`.
See the takeover document for logs. Public CLI and crash-cleanup wiring remain
unfinished; no public automatic-attachment claim is made.

### Native physical viewport checkpoint (2026-09-09)

Bee commit `9f9b66a` removes the physical client's experimental display-transport
dependency. It consumes Wippy checked, cancellable native viewports directly,
with independent observation/input/resize rights. PTY race tests and vet pass;
a runtime viewport fixture verifies recipient denial, detach expiry and retained
content on reattachment. Evidence: `/tmp/bee-native-viewport-isolated.log`.
Wolfden seq 242 records this checkpoint. Public startup/admission and OS-process
acceptance remain unfinished. There is no user-permission or runtime-owner blocker.

### Local client process startup checkpoint (2026-09-09)

`b9a2e7b` adds gated native client startup from protected same-account enrollment.
A separate OS client authenticates with its freshly generated key, exits and cleans
its registration; the owner's application lock remains held. Startup lifetime,
stale endpoint and failure cleanup checks pass with race tests and vet. Wolfden
seq 245 records evidence and remaining work. The public CLI is unchanged. Next is
the runtime-owned process frame and supervisor admission into retained desktops.

### Native actor and physical clients verified (2026-09-09)

Bee `f31199f` composes native actor identity, bounded control inbox and TTY lifetime.
Two OS clients under PTYs render retained native content, send keys, detach and
reattach. Isolated race/vet checks pass. Fixture-selected grants remain separate
from production supervisor admission. The explicit remote-monitor check fails:
accepted monitoring yields no EXIT after target completion. Runtime dependency
requests are Wolfden seq 247–248; physical and monitor evidence is seq 253.

Runtime candidate reuses metrics PR #690 as `1b81a3d817`, extracts the shared native
surface adapter as `7334244f75`, and fixes the stale Lua shrink test as `7c999b9659`.
Relevant race tests pass; no full-runtime/CLI readiness claim. Seq 256 supplies the
TTY handoff. Journal cursor remains `jc_1HYZK1CTT9212`, rotated at seq 250–251.

Client integration checkpoint: runtime `8c2b982548` adds native cancellable
control sends from the primary runtime lane; relay/internode race and vet and
Bee actor request/reply proof pass. Local enrollment reclamation is synced as
Bee `8589596`. Wolfden seq 258 records the enrollment checkpoint; the next
integration fact records the runtime send extraction. Remote monitor ingress,
production supervisor admission, public attachment and LAN acceptance remain
open. Neither finding requires further user authorization.

### Client reply connection lifetime checkpoint (2026-09-09)

Bee `76dcd22` is synced to `feat/independent-view-bindings`. Native control
replies require a live ingress connection signal at enqueue and are checked again
at receive, preventing a queued reply from a closed connection being delivered.
The mesh/physical race suites and vet pass against runtime `ef22d02d4e`, including
actual TLS physical clients. This is not atomic session or grant fencing.
Wolfden seq 269 records the still-missing Lua ingress propagation seam; seq 270
records this verified checkpoint. Runtime ownership and public launcher gates
remain unchanged. Cursor: `jc_1HYZK1CTT9212`.

Runtime seq 271 introduced local execution-observation and service-binding
research APIs. Bee reviewed them at seq 273: their contracts explicitly do not
supply remote completion evidence or authenticate remote data, so they do not
replace the remote monitor or Lua ingress gates. No extraction performed.
Seq 272 records correction of HIVE_LAUNCH_STATE.md: obsolete sidecar candidate
sections removed, native mesh evidence and production integration gaps stated.

### Automatic local TLS credentials (2026-09-09)

Bee `d9e3b6a` adds `native/hive/localtls` and `mesh.SameAccount` in the isolated
integration tree. The native owner provisions a protected single PEM bundle per
execution; clients locate it from the execution without certificate arguments.
Each execution has fresh filenames and an independent TLS key; same-execution
retries retain identity/expiry. Native signing enrollment still identifies peers.
The returned expiry must bound owner lifetime; the client applies it to its context.
Public owner startup/renewal remain unwired. This is local-only, creates no listener,
and grants no application access.

The complete `mesh-client-check` passes race and vet for mesh, physical and localtls
against runtime `ef22d02d4e`, including two separate OS PTY clients using automatic
credentials. Evidence: `/tmp/bee-local-tls-provisioning-verified.log`. Focused store
race/vet also passes against the pinned native module runtime. Fixture directory
permission failures were fixed without weakening the private-file checks.
Wolfden seq 274 records design and initial validation. Admission/remote-monitor
runtime seams and actual first/second `bee` and LAN Terminal remain required.

### Owner startup prerequisites (2026-09-09)

Isolated runtime `ff98884382` adds strict normal-boot TLS selection using the
existing native manager. `4c6675c68d` adds lock-held `LaunchPlan.PrepareOwner`
with cleanup before lock release and an explicit execution deadline. Real boot
TLS/listener tests and full boot-system race/vet pass; application race/vet
passes with actual lock ordering, busy-attach exclusion and failure tests.
These are local runtime commits, not pushed or installed. Wolfden seq 276–279
records pre-edit coordination, behavior and evidence. The primary runtime tree
remains untouched. Bee still needs to compose the owner/admission paths; these
APIs do not prove public auto-attach or remote Terminal readiness.

### Normal owner execution lifetime (2026-09-09)

Wolfden seq 282–283: isolated normal-owner composition now passes real-process
transport expiry and lock-retention checks. Wippy preserves caller deadlines,
cleans up runner error paths, and cancels native cluster services independently
of slow supervisor drain. Networking closes before process cleanup completes;
the application lock remains held until cleanup ends. Runtime changes remain
local pending the final review checkpoint. Bee's public launcher is unchanged.
See `RUNTIME_CLIENT_TAKEOVER.md` for exact evidence and remaining admission gates.

### Runtime primary coordination boundary (2026-09-09)

Primary read Wolfden through seq283 and reaffirmed ownership in the shared journal.
Runtime primary owns cluster/naming, execution-bound locks, shared transport
primitives and load/toxic-network proof. Bee/native client lane retains isolated
native TLS boot selection, owner preparation and cancellation work announced in
seq276–283, plus admission/composition and actual consumer tests. Primary will not
duplicate those edits; exact commits and evidence need integration review.
Use native mesh/shared TLS lifecycle; do not revive the separate local TLS sidecar.
New shared defects should be coordinated before overlapping edits. The lock
adapter passes normal-build race suites but remains unwired into public boot/Lua;
cluster readiness remains unproven.

Checkpoint committed: Bee `467a060` is pushed to the integration branch; runtime
`9663ea8263` and `819c859f15` remain local for primary review. Seq 284–286
reaffirms ownership and records evidence. Next: authenticated Lua message ingress
for destination supervisor admission; shared remote-monitor correctness remains
with the runtime primary. No new Lua ingress edits are included in this checkpoint.

### Native Lua ingress checkpoint (2026-09-09)

Runtime `14ae99cebe` preserves transport evidence through queued Lua delivery and
adds typed native `process.Ingress` handles. Full engine/process race suites, vet,
strict types and the scheduler-to-Lua check pass. Bee `d3add5d` accepts bounded
native Go reply records produced by ordinary Lua sends and proves a real native
client / normal-owner Lua request-reply exchange, followed by expiry and retained
lock drain. Native mesh/physical/local-TLS race suites and vet pass. Wolfden
seq 290–291 has the exact evidence and ownership handoff. Runtime remains local
for integration review; Bee is synced by normal fast-forward on its integration
branch. Public launch is unchanged. Next: consume native ingress in the actual
Hive supervisor and authorize retained-desktop admission before auto-attachment.


### Native ingress consumer checkpoint (2026-09-09)

Wolfden Bee Harness seq 295 records the implemented supervisor consumer. Typed
message subscriptions pass strict lint; remote admission pins authenticated,
protected native connection evidence. Both actual-supervisor and native-service
TLS acceptance pass (`/tmp/bee-supervisor-native-ingress-acceptance3.log`, 26.603s).
Disposable transport certificates remain separate from native signing keys.
The shared Hive source is preserved unstaged because it belongs to the combined
lanes; do not blanket-stage it. Luna max is reviewing connection lifetime.

Isolated Bee commit `02cb03d` requires object roots in native control replies and
qualifies userdata export behavior. Focused race tests and vet pass in
`/tmp/bee-native-object-root-focused.log`; the broad run was unable to start its
PTY subprocess (`operation not permitted`), so fresh physical acceptance is not
claimed. Public `bee` auto-attach, retained production desktop grants and the
100.70.10.28 Terminal proof remain outstanding. The runtime primary owns the
terminal lifecycle forwarding gap recorded at journal seq 294.

Wolfden seq 297–299 records final supervisor/unit evidence, the packed-host
failure and its fix. Runtime local commit `699597ef70` honors `--host` in pack
launches; source/pack headless and multi-workspace acceptance pass on the candidate.
The independent Luna review failed at the provider and supplies no approval.


### Completed candidate repository acceptance

The resumed `make check` completed successfully against the raw candidate with
runtime packed-host fix `699597ef70`. Source/pack checks include multiple workspace
hosts, storage/migration integrity, journal ownership, window/Terminal behavior,
independent/retained client views, recovery and Test Status background replay.
Logs: `/tmp/bee-supervisor-native-ingress-repo-check.log` (passed prerequisites and
original packed-host failure), `/tmp/bee-runtime-pack-host-headless.log` (fixed
source/pack host proof), `/tmp/bee-supervisor-native-ingress-repo-resume.log`
(successful remainder). No installed-launcher or LAN claim follows from this.

The new isolated `native/client/hive` binds the existing Hive protocol to the
native physical actor, serializes calls, pins verified connection lifetime and
returns unknown outcomes without replay after a send. Focused race/vet and real
Lua wire exchange pass. Independent bounded review found no issues in client.go
and reply.go after Luna provider failures. Destination desktop authorization is
still required; it must use this same Hive surface and host-selected authority.


Native Hive binding commit: `6df7d0d` in the isolated Bee integration branch.
Final normal-boot wire/expiry/drain proof: 19.368s in
`/tmp/bee-native-hive-lua-wire-final.log`; focused race/vet in
`/tmp/bee-native-hive-client4.log`. Independent review found no concrete issue.
Wolfden seq 309 records full local candidate acceptance. Seq 308 asks the runtime
primary for authenticated credential evidence (or an existing equivalent) so
shared-transport desktop admission can distinguish local-client enrollment from
LAN supervisor trust. Node names or caller payload flags must not grant local
account rights. Root owns the Bee admission consumer; primary owns the runtime
identity/transport seam. Public launch remains unchanged.

Desktop bridge continuation (2026-09-09): strict lint passes after preserving
native event/message channel types through stable local bindings in the Hive
supervisor. The isolated supervisor fixture explicitly stages only the three
pure desktop interface dependencies (application arguments, application protocol,
retained protocol); it adds no desktop process, database or admission grant.
`make hive-supervisor-check` passes with the candidate runtime: actual native
supervisors and supervised service bootstrap, 31.099s. This exercises the bridge
**disabled**. Enabled desktop admission, the compiled physical client and public
auto-attach/LAN acceptance remain outstanding. Luna Max has a read-only review
of the bridge's session, receipt and revocation behavior in progress.

Follow-up unit run: 383 passed, 2 failed. Fixed local-only supervisor discovery
so distributed registration occurs only with configured peers or an enabled
desktop bridge. Fixed the retained-protocol negative test to construct a control
byte with `string.char(1)` (this Lua runtime does not support its hex escape).
Rerun: `/tmp/bee-hive-desktop-unit-check2.log`; no passing claim yet.

The corrected Wippy unit run now passes **385/385** in 114.5s. Full foundation
check is running as session 33405, log
`/tmp/bee-desktop-bridge-foundation-check.log`. The isolated Bee worktree has new
native desktop reply decoders and negative boundary tests; focused race/vet pass
in `/tmp/bee-native-desktop-decode-check2.log`. They are not committed yet.
Agy Flash owns only the new enabled-desktop fixture files under
`tests/fixtures/hive_desktop_admission/` and `tests/hive_desktop_admission_test.go`;
CLI session 45770/log `/tmp/bee-desktop-admission-agy.log`. Luna fixture attempts
failed at the provider; the separate Luna bridge review is still active.

Native desktop decoder checkpoint `5f71e89` is now FF-pushed to
`origin/feat/independent-view-bindings`. It adds no public activation or transport.
The foundation process handle is **33405** (the earlier journal entry's guessed
handle was incorrect; the log path was correct).

Foundation continuation: the full run passed its prerequisites (including the
385-test suite, pack, source/pack headless and multiple workspace hosts), then
caught the bridge's undeclared core interface import. `tests/architecture.py` now
permits only the two named bridge decoder imports and recursively requires their
closure to be libraries without runtime modules/security. Source/pack registry
checks pass at 466 entries. Remaining check recipes resumed as session 9118,
`/tmp/bee-desktop-bridge-foundation-resume.log`; no full completion claim yet.
Luna bridge review and native decoder review both failed at the provider without
findings. Local review corrected pending duplicate handling: fresh correlation
gets BUSY, same key/different input gets CONFLICT; exact original duplicate still
waits for its original completion. Strict lint passes; enabled behavior pending.
Agy CLI returned its 5-minute observation timeout with a turn still in progress;
no fixture files exist yet. Do not infer the underlying turn stopped or overwrite
its assigned files without verifying status.

Root now owns optional desktop configuration in shared `native/hive/service`:
`desktop.go`, `desktop_test.go`, `config.go`, `listener.go`, README, and the
explicit pure-interface staging in `fixture_test.go`. It carries only trusted
host input, requires the named desktop policy, copies arrays, and adds the
worker-host lifecycle dependency. Public launch remains unchanged. Native service
checks rerunning as session 88384, log
`/tmp/bee-native-service-desktop-config2.log`; the first run exposed missing pure
interface staging in this separate fixture, which was corrected.

Native service configuration race/integration/vet gate now passes (24.404s).
Agy conversation `1d3da665-7b95-4c7b-bace-e6ad8cfd9189` acknowledged stop and
reported no files or live tasks; its baseline supervisor test passed. Root took
over the fixture files and wrote `tests/hive_desktop_admission_test.go` plus
`tests/fixtures/hive_desktop_admission/`. Actual two-runtime proof targets owner
list, recipient-bound mount, Terminal command, denied foreign session and
same-shell detach/rejoin. First run caught fixture strict-type errors at boot;
fixed without casts. Second run is session 45358,
`/tmp/bee-hive-desktop-admission-second.log`. Not yet a passing attachment claim.

Enabled owner milestone: `TestHiveDesktopAdmission` passed 31.616s in
`/tmp/bee-hive-desktop-admission-fourth.log`: native name discovery, qualified
catalog, retained desktop mount, actual Terminal command, foreign-session denial,
and detach/rejoin with the same shell variable. This is a Lua client-role fixture,
not compiled/public client acceptance. UTC corrected the fixture config; startup
now surfaces supervisor failure instead of hiding it behind missing discovery.
Config decoder errors name the rejected field; strict lint passes.
Extended negative checks (stale mount, foreign workspace, observer input) run
through the new Make target as session 3333,
`/tmp/bee-hive-desktop-admission-negative.log`. Full foundation session 9118 remains
active. Owner/client connection loss, crash/rejoin and LAN are still open.

Extended enabled desktop proof passes race/vet: 31.010s,
`/tmp/bee-hive-desktop-admission-negative.log`. In addition to same-shell rejoin,
detached mounts cannot send input, foreign workspaces return NOT_FOUND, and
observer mounts retain visible content but cannot type. This remains the Lua
client-role fixture; no compiled client or public startup claim.

Client lifetime extension in progress. First crash/rejoin run failed immediate
fresh attach with the old controller still present. The fixture now retries only
definite refusal responses while cleanup converges. Root also fixed a separate
record-lifetime gap: Hive bridge explicitly monitors client actors, revokes on
EXIT and unmonitors on forget/close, so a live runtime connection cannot retain
all dead actor records. Strict lint passes. Session 13451/log
`/tmp/bee-hive-desktop-client-lifetime.log` now tests crash/rejoin and 66 client
actors exiting after attach, above the 64-record bound. No passing loss-recovery
claim yet. Foundation session 9118 has reached actual client-desktop checks.

Remote actor-lifetime gate is reproduced in native runtime independently of Bee:
`make -C /tmp/bee-mesh-rendezvous-20260909/native mesh-monitor-check MESH_RUNTIME=/tmp/wippy-bee-client-runtime-20260909`
fails in 5.194s, `/tmp/bee-desktop-runtime-monitor-gate.log`.
`TestNativeRemoteMonitorMustObserveClientActorExit` confirms the monitor via an
application FIFO barrier, completes the actual actor, keeps transport alive and
receives no EXIT. Actual Bee crash test likewise retains the old controller.
Runtime primary has the reproducer in the journal; no runtime edits by root.
The 66-actor capacity extension is implemented but not reached while this gate
fails. Explicit detach/rejoin and authority negatives remain the passing proof.

Typed native desktop operations checkpoint `f340902` FF-pushed to
`origin/feat/independent-view-bindings`; focused race/vet passes. `NewDesktop`
binds list/attach/detach to selected execution and actual actor, accepts only its
owner-bound session for detach, preserves unknown mutation outcomes and keys,
and never retries. It adds no public startup path.
Foundation continuation session 9118 completed with exit 0: source/pack storage,
desktop/Terminal/retained client/recovery/Test Status recipes all passed after
previously completed prerequisites. Evidence uses each recipe's staged snapshot;
it does not prove the new enabled actor-loss case, which still fails the native
remote EXIT gate. Shared bridge/service/fixture changes remain uncommitted.

Compiled native client-role acceptance passes 31.145s:
`/tmp/bee-hive-compiled-desktop-first.log`. Isolated native helper source is
`native/client/hive/testfixture/main.go`; Make target
`hive-desktop-client-fixture MESH_RUNTIME=... FIXTURE_OUTPUT=...` builds it.
Shared Go harness selects it via `BEE_NATIVE_DESKTOP_CLIENT`; compiled variant
uses native stack/naming/actor + typed desktop operations and viewport IO to the
actual retained owner. No Lua client, physical input or public launcher claim.
Both processes stopped cleanly. Client now rebuilt with `-race`; rerun log
`/tmp/bee-hive-compiled-desktop-race.log` is in progress. Helper/Makefile changes
remain uncommitted; runtime actor-EXIT gate remains separately failing.

### Physical native desktop and runtime read isolation (2026-09-09)

The actual compiled native client now passes the PTY acceptance against the
retained Bee owner: shell input, F12 retaining the same shell, resize and further
input, Ctrl+] detach within eight seconds, and exact terminal attribute
restoration. Log: `/tmp/bee-hive-physical-desktop-read-isolation.log`, 37.362s.
No public launch or LAN acceptance is implied.

The failing F12 exposed a general runtime defect: `io.readline()` occupied the
single terminal dispatcher worker, so another actor's `tty.start()` never ran.
A deterministic runtime regression failed before separating the bounded stream
read and terminal control queues; the terminal dispatcher race suite then passed.
Candidate changes are in `/tmp/wippy-bee-client-runtime-20260909`, not the primary
runtime tree. Temporary startup tracing was removed. Bee retains named presenter
failure/readiness and renderer-admission diagnostics; the disposable headless
fixture keeps logs visible. Wolfden facts 348–349 record the reproduction and fix.

Remote actor EXIT cleanup, automatic ordinary `bee` attachment and the actual
`100.70.10.28` Terminal acceptance remain required. The physical fixture's explicit
detach does not prove recovery after an actor crashes without detaching.

Final dispatcher checkpoint: runtime `944736c999` separates reads/control,
rejects saturated queues without running reads on the scheduler, and serializes
submission, shutdown and restart. Luna Max's race checks pass for the dispatcher
(100 runs), all terminal services, and Lua tty/io modules; vet also passes.
The clean detached build in `/tmp/wippy-tty-dispatcher-20260909` passes the actual
physical client again: `/tmp/bee-hive-physical-desktop-final.log`, 32.230s.
Native helper `11b16e1` is fast-forwarded to `feat/independent-view-bindings`.
The complete Bee check is still running in
`/tmp/bee-physical-client-foundation-check.log` against the initial read-isolation
candidate binary; it has passed 385 tests, isolation, packaging, storage and
migration checks. Keep the two binaries/proof scopes distinct.

### Completed full foundation recheck (2026-09-09)

Session 36510 exited 0: `/tmp/bee-physical-client-foundation-check.log` covers
385 Wippy tests, module isolation, source/pack architecture, workspace hosts,
storage and migrations, desktop interactions, native Terminal themes/permissions,
control-delivery failures, independent/retained clients, recovery and Test Status
background completion/replay. That full run used the initial read-isolation
candidate binary. Session 15478 also exited 0: final committed dispatcher runtime
`944736c999` passed the source/pack independent-client, workspace-appearance and
retained-supervisor checks in `/tmp/bee-client-desktop-final-dispatcher.log`.

Luna Max is adding a separate physical OS-process crash/rejoin fixture. It must
kill the compiled client without sending detach and prove the retained shell on
reconnect. A passing connection-loss case must not replace the still-failing
remote actor-EXIT gate with live transport.

### Physical LAN desktop acceptance (2026-09-09)

The actual retained-owner fixture passed against `100.70.10.28` with native TLS
and mesh, final runtime `944736c999`, and a compiled physical client. Evidence:
`/tmp/bee-hive-physical-desktop-lan-cap.log`, session 86238 exit 0, 42.35 seconds.
An owner-only random file proves shell location; typing, F12 same-shell recovery,
resize, bounded detach and exact terminal settings restoration passed.

Desktop admission now rejects invalid or expired deadlines and caps owner work
at thirty seconds, consistent with ordinary originating supervisor admission.
Previously it rejected deadlines even slightly beyond its own thirty-second
clock window. The first cap used math.min and strict lint rejected its number
result; the final conditional retains integer due times.

This run used the frozen `/tmp/bee-desktop-physical-lan.py` baseline plus owner
assertion; repeat with Luna's final checked-in crash fixture after review. The
remote candidate remains at `/tmp/bee-desktop-runtime-qrKEJEku/wippy` for that
proof, not installed globally. Actor EXIT with live transport and public
auto-attachment/desktop selection remain separate unfinished gates.

### Physical LAN client crash/rejoin (2026-09-09)

Session 84835 exited 0: `/tmp/bee-hive-physical-desktop-lan-crash.log`, 41.75s.
With `BEE_NATIVE_DESKTOP_PHYSICAL_CRASH=1`, the frozen physical driver kills
the compiled client using SIGKILL (no detach), starts a new process and verifies
`PHYSICAL_CRASH_REJOIN_crash_retained_OK` from the original remote shell.
The owner-only file assertion also passes. Fresh detach restores terminal state;
the test driver itself restores raw-mode residue immediately after SIGKILL.
This crash branch does not run F12/resize; those passed in the separate LAN
baseline run. Test log labels now distinguish the branches.

Helper built through the Make target against final runtime 944736c999 at
`/tmp/bee-native-desktop-crash-lan-fixture`; frozen driver
`/tmp/bee-desktop-physical-crash-lan.py`. Review and repeat Luna's final checked-in
fixture before checkpointing it. Live-transport actor EXIT remains unproved.

### Correction: crash proof endpoint scope

Review of the native helper found its CRASH=1 branch chooses stable membership
and internode ports (owner seed port +1/+2) for each restarted node-1 process.
Thus the preceding LAN crash proofs establish same-endpoint recovery only. They
do not prove automatic-port crash recovery and must not be cited as that gate.
The final checked-in Python branch also passed at these stable endpoints:
`/tmp/bee-hive-physical-desktop-lan-crash-final.log`, session7472 exit 0, 41.66s.
Root is testing a frozen driver that preserves Python SIGKILL behavior but disables
the Go helper's port override; session44314,
`/tmp/bee-hive-physical-desktop-lan-crash-auto.log`. Port arithmetic is not approved
for public launch and should not remain implicit in acceptance fixtures.

Automatic-port probe session44314 exited 2 (53.41s). Initial attachment worked;
post-SIGKILL rejoin timed out before its prompt. Owner logs show native memberlist
`Conflicting address for node-1` (old port37289, new37231) and an unmanaged-node
connection warning. `/tmp/bee-hive-physical-desktop-lan-crash-auto.log` is the
reproducer. Same-name immediate rejoin is distinct from the real local client's
fresh random `bee-client-*` identity on each run; do not infer that path fails.
The next proper acceptance must admit fresh identities through native enrollment
evidence, not force stable ports. Full foundation check is running session56294,
`/tmp/bee-foundation-final-runtime-lan-cap.log`, final runtime944736c999; lint passed.

### Available parallel UI lane

User asked what can proceed in parallel. Hive Manager and node/desktop selector
UI can proceed over a typed adapter, with fixture data explicitly labeled until
live operations exist. Keep named nodes, workspaces, desktops and attachments
separate; distinguish control/observe and unavailable/empty. Root retains native
admission, reconnect, desktop allocation and public launch wiring. Coordinate
shared interfaces before changing them. Read BUILD_SEQUENCE.md and CLIENT_STATE.md.
This offers work for the user's other agent; it does not claim that lane is staffed.

### Fresh client identity and automatic-port LAN recovery accepted

Session84176 exited0: `/tmp/bee-hive-physical-desktop-lan-crash-fresh.log`, 53.28s.
The checked-in Python driver SIGKILLs node-1, then starts node-2 from a separate
disposable configuration with its own key. Both use automatic ports. Owner
explicitly admits both fixture identities. Retained shell variable and owner-only
file checks pass; final detach restores terminal state. The helper no longer
contains implicit stable ports or seed-port arithmetic. Native helper/docs
checkpoint is 1dc4bac, based on runtime944736c999. Public dynamic enrollment and
live-transport actor EXIT remain separate.

User wants notification when runtime PRs are all ready, to release a base for Bee.
Current verified candidate is tty dispatcher944736c999; native actor EXIT and
authenticated enrollment evidence remain release gates, and full final-runtime
foundation check session56294 is still running. No all-runtime-ready claim yet.

### Runtime PR-only release handoff

Runtime PR https://github.com/wippyai/runtime/pull/701 is open from current main:
`1926243b1c` isolates dispatcher read/control queues and bounded admission.
All terminal packages pass race tests and vet on the main-based branch.
`RUNTIME_CLIENT_RELEASE_GATES.md` inventories the candidate/main ancestry gap;
existing PR ownership and patch equivalence must be checked before further PRs.
User wants to release the main-based runtime once required PRs are ready, then
have Bee consume that release. No runtime main push or merge is authorized.

Runtime PR https://github.com/wippyai/runtime/pull/702 now preserves `--host`
for both pack paths, directly on main (`6c335d88a5`). The regression test fails
with old terminal-host fallback; pack/launch race checks and CLI vet pass. No
merge. Luna is auditing existing PR equivalence before more slices are opened.

Draft runtime PR #703 adds native launch/owner preparation and busy-lock attachment,
assigned to Rodrigo. Application race tests/vet pass on main. It remains draft
until command startup cleanup is reviewed. Graphics #692→#693→#697 are also in
the release inventory; no duplicate graphics implementation is needed.

Runtime PR #704 (`d644cf9b75`) now isolates command lifetime and startup cleanup
on main; assigned Rodrigo. Boot and command race tests/vet pass. This is the
cleanup prerequisite called out by draft #703. Both remain unmerged.

### Runtime CI baseline corrections

PR701 CI exposed inherited publish fixture fieldalignment and terminal shrink
assertion failures. The same test-only corrections as the graphics stack are now
on all four client PRs: heads701=93fc82eef4,702=23845f2c99,703=58295eae40,
704=ba01b8379e. Targeted race tests pass; exact full-repository lint passes on701
(`/tmp/runtime701-full-lint.log`, zero issues). CI is restarted on the new heads;
no merge or full CI-pass claim. Luna's inventory task failed service demand;
root continues that audit locally.

Runtime PR #705 (`1bbf7693d8`) exposes typed terminal input without a scheduler,
EOF/error completion and restart cleanup fencing. Assigned Rodrigo. Terminal race
suites and exact full lint pass; first lint found a bool-field padding issue,
fixed without behavior changes. Graphics #693 overlaps input.go; PR description
calls out preserving capability probing during integration. No main merge.

### Resumed Bee checks and refined transport lifecycle finding

Strict lint passes after the bounded byte formatter fix in src/apps/hive/view.lua:
KiB/MiB numeric values computed before range narrowing, no casts/type relaxation.
Session44352 is running the remaining Makefile desktop commands starting at
control_delivery, after repacking and architecture checks, via temporary
/tmp/bee-foundation-resume.mk. Log /tmp/bee-foundation-final-runtime-resume.log.
Do not call it a fresh full-check pass; earlier stages and this continuation have
different source snapshots because the UI lane added entries during the first run.

Refinement of transport review: system/tty/mesh.go already calls Receive(nil)
once during close. Thus registration is NOT necessarily manager-lifetime as
previously described. The extraction's comment was inaccurate. The manager clear
is unqualified; a reusable exported adapter must track its own successful claim
and make release one-shot, or use a manager-owned registration token, before
claiming safe replacement. Verify failed duplicate admission and stale cleanup
cannot unregister a replacement. Do not add a parallel listener/protocol.

Runtime PR #706 (`8b9d93886a`) exports native surface transport with per-adapter
receiver lifetime, assigned Rodrigo. Regression proved failed duplicate cleanup
cleared the active receiver before the fix. Race suites and 50 concurrent-retired
cleanup repetitions pass; full lint zero. Existing class/protocol and TTY authority
remain unchanged. No direct main push or merge. Remaining Bee checks44352 continue.

Acceptance session44352 stopped at a new transient lint failure while the UI
lane changed the source from275 to279 entries; current shared source lint passes.
Root froze source/tests/docs/build and root config files into
/tmp/bee-foundation-frozen-20260909-0hbomp7y, with acceptance-source-sha256.json.
Full Makefile check is now session37696, /tmp/bee-foundation-frozen-check.log.
This avoids treating moving-source checks as a coherent acceptance snapshot.

Runtime inventory: #685 expressly excludes remote monitor protocol installation;
#675 handles closed-before-Run, not socket-first TLS close. Remaining candidate
commit groups are listed in RUNTIME_CLIENT_RELEASE_GATES.md. Cluster owner needs
to coordinate consumable listener/key/TLS/ingress and monitor checkpoints; root
has not copied that owner's dirty closure or claimed these gaps covered.

Runtime PR #707 (`004374b479`) isolates socket-first TLS abort on main, assigned
Rodrigo. Full internode race suite and full lint pass. Close/rejected handshake
must complete without idle peer reads; verification unchanged. No merge.

Frozen check37696 stopped on a Timeline test file missing during the copy. The
file now exists; all src/tests Lua manifest source references resolve. New snapshot
/tmp/bee-foundation-verified-20260909-8yoe13c_ passed before/copy/after SHA256 equality
for src and tests, recorded acceptance-input-sha256.json. Full check20832 is running
there, log /tmp/bee-foundation-verified-check.log. Earlier failed copies remain
failure evidence, not acceptance passes.

Runtime PR #708 (`b2efb6c4d0`) isolates retained automatic listeners on main;
assigned Rodrigo, no merge. Full cluster/internode/system boot race suites and
full lint pass. Wolfden seq383. Compiled zero ports intentionally request OS
assignment; explicit ports and normal boot defaults remain.

Frozen full check20832 failed on 13 Inbox fixture type errors (production lint
passes), recorded at seq382 and /tmp/bee-ui-fixture-errors.txt for the UI owner.
Separate pack/desktop acceptance11731 remains running; no full-check pass claimed.

Wolfden seq385: draft runtime #709 (`755faad98d`) adds host-approved peer key
lookup, stacked on #708 and assigned Rodrigo. Lint/internode/boot races pass;
initial full cluster check timed out forming twenty nodes. Three focused repeats
pass on both branches, but do not resolve the intermittent failure. #708 now
has per-node diagnostics at b42c22f42d. No independent reviewer evidence: agent
failed at the provider. No runtime release-ready claim.

Runtime PR #710 (`cbce0f9896`) isolates cancellable relay/queue admission on
main, assigned Rodrigo. Full internode/relay race suites and lint pass. No
detached legacy sends; errors preserve package ownership, accepted items cannot
be recalled. Codec stays synchronous. Preserve wakeups with #673 during
integration. Independent review agent failed provider; no review claimed.
Frozen desktop11731 reached navigation after source/pack Terminal acceptance.

Frozen pack/desktop session11731 passed, log /tmp/bee-verified-desktop-check.log.
Full check20832 still failed Inbox fixture types; desktop success is separate.
Runtime #711 (`4adafbef9f`) propagates native ingress through Lua, assigned
Rodrigo and ready for review: complete API/internode/engine/process race suites
and lint pass. Existing #675 prerequisite is included with its test reused.
TLS extraction is still local: full cluster/boot race passed, review then found
an explicit malformed TLS root could silently select plaintext. Red regression
proves it; rejection is added and final boot race/lint is running.

Runtime #712 (`72f03ff598`) adds native TLS config and boot admission lifetime,
stacked on #708, assigned Rodrigo. Full cluster/boot races and lint pass; malformed
TLS roots now reject instead of downgrading implicitly. All tested candidate
commits are now mapped to PRs. This does not resolve #703/#709 drafts, native
actor EXIT, public enrollment/launcher or main-release acceptance. No merges.

CI follow-up: #703/#704 lint corrections pushed at e348909100/3933abd56b;
local lint and focused races pass. #708 converted to draft after CI convergence
failure. Constrained isolated tests also hit the known #690 metrics race.
Local integration #708+#673+#675+#690 passed five constrained race repetitions
in69.551s; no claim of individual causal attribution or isolated readiness.
No timeout was increased. Logs: /tmp/wippy-client-pr-integration-constrained.log
and /tmp/wippy-auto-listeners-pr-constrained.log.

Monitor diagnosis: remote requests lack production topology dispatch. An
unvalidated prototype was unexpectedly written during a read-only subtask;
root preserved all seven paths exactly in /tmp/wippy-topology-ingress-prototype-20260909
and /tmp/wippy-remote-topology-unvalidated-20260909.patch, then restored the tested
candidate clean/detached at944736c999 with the same binary SHA256. No process was
left running. Prototype ownership, authorization and composition need redesign;
no monitor PR or passing gate is claimed. See Wolfden findings for specifics.

Wolfden seq 395: combined #708+#673+#675+#690 full cluster/internode/metrics
races pass (12.191s/8.061s/2.046s); isolated #708 CI failure remains unresolved.
Remote monitor proposal now records target-owner grants, native host composition,
connection fencing and correlated installation receipts in the release-gate doc.
A separate main-based runtime branch reproduces rejected incoming-package retention
leak and fixes it; internode races pass in 8.576s. Full lint initially stopped on
local disk exhaustion; 6.01 GiB of old generated Go cache cleared, rerun pending.
Apps agent can independently build the typed client-session status reader through
the public projection contract, coordinating before shared presenter wiring.

Rejected-delivery fix published as runtime PR #714, dad1070bbf, assigned Rodrigo.
Full internode races and repository lint pass; the regression was red before fix.
No runtime merge or global Bee binary replacement. #703 CI is green; #704 native
Lua CI failed and the inventory lane is investigating. Public second-bee and
remote monitor gates still remain.

Runtime #704 updated to 4dbd7c737c: loaded-but-unstarted dispatchers now stop
without panic, and the cleanup regression covers the entire default composition.
Full affected races and repository lint pass. Combined application.Run proof at
local 70064f81d6 passes: runtime Stop then owner Close under lock, then release.
#704 remains draft for unexplained generation_drain startup-event CI timeout;
new-head CI pending. No runtime merge, public launch or monitor completion claim.

Runtime PR #715, 12c471667d, assigned Rodrigo: optional owned relay-host
registration with exact-incarnation release; no monitor authorization or drain
claim. Full relay/topology/boot-component/API races and repository lint pass;
read-only review found no correctness issue. #714 corrected inherited terminal
shrink assertion at a5b05370da after its Ubuntu CI failure; focused race passes.
The status-reader handoff docs/handoffs/STATUS_SURFACE.md was read; shell wiring
remains separate from the native transport and monitor work. No merges.

Draft runtime PR #716 at 0f14ff2470, assigned Rodrigo, stacked on #711:
exact connection-bound monitor grant authority plus strict native control codec.
Root review fixed authority-close admission, concurrent-close completion,
panic gate release and capacity reclamation ordering. Races/lint pass; decoder
fuzz passed 71,948 executions. Receiver/EXIT/boot/Lua/client integration remains.
Other agent assigned durable subscription close/forget and bounded retention;
shared shell, runtime and transport remain root-owned. No runtime merges.

Wolfden seq 402: uncommitted #716 target-side admission state passes remote and
local topology race suites and full runtime lint. Retirement regression is red
with the old early-return path, green with joined cleanup; Done publishes under
the authority map lock. A grant retains one installation request identity and
reserves release receipt capacity. Local completion preserves the actual result.
Independent receiver-state review is pending. No EXIT wire, boot, Lua or public
Bee monitor integration is claimed; these changes have not yet been pushed.
Subscription close/forget completed in the independent threads lane; next lane
assigned workspace resources and credential broker, excluding shared launch wiring.

Runtime #716 updated to 06e73fdfa4, assigned Rodrigo. Review found and root fixed
shared-target observer collisions and rejected-ID receipt starvation. Inbound
multiplexes local observation claims; real-topology completion preserves original
request IDs and actual results. Releasing one grant preserves the other watcher.
Ten remote race repetitions and full runtime lint pass. Rebased over a concurrent
README deletion, preserving it without force push. PR was externally marked ready;
root did not override it. Receiver/EXIT-wire/boot/Lua/Bee integration remains.

Runtime #716 checkpoint 011b873f43 adds the native EXIT envelope and bounded
completion-result representation. Internode codec round-trip, negative envelope
checks, remote/topology races and full lint pass. Result review corrections
support JSON string backing and distinguish present empty bytes from absence.
Result capture must run outside admission gates. The origin still needs to
verify the installed relationship before actor delivery; no receiver/boot/Lua/Bee
completion claim follows from these codecs.

Wolfden checkpoint seq 407: watcher-side expectations implemented but uncommitted
in #716 outbound.go/outbound_test.go. Exact request/connection checks, reordered
completion buffering until Installed, once-only queue admission and cancellation
fencing pass races. Cancel retains a capacity-counted tombstone to stop request
resurrection. Full runtime lint passes; independent review pending. The journal
required its eight-hour episode rotation; checkpoint saved before rotation.
Receiver registration, actor delivery, boot/Lua/Bee integration remain incomplete.

Runtime #716 a695cb1690 adds reviewed watcher expectations and the origin relay
receiver. Cancellation tombstones retain replay fencing and count toward capacity;
exact re-Track and delayed Installed/EXIT cannot revive cancelled requests. Native
relay routing proves completion queue delivery and success-only package release.
Expectation race repeats, final receiver races and full runtime lint pass.
Target-side receiver, owned registration composition, actual actor event delivery,
boot/Lua/Bee integration remain incomplete. No runtime merge or launch claim.

Coordination pause: user requested remote-monitor semantic changes and startup/API
wiring pause while the cluster lane compares overlap. Published #716 head is
`a695cb1690`; uncommitted comparison material is in
`/tmp/wippy-remote-monitor-pr-20260909`: inbound.go/inbound_test.go and
 target_receiver.go/target_receiver_test.go under system/topology/remote.
The target-side integration test passes; final full runtime lint is zero issues.
#685 at b32785b3676ec5af53c18664d5eb45cfe2c9735a owns existing topology lifecycle
bookkeeping and explicitly excludes acknowledged remote-monitor wire delivery.
No public process.monitor API or boot wiring has been changed by #716. Leave
these semantic changes paused until ownership is reconciled. Other Bee work may
continue. Last CI check: #704 all green; #708 Ubuntu failure remains unresolved.

Read cluster handoff seq 412: an existing private binary/session-class monitor
controller overlaps #716. One controller must be consolidated before any protocol,
EXIT, receiver or boot integration resumes. Runtime changes remain paused; user
will forward runtime gaps. Bee-only work may continue.

System map added at docs/SYSTEM_MAP.md and indexed from docs/README.md: persistent
owners, application-db definitions versus registry overlays, governed change and
installation planning, Hub/cache, sharing/export, visible operation interfaces,
federated approval inboxes and the acceptance sequence. Future capabilities stay
proposals. Internal links checked. See Wolfden seq 414 and following handoff.

### 2026-09-09 Codex: receiver-local typed listener and sender-only Hive boundary

User corrected the boundary: use native sender identity and established supervisor
admission, remove Bee Lua ingress/connection evidence. Removed that dependency
from supervisor and retained-desktop owner/fixture; retained exact sender checks,
peer incarnation fencing, deadlines, session receipts and native EXIT cleanup.
Strict lint now has no ingress errors: remaining four are three gateway lane
errors and the Future completion-channel declaration.

Preparing main-based runtime branch `feat/process-typed-listen` in isolated
`/tmp/wippy-typed-listen-20260909`. Required API:
`process.listen(topic, {message = true, type = T})`, validating receiver-local
T against decoded v1 maps without changing native sender identity. Wippy2 is
the reference; static typing and real delivery filtering both require proof.
Runtime origin/main base is `6eb34cb3d1`; no build pin change or release yet.
Actual GitHub Go-Lua main is staged separately; the nearby go-lua checkout
tracks a legacy repository and is untouched. Runtime PRs go to skhaz. Cluster
and paused remote-monitor controller ownership remains unchanged.

### 2026-09-09 Codex: typed listener and Future PRs opened against main

- Runtime #718: `process.listen(topic, {message = true, type = T})`, receiver-local
  native validation before delivery. `message:data()` returns the checked value;
  native sender/topic remain intact. Raw mode returns the checked value directly.
  Uses existing topic-handler filtering and map transcoding, no mesh changes.
- Go-Lua #44: generic metatype inference and substitution; typed and untyped
  listener overloads preserve their result types. Full Go-Lua suite passes.
- Runtime #717: Future response/channel returns the actual optional native
  `Channel<unknown>`; strict retention/select regression passes.

All three target main, are assigned to Rodrigo/skhaz, and remain unmerged.
Runtime #718 pins #44's published commit; replace it with the released dependency
during cutover. Bee's build pin/global executable is unchanged. Focused Bee
supervisor suites now pass 39/39 after ingress removal. Full process race,
engine/payload race and process lint pass for the listener; full runtime lint
is still running at this checkpoint. Remaining Bee lint errors at last run:
three parallel gateway errors and the Future manifest declaration.

Runtime #718 final local gate: full `GOWORK=off make lint` completed with
0 issues. PR validation description updated. Hosted CI is still running;
no hosted-CI or release success claim.

### 2026-09-09 Codex: typed map integration checkpoint (journal seq 464)

V1 remote payloads remain maps. Listener `type=T` validates the decoded value
against the receiver's local type; it adds no transmitted type identity.
Native sender authentication and operation authorization remain separate.

Correction to the earlier Future note: runtime #717 now declares the actual
nonoptional `Channel<unknown>` return at `91502bb2735a`; optionality belongs only
to Bee fields that may not yet hold a channel.

Temporary candidate `beb5c014a1` combines #718, corrected #717 and the existing
#702 explicit pack-host fix (`6c335d88a5`). Release pins and the global executable
are unchanged. Source host/restart acceptance passed; the prior packed check
exposed #702's command-host bug. Focused status tests pass 68/68; the inbox child
reports 91/91 selected tests after fixture typing corrections. Full `make check`
and source/pack workspace-host acceptance are running on the rebuilt candidate.
Remote-monitor #716 stays paused for the cluster lane.

Candidate update: `make workspace-hosts-check` now passes source and pack,
including restart recovery. Strict production lint (302 entries) and staged
test lint (419 entries) pass. Full `make check` and actual desktop-client
acceptance remain running; no full-suite or release success claim.

### 2026-09-09 Codex: full foundation integration progress (seq 467–469)

Candidate `beb5c014a1` passed 454/454 Lua tests, standalone module closures,
gateway checks, headless and workspace-host source/pack acceptance, ordinary
client-desktop source/pack acceptance, workspace/client storage and resource
persistence/containment. Architecture now passes at 517 source/pack entries:
session helpers remain in their namespace, the application envelope has one
pure thread-ID decoder dependency, and carrier/placement share only the
host-selected gateway configuration renderer. Full physical desktop suite is
still running.

The previously staged subscription restart probe exposed a missing fixture
create grant, a UUID return narrowing issue, and output going to the runtime
logger. It now lints explicitly, grants creation only for `lifecycle-thread`,
uses `io.print`, and passes close/restart/resume/forget/restart assertions.
Production policies and migrations are unchanged.

Runtime #717/#718 and Go-Lua #44 now have all hosted checks green; all remain
open and assigned to skhaz. Native mesh no longer carries ingress evidence;
`make -C native mesh-client-check` passes race and vet against historical
`944736c999` (mesh 61.545s, physical 1.031s). This is mechanism evidence only.
Current main and that historical candidate lack the earlier direct source-node
provenance guard: seq 469 records the exact native cluster handoff. Keep the
Lua ingress API removed and have the cluster lane enforce source authority
inside routing. Release pins/global binary are unchanged.

### 2026-09-09 Codex: local candidate acceptance checkpoint (seq 475)

All foundation recipes now have passing evidence across original and resumed
focused runs, not one uninterrupted `make check`. The final marker-checked
client-desktop source/pack probe proves host-authorized status survives F12 and
fresh-client rejoin, then changes to Idle after a real owner reply. Evidence:
`/tmp/bee-client-desktop-final.log`. Status handoffs now reflect these results.

V1 remote payloads remain maps; typed listeners validate decoded values against
the receiver's local type, without wire type identity. Sender authorization is
separate. The shared manifest now maps the gateway database into native state;
no new standalone binary or global install is claimed. Module composition and
public auto-attachment remain Bee work; native source authority and remote
monitoring remain cluster-lane release gates. Runtime #716 stays paused.

### 2026-09-09 Codex: standalone ownership proof (seq 477–478)

The current source declares 28 roots for 12 intended module owners. An isolated
copy removes 16 redundant child-root declarations while preserving operational
entries and groups child slices with their owner. Threads isolation, strict lint
and standalone desktop acceptance pass. All 502 staged source/installed entry
payloads match, and registry metadata verifies exact ownership across 12 modules.
Gateway state defaults also pass in this newer executable. See
`STANDALONE_MODULE_COMPOSITION.md` for evidence and the candidate binary hash.

Shared declaration correction and a reproducible explicit bundle workflow are
still pending; the temporary pack script is not the adopted release workflow.
Global Bee and release pins remain unchanged. Native topology stays in its lane.

### 2026-09-09 Codex: bundle workflow adopted (seq 483, 485, 487)

`build/modules.json` now enumerates namespace ownership, and `build/bundle.py`
prepares validated packs for the pinned builder. The normal Make path uses its
generated manifest. Shared source has 12 package roots with child slices retained;
no operational entries or migration contents changed. Seven bundle checks,
Threads isolation, candidate standalone/native acceptance and source/pack
architecture (502 entries) pass. Storage, subscription restart and resources pass.

The full suite is not green: new gateway/harness fixture calls erase typed returns
through `assert`, producing four lint errors; seq 483 hands those to that lane.
The remaining run then hit a four-second blank initial desktop frame. Focused
source/pack boots pass unchanged at 1.739/0.846 seconds; cause remains unproven.
Desktop acceptance is rerunning in `/tmp/bee-adopted-bundle-desktop.log` (session
26316). The earlier remaining-recipes session 62397 has finished with failure.

Candidate executable `/tmp/bee-adopted-bundle` has SHA-256
`2d6752e4356858eb5cf298922f658494100df995261802f859c48eed6bc3fad5`.
Release runtime PRs remain open, assigned to skhaz. Global Bee is unchanged.

### 2026-09-09 Codex: assets and input regression checkpoint (seq 495, 501)

Bundle composition now freezes explicitly selected module-relative filesystem
assets, records file hashes and embeds them in the owning pack. Eight bundle
tests and the source-free nested-template/WASM-byte proof pass. This proves
asset transfer and read-only loading, not WASM execution or Hive distribution.

The earlier desktop run is finished, not running: it reached lifecycle staging
and failed lint after concurrent gateway edits. No full-suite green claim.

`make terminal-scroll-check` is the new TDD acceptance. The original candidate
fails on the first physical wheel notch because native proxy history retains
one line. The bounded-history candidate passes movement but the 40-event SGR
burst exposes a second failure: a mouse sequence suffix reaches Bash as text.
The current x/input reader parses independent 256-byte reads. Native stream
framing investigation is in progress; do not mark scrolling or Codex fixed.
Window-local selection/copy remains pending its physical-client delivery path.
Clipboard content must never become durable or broadcast viewport state.

Go-Lua assert result typing is reviewed separately in GitHub PR #45, assigned
to skhaz. Full tests and fixtures pass. Hosted CI is entirely green, including
lint, fuzzing, race tests and Windows. Local lint reported findings also present
on its main baseline. Bee's dependency pin and global binary are unchanged.
Native scrollback is draft runtime PR #719, also assigned to skhaz; its Bee
acceptance remains behind the separate native input-framing fix. See
`TEXT_SELECTION.md` for the proposed window-local selection and physical-copy
boundary. No clipboard mode is implemented yet.

### 2026-09-09 Codex: wheel/framing red-to-green (seq 509)

Both defects are fixed in the combined candidate: bounded native scrollback in
runtime PR #719 and Unix stream framing appended to existing PR #705. The latter
preserves its existing commits and the Windows Console API reader. Native race
tests and lint pass. `make terminal-scroll-check` now passes from source and pack;
the 161-case navigation proof and existing source/pack Terminal suite pass too.
The scrolling regression is included in `desktop-check`.

Candidate runtime source is `/tmp/wippy-bee-scroll-integration-20260909` at
`5fe640b780`, binary `/tmp/bee-wippy-input-candidate`. Logs are
`/tmp/bee-terminal-scroll-pass.log`, `/tmp/bee-input-navigation.log` and
`/tmp/bee-input-console.log`. PR #705 now ends at `993ca5e019`; PR #719 is ready
for review and had all hosted checks green. Both are assigned to skhaz.

Plain-text extraction is runtime PR #720, also assigned to skhaz, with native
TTY race tests and lint passing. It supplies no clipboard delivery. Selection
and copying remain unimplemented; the physical recipient boundary is documented
in `TEXT_SELECTION.md`. Actual Codex-conversation and device-trackpad acceptance,
full foundation acceptance, release-pin cutover and global installation remain
outstanding. No release or full-suite completion is claimed.

### Input integration and selection checkpoint (journal seq 517)

The combined compiler candidate exposed a real Go-Lua PR #45 regression:
truthy narrowing of `assert(tty.events())` loses the instantiated channel's
element type. PR #45 is draft while the compiler lane fixes it; no production
cast was added. The frozen foundation check is blocked at that error, so the
focused input results above are not a full foundation result.

The pure selection model now has five passing focused Wippy cases. The client
clipboard decoder has two passing cases covering active presenter identity,
unknown fields, control sequences and the 8 KiB text bound. Presenter wiring
is underway; clipboard output is still missing. Copy must use an explicit
operation to the requesting physical client, never saved or broadcast frames.
The existing native mesh actor inbox can carry that operation; no new mesh is
planned. Global Bee and the selected runtime pin remain unchanged.

### Local selection/copy acceptance (journal seq 520)

`Select text` now freezes one window's body. Left-drag selects, Ctrl+C submits
one bounded request, and Escape/resize/attachment retirement cancel it. Hover
after release preserves the range; a submitted reply retires selection and
returns keyboard input to the app. The exact active presenter is authenticated
by the client owner. Text and selection remain ephemeral.

Runtime PR #722 (`6f5f54aab5`), assigned to skhaz, supplies optional physical
`ClipboardSurface` and `surface:clipboard(text)`: bounded UTF-8, serialized OSC52,
closed-lease rejection and no virtual-frame fallback. Native race suites and
focused lint pass; full runtime lint reports two unchanged SQLite unused symbols.
Candidate `/tmp/bee-wippy-selection-candidate` at runtime `8beea1b58f` passes
production lint and `make terminal-selection-check` from source and pack.
The proof uses two overlapping Terminals and decodes exactly the foreground
selection from actual output; it covers hover, resumed input, cancellation/rejoin
and resize. Log: `/tmp/bee-selection-ui-final.log`.

Go-Lua PR #45 remains draft: the assertion correction passes compiler fixtures,
but the exact Bee fixture still exposes an `any` return from native event/completion
channel `case_receive` types. Native typing investigation continues. Remote copy
routing, full foundation acceptance, release cutover and global install are open.

The following shared acceptance fixes are recorded at seq 521/523: the exact
native runner was added to the existing pure gateway configuration consumer list,
and `fixture_workspace` now requires `managed_gateway=True` for the test-only
HTTP listener. Unit and managed-launch suites opt in; desktop and drag proofs
retain the no-listener default assertion. The production composition was not
binding that port. Architecture passes at 513 entries in source and pack.
The restarted desktop gate is `/tmp/bee-selection-desktop-check-2.log`; its result
is pending. Runtime PR #722 hosted lint and native application checks are green;
the Linux/Windows full suites were still running at this checkpoint.

### Global candidate installed — 2026-09-10, seq 534

At the user's explicit request, the tested standalone candidate is now installed
at `/home/wolfy-j/.local/bin/bee`. The previous executable is preserved at
`/home/wolfy-j/.local/bin/bee.rollback-20260910T024911Z`; user databases and deployment
selection were not changed. The installed executable passed standalone acceptance,
including embedded boot, Settings recovery, native Terminal, physical selection/copy,
fullscreen aliases, literal arguments and presenter rejoin. Evidence:
`/tmp/bee-global-installed-check.log`. SHA256:
`5f11377c2cd3e5e5d5d985c57247edf0f556e2008a2d1c17b4aeb19f568aa38f`.
This is the validated integration runtime candidate; the main-based runtime
cutover and public remote launch remain open. This supersedes the earlier
"global install open" status, not the remaining release gates.

### Bee-only continuation — seq 538–539

The user redirected this lane away from runtime work. The runtime handoff records
one uncommitted compiler update for its owner; no further runtime edits are queued
here. Current production `src/` matches the frozen foundation snapshot byte for
byte. The full check remains live and has passed scroll source/pack, 161 navigation
cases and selection source/pack before entering lifecycle acceptance.

`tests/native_binary.py` now also exercises wheel and burst scrolling through the
installed global executable. It shares the actual Terminal-body check with
`tests/terminal_scroll.py`; this works with Settings restored behind Terminal.
The unchanged notch, 12-event up burst, 40-event down burst and resumed-keyboard
assertions pass globally (`/tmp/bee-global-scroll-check-2.log`) and from source/pack
(`/tmp/bee-scroll-helper-check.log`). This is terminal-protocol evidence, not a
physical-trackpad or real-Codex-session claim. The installed executable was not
replaced during these checks.

### Detached completion and client acceptance

The strengthened detached check passed all six modes from source and pack,
requiring `BEE_ATTACHMENT_COMPLETE:<mode>` after every probe's assertions. Log:
`/tmp/bee-detached-completion-check.log`. The resumed desktop run completed
client-desktop acceptance and reached public-launcher checks. Legacy migration
source/pack preserves identities, edited layout and the original ledger. Remaining
launcher, recovery and app recipes are still live in
`/tmp/bee-foundation-remaining-desktop.log`; do not call the full suite complete.

### Foundation recipes complete — 2026-09-10

The resumed desktop process exited zero. Client-desktop, public launcher,
persistence recovery, Inbox, Hive Manager and Timeline passed. Combined with
the original frozen run and the corrected detached-probe completion check,
every foundation recipe has passing evidence: 481 Lua tests, 513 source/pack
entries, storage and module boundaries, desktop input/lifecycle and app gates.
This is resumed evidence after a fixture correction, not one uninterrupted
`make check`. The production source matches the tested snapshot. The actual
global executable separately passes standalone selection/copy and wheel/burst
scrolling acceptance. No replacement installation was necessary.

Remaining boundaries include the portable runtime pin (handed off), a coherent
source checkpoint sync, public second-invocation attachment, remote enrollment
and the remote Terminal launch surface. These passing local checks do not
establish those features.

### Automatic client-node rule and current binding — 2026-09-10

User confirmed: workspace ownership conflict selects a client node. The owner
retains applications/stores; the client requires live-owner verification and
supervisor admission. Update locks and stale discovery cannot authorize reuse.
The public global launcher does not implement this transition yet.

`native/client/hive` now passes its race/vet Make target against the existing
native mesh runtime, with native sender checks, supervisor replacement fencing,
actor lifetime cancellation and no ingress dependency. The compiled fixture was
adapted to that contract and builds. Its actual supervisor round trip fails:
both runtimes become ready, then a sent operation times out without a validated
reply. See `/tmp/bee-hive-client-supervisor-current.log`. Diagnose the boundary
before public wiring; no runtime files were changed and no global reinstall was
made. Local foundation acceptance remains separate from this failing Hive gate.

The enrollment review also confirms that same-account rendezvous is not remote
redemption. Remote enrollment needs an authenticated native bootstrap route and
live host-owned peer admission updates; a config write or transport membership
alone cannot grant workspace or Terminal access.

### Native reply decoding fixed; TLS mismatch isolated — 2026-09-10

`native/client/mesh` now accepts bounded Go maps normalized from Lua as well as
JSON record bytes. The previous inbox silently discarded map replies. Imported
and reviewed the existing bounded decoder, wired it into the actual actor step,
and added an actor-inbox regression. `mesh-client-check` passes with race/vet;
focused normalization/inbox tests also pass. Logs: `/tmp/bee-mesh-map-check.log`,
`/tmp/bee-mesh-map-regression.log`.

The real Hive round trip remains red for a separate, now isolated reason:
`/tmp/bee-wippy-selection-typed-candidate` initiates a non-TLS handshake against
the TLS compiled client, despite the fixture's enabled TLS configuration.
Client diagnostics show `tls: first record does not look like a TLS handshake`.
Typed and isolated-untyped listener runs both receive no request. Runtime
cutover handoff updated with reproduction; no runtime source changes, no TLS
bypass, no global reinstall. See `/tmp/bee-hive-client-transport-trace.log`.
All processes from these checks have terminated; no pending test waits remain.

### Runtime dependency identified — 2026-09-10

Revalidated upstream state: #712 (native TLS configuration) is OPEN and assigned
to Rodrigo/skhaz; #706 (surface transport) and #718 (typed listeners) are also
OPEN. #712 explicitly does not depend on the rejected Lua ingress API, is stacked
on #708 and asks integration to preserve #707 teardown. The runtime lane needs
to supply these compatible capabilities together for Bee's real admission proof.
Existing local runtime binaries predate that combination. No runtime/PR mutation
or global install was performed. The previous turn made concrete Bee progress
(map decoder and regression); this turn identifies the precise external cutover
rather than repeating the failed integration test.

### Verified native client checkpoint pushed — 2026-09-10

Pushed commit `5f20704e7310943d1a4a26757ba197b872ea7b76` to
`checkpoint/native-client-binding-20260910`; remote ref verified. No PR opened
or merged. The isolated branch starts at `722729c` and contains only the three
native client packages, rendezvous/privatefile dependencies, module metadata and
focused Makefile/README. Its 51 component files exactly match the shared checkout.
The shared main checkout and other lanes were not staged or changed by the sync.

Restored desktop-binding regression coverage under the new actor-lifetime
contract: exact attach/detach identity, no replay, foreign-owner rejection and
refusal versus uncertain grant results. The isolated Hive/mesh/physical race
checks and vet pass; rendezvous/privatefile race checks and rendezvous vet pass;
the compiled fixture builds. Logs `/tmp/bee-native-client-checkpoint-proof.log`,
`/tmp/bee-native-client-checkpoint-rendezvous.log`, and
`/tmp/bee-native-client-checkpoint-build.log`. These are separate focused runs.

This is a component checkpoint requiring an explicit reviewed runtime checkout,
not a portable release or complete shared-source sync. Runtime TLS cutover,
public auto-attachment, remote enrollment and actor-loss acceptance remain open.

### Adopted TLS candidate; physical F12 isolates #701 — 2026-09-10

Consumed runtime handoff 559. `/tmp/bee-wippy-tls-lifecycle-candidate` passes the
compiled native Hive admission/viewport/detach/rejoin proof; TLS blocker resolved.
Its six lint issues and broader cluster limits remain unclaimed.

Bee's physical PTY check reaches shell input but fails on F12. Isolated presenter
trace proves the replacement enters `tty.start()` and never returns; timeout
occurs three seconds later. Candidate dispatcher still shares one worker with
the coordinator's blocking `io.readline()`. Runtime PR #701 explicitly fixes this
exact scenario and is OPEN; reproduction added to the cutover handoff. Logs:
`/tmp/bee-physical-tls-lifecycle-check.log`, `/tmp/bee-physical-f12-trace.log`.
No shared Lua diagnostic edits, timeout changes, runtime edits or global install.
Both diagnostic processes are terminal. Public startup also needs #703's launch
hooks, absent from the supplied candidate; no new hook implementation proposed.

### Fresh-client crash discovery isolated — 2026-09-10

Physical crash acceptance reaches the initial shell, then fresh node discovery
fails before Hive admission. Fixture-only phases stop at `discover`, never
`supervisor-found`; membership joins and owner connection logs are present. This
is not evidence of a remote monitor failure yet. Logs:
`/tmp/bee-physical-crash-tls-lifecycle-check.log`, `/tmp/bee-physical-crash-phases.log`.
Added opt-in fixture phase diagnostics; no production Lua/runtime changes.

The owner source's native consumer build separately fails on missing
`internode.NewSurfaceTransport` and `StackConfig.InternodeTLS`, identifying the
remaining #706/full-#712 assembly surfaces. Public startup also needs existing
#703/#709; #701 remains the physical F12 gate. Detailed commands and limits are
in RUNTIME_UPSTREAM_CUTOVER. All checks from this turn are terminal; no install.

### Global body-selection build installed — 2026-09-10, journal 564

Installed `/home/wolfy-j/.local/bin/bee` from the accepted standalone candidate;
SHA256 `b33451bf0a0bf192c0c9b66c42c408b3b53ec281d91205d3c4f89ec84dc8e0f2`.
Rollback: `/home/wolfy-j/.local/bin/bee.rollback-20260910T040647Z`.
Body right-click opens the window menu with Select text; Shift-right-click
forwards to the application. Source/pack selection and standalone acceptance
pass, including clipboard, scrolling, recovery, arguments and F12. The broader
check is still running in `/tmp/bee-body-context-build-y61cmyxm`, session 29475,
log `/tmp/bee-body-context-foundation-check.log`; do not claim its completion.

Ordinary `bee` and `bee --base` still select different registry deployment state.
The required default is embedded definitions plus retained registry overlays;
forcing the flag would not preserve that contract. Public Hive activation and
automatic client launch remain unfinished. No application database was changed.

### Same-account client credentials — 2026-09-10, journal 565

Restored `native/hive/localtls` behind the `meshclient` build tag and added
`mesh.SameAccount`: validate local discovery, load protected execution-specific
TLS files, bound client lifetime by expiry, then enroll through native Wippy.
No owner startup, plaintext fallback, database access or desktop grant is implied.
The explicit `local-tls-check` gate and mesh/physical race tests plus vet pass
against `/tmp/wippy-bee-client-runtime-20260909`. Logs:
`/tmp/bee-local-tls-restored-check.log`, `/tmp/bee-same-account-mesh-check.log`.
No runtime edits or global reinstall. Public owner composition is next.

Correction to the global build validation: session 29475 ended with exit 2.
481 Lua tests, module/storage proofs, desktop smoke and fresh-pack acceptance
passed; taskbar startup received no Settings screen. Its unchanged isolated
source/pack rerun passed; the original cause remains unresolved. Remaining
Makefile desktop recipes are running as session 75150, log
`/tmp/bee-body-context-remaining-check.log`. Do not claim a full green check.

### Owner bootstrap and honest Hive status — 2026-09-10, journal 566

Restored `native/hive/localowner` using the existing runtime launch hook. Its
actual application subprocess test now checks native sender identity and the
current Hive client actor lifetime API, with no ingress dependency. Owner/client
exchange, credential expiry, listener closure and state-lock retention/release
pass (20.235s) against `/tmp/wippy-bee-client-runtime-20260909`. The Makefile gate's
vet phase is still running as session 6982, log
`/tmp/bee-local-owner-restored-check.log`. Public launch still needs composition
with the production supervisor and desktop admission service.

User requires UI to reflect Hive status. The Hive Manager now reports failed
lookup as supervisor unavailable with its reason, not profile disabled; it no
longer asserts enrollment will repair the problem. Existing periodic refresh
remains. The model test covers disappearance and return, and the app smoke passes.
Full Lua validation is running as session 39259, `/tmp/bee-hive-status-test.log`.
The prior frozen desktop remainder remains session 75150. These source changes
are not installed globally. No runtime source was changed.

Owner bootstrap vet also completed successfully. The coherent native closure is
pushed at `8ca8c0b14d0e832f99bc686a675228127799afaf` on
`checkpoint/native-client-binding-20260910`; remote ref verified, journal 568.
No PR, merge or shared-main staging. Lua status validation (39259) and frozen
desktop remainder (75150) are still running.

### Local admission boundary review — 2026-09-10

User questioned additional code given native mesh, then directed generalization
be revisited later. Transport and authenticated sender identity remain native.
Existing direct desktop admission uses fixed `allowed_nodes`, whereas fresh
clients have ephemeral identities. The unwired `localowner.ClientPolicy` uses
Wippy's existing security.Policy interface for one Bee desktop eligibility check;
it is not transport authentication, a registry entry, or a new Lua module.
Only a host-selected supervisor scope may receive it. Race/vet tests covering
unknown nodes, wrong actor/host, enrollment retirement and execution replacement
pass in `/tmp/bee-local-owner-policy-check.log`. Service composition remains next;
its sealed runtime frame must be forked before adding a host-selected policy.

The Hive Manager status changes passed all 481 Lua tests and its app smoke.
Frozen desktop remainder remains session 75150. No new global build installed.

### Supervisor-scoped fresh-client permission — journal 572

`Desktop.ClientPolicy` is now an optional native host input. Service startup
forks its sealed lifecycle frame, adds the policy only to that supervisor child,
and seals it before starting the process. Native race tests verify parent and
sibling scope isolation and missing-actor denial; native tests and vet pass.
An empty static list requires the host policy. Lua receives only `local_clients`
and checks the actual message sender through the existing security.can surface,
then all existing operation, execution, expiry, session and grant checks.
Public startup still does not select it; real fresh-client desktop acceptance is
next. Lua validation session 3136 and frozen desktop remainder 75150 remain live.
No runtime edits or global reinstall. Logs `/tmp/bee-service-client-policy-native-check.log`,
`/tmp/bee-service-client-policy-native-vet.log`, `/tmp/bee-dynamic-desktop-lua-check.log`.

### Fresh global Bee installed — 2026-09-10

`/home/wolfy-j/.local/bin/bee` now has SHA256
`1b71dff9845e25fe1bb3033d18ef1aed25c7dd65fbb21cdd30ae4b2c6a6da008`.
Rollback: `/home/wolfy-j/.local/bin/bee.rollback-20260910T043330Z`.
Built from `/tmp/bee-global-status-build-a4c4vkdm`: the only production changes
from the accepted body-selection build are Hive Manager model/view status wording.
Standalone checks pass for selection/copy, scrolling, recovery, command arguments,
F12 and the exact Hive status display. Logs `/tmp/bee-global-status-build.log`,
`/tmp/bee-global-status-native-check.log`, `/tmp/bee-global-status-hive-check.log`.
No database edits. Public Hive activation and default deployment selection remain
unfinished; new dynamic admission work is excluded from this installed binary.
Frozen desktop remainder session 75150 is still running. The new
`localowner.DesktopService` composition helper is not yet acceptance-tested.

### Combined native owner/desktop acceptance in progress

The optional `TestFreshClientDesktopComposition` builds current Bee source,
composes owner + service + ioevents, and tries catalog/observe attachment/detach
from a fresh SameAccount client with no static allowlist. Fixture corrections:
standalone parser does not accept runtime `--host`; pack identity must match its
bundle; multiple Bee module roots cannot be put in one module archive. The test
now uses `build/modules.json` to produce separate packs, keeping all module roots.
Current focused run: session 51553, `/tmp/bee-fresh-owner-desktop-check.log`.
`LOCAL_OWNER_TEST_RUN` selects the focused check; the package runner ceiling is
90s for its 20s and 45s bounded tests. No product timeout or runtime source changed.
The combined desktop proof remains unverified. Frozen desktop remainder 75150
completed successfully; the earlier taskbar initial-frame failure and successful
unchanged rerun remain recorded rather than claimed as one green make check.

### Fresh-client production desktop admission passes — journal 579

The combined owner test now passes discovery, desktop catalog, observer grant
and detach using a fresh SameAccount native client and no static client list.
It uses current source, real module plan and manifest database bindings, Wippy's
lock-held launch hook, production service and the host-selected client policy.
Race/vet passed in 12.061s; `/tmp/bee-fresh-owner-desktop-check.log` preserves it.
The stronger real Terminal control/rejoin/stale-input test is now running as
session 29259, `/tmp/bee-fresh-owner-terminal-check.log`. Public launch remains
unwired. No global binary change, runtime source change or database edits.

The stronger Terminal variant completed successfully (13.157s), including race
and vet: real native viewport input/output, retained shell variable after rejoin,
and stale mount input denial after detach. Log `/tmp/bee-fresh-owner-terminal-check.log`.
The rejoin uses the same live client actor; fresh-client crash recovery and LAN
remain separate gates. Public CLI selection is still unfinished.

### Reusable physical client session passes

Added `native/client/session`, composing existing mesh, Hive admission and
physical presentation. No owner startup or application-store access. Automatic
selection requires precisely one desktop; explicit selection requires both IDs.
The native session tests and vet pass, `/tmp/bee-client-session-check.log`.

The composed-owner probe now adds a second fresh native client through session.Join,
using a real PTY. It reads the first client's retained shell variable and detaches
with Ctrl+]. Race/vet pass in 17.606s, `/tmp/bee-fresh-physical-session-check.log`.
This supersedes the earlier fresh-client discovery uncertainty for this tested
composition; crash recovery, LAN and public launch remain separate gates.
No global install or runtime changes. First-launch lifecycle still needs explicit
owner/client separation so closing the foreground client does not kill its apps.

### Native client startup readiness verified

The client now retries only definite UNAVAILABLE catalog reads within the shared
15-second discovery deadline, with fresh keys and cancellation. Permission,
protocol, transport and uncertain errors return immediately; no mutation replay.
Session race/vet passes (`/tmp/bee-client-session-readiness-check.log`).
Actual-source fresh physical-client retained-Terminal composition also passes
race/vet in 15.502s (`/tmp/bee-fresh-session-readiness-check.log`).
Global binary unchanged; public launcher/background lifetime still needs wiring.
No runtime or user database changes.

### Retained owner/client checkpoint pushed

Pushed `22855af` to `checkpoint/native-client-binding-20260910` on wippyai/bee.
Includes native session, owner policy/service composition, Hive service and
ioevents closure. No PR or main merge. From that isolated checkout, all owner
race/vet tests pass in 35.920s including the fresh physical client retained-shell
proof; session race/vet passes in 1.086s. Log:
`/tmp/bee-native-session-checkpoint-check.log`.

The integration test can explicitly snapshot another Bee checkout through
`BEE_OWNER_TEST_SOURCE`; `native/CHECKPOINT.md` documents that the native branch
does not contain current application composition. Public owner/background
startup and automatic attachment remain unfinished. Global binary unchanged.

### Actual lock-busy client attachment verified

Added `native/launch.Client.Attach` over the runtime-selected state and existing
client session. Rejects unrelated commands, arguments, base/update/tooling.
Moved the discovery directory name into rendezvous (localowner retains an alias).
The physical composition probe now invokes actual `application.Run` while the
separate owner holds the lock. Failing PrepareOwner/Load hooks and invalid data
bindings prove no owner boot/deployment path; retained shell reads and Ctrl+]
pass with race/vet in 16.660s (`/tmp/bee-runtime-busy-client-check.log`).
Adapter rejection race/vet passes (`/tmp/bee-client-launch-check.log`).
No runtime or global install changes. First-owner background startup and public
component registration remain unfinished.

### Background owner lifetime primitive tested

`native/launch.StartOwner` starts this executable's `start` route with literal
state and command arguments, original project directory, null stdin and a
caller-owned regular log. Linux subprocess acceptance proves survival after
launcher exit, independent process group and no controlling terminal. Canceled
waits do not kill the child; already-canceled starts create none. Race/vet passes
via `client-launch-check` (`/tmp/bee-background-owner-check.log`). Windows flags
are implemented but unverified.

This supplies process separation only: public start command, readiness/error
handling and automatic first-launch composition remain unfinished. Global binary
and runtime source unchanged.

### Detached self-exec and explicit start checkpoint pushed

`NewOwnerLauncher` maps explicit start to the host-selected retained command,
clears consumed args and defers preparation to the runtime's application lock.
The strong composition now uses `StartOwner` self-exec through the real standalone
parser, then actual lock-busy physical attachment. Source race/vet: owner17.295s,
launch2.099s (`/tmp/bee-detached-owner-start-check.log`).

Pushed `bee6da5` to `checkpoint/native-client-binding-20260910`. Isolated retest
passes owner16.212s and launch2.089s (`/tmp/bee-owner-launch-checkpoint-check.log`).
No PR/main merge or global install. Fixture headless entry and activation/policies
remain selected explicitly; ordinary first-launch discovery/readiness and
production assembly are still unfinished. Runtime journal586 reviewed: transport
config validation progressed, but no boot activation/cutover handoff yet.

### Automatic native first launch and reuse pass

`NewLauncher` now composes the default foreground client and explicit start.
A detached owner contender uses the real runtime lock; a loser verifies the
existing owner through `session.Probe` (no mount). The foreground waits for new
publication or successful loser exit, then admits one fresh client. Unchanged
stale hints and failed child startup cannot authorize fallback.

The actual-source proof passes automatic reuse of the retained shell and cold
startup from empty state, including physical input and Ctrl+] detach. Foreground
bundle/data bindings deliberately invalid to catch unintended parent owner boot.
Composite race/vet37.298s (`/tmp/bee-automatic-first-launch-check.log`); launch and
session checks also pass (`/tmp/bee-automatic-owner-reuse-check.log`).
No runtime/global changes. Production entries/assembly/global acceptance remain;
fixture activation, naming/execute policies and wait command still supplied.
New automatic changes are not yet pushed; previous checkpoint is `bee6da5`.

### Production assembly and combined-runtime requirement

Production source now owns activation, the `bee-owner` wait command and the
supervisor naming/execute policies. The single `native/desktop.Component` factory
composes owner, Hive service, client launcher and I/O. Real-source proof passes
37.759s; isolated native checkpoint retest34.557s. Pushed `7be760e`, native module
`v0.0.0-20260910053029-7be760ef1749`.

Built `/tmp/bee-wippy-production-owner-candidate` from runtime944736c999 and that
module. Its lint fails `bee.terminal:display:54: no method clipboard`. The existing
selection runtime5708a6e829 provides clipboard/text support but lacks the launch
API file required by the new native factory. A reviewed combination is required
from the runtime lane; Bee made no runtime edits. Exact lint log:
`/tmp/bee-production-factory-lint.log`. Frozen build:
`/tmp/bee-native-production-assembly-3eclldgu`.

Old ioevents-only toolchains cannot boot the new activation kind: full check
stopped at its handler timeout (`/tmp/bee-production-foundation-check.log`).
Do not install either incomplete combination as global Bee. Global remains the
previous selection-enabled binary. Full checks/standalone build resume with a
combined runtime plus the desktop native factory.

### Concurrent start converges

Reproduced the losing start exiting before the winner publishes while held in
lock-owned preparation for one second (`/tmp/bee-concurrent-start-before.log`).
Probe now waits for missing discovery inside its existing 15-second budget,
without creating owner state; corruption/permission errors remain immediate.

The real factory/source test proves two starts leave one live lock-owning child
and a successfully verified loser. Full cold/reuse/retained/physical/concurrent
race/vet50.579s; session1.138s (`/tmp/bee-concurrent-start-after.log`). Pushed native
checkpoint `8becc91`. Global/runtime unchanged. Journal594's combined-runtime
requirement still applies; no new runtime handoff observed this turn.

### Signal exit and retained rejoin verified

SIGTERM acceptance exposed concurrent presentation/actor/transport cancellation: stale detach refusals and viewport revocation raced cleanup. Merely skipping detach was insufficient. The session now stops presentation first while retaining native admission/transport for at most three seconds to detach and restore the terminal, then retires the actor. Credential fencing and operation errors remain.

Real cold/reuse/concurrent/signal/rejoin race/vet56.376s (`/tmp/bee-signal-ordered-cleanup-check.log`); cleanup bound race/vet4.139s (`/tmp/bee-session-cleanup-bound-check.log`). Pushed `ed0ce07`. No runtime/global changes. Runtime journal593 reviewed:100-node stack proof progressed but no combined clipboard/launch candidate was handed off; journal594 gate remains.

### Empty desktop and cancellation delivery distinction

The actual-source composition proof now starts the cold owner with no initial
application, opens Terminal through F1/Start and verifies retained state after
rejoin. Full composition race/vet passes56.448s
(`/tmp/bee-empty-default-desktop-check.log`); physical race/vet passes1.027s
(`/tmp/bee-typed-delivery-check.log`).

Local observation cancellation is distinguished from external mount revocation.
Input/resize failures carry a typed DeliveryError and remain visible even if
cancellation races the reply. Signal acceptance allows the specific interrupted
mount-expired delivery error, while still requiring terminal restoration and a
fresh retained-shell rejoin; it does not claim every signal exit is error-free.

Global Bee remains SHA256
`1b71dff9845e25fe1bb3033d18ef1aed25c7dd65fbb21cdd30ae4b2c6a6da008`.
Runtime journal599–600 report transport hardening, not a combined launcher and
clipboard candidate. No runtime edits or global replacement were made.

### Physical copy audit and journal episode rotation

Checkpoint `d99bdac` is pushed. The headless copy path still terminates at a
virtual surface; combining runtime APIs alone does not enable physical copy.
Native Hive calls currently consume and discard unrelated inbox topics, so a
second reader would race replies. The next Bee slice needs one bounded session
dispatcher and attachment-qualified one-shot copy. Encoded JSON must fit the
16KiB actor bound even when 8KiB text expands under escaping. See
`TEXT_SELECTION.md` for evidence and acceptance requirements.

The journal required its eight-hour episode rotation. Old cursor
`jc_1HYZK1CTT9212` checkpointed at603 and closed604; new cursor
`jc_H7E57Z5SJH71M` opened605, same Bee Harness journal and graph/root.

### Bounded client inbox checkpoint

Pushed `003fe91`: one native actor reader separates Hive replies from clipboard
requests into two bounded eight-message queues. Routing grants no authority.
Overflow retires the binding and physical input/presentation; close joins the
reader after detach. Hive/session race+vet pass1.056s/4.148s; real-source owner
composition passes55.502s (`/tmp/bee-inbox-composition-check.log`).

Copy authorization, retained-owner routing, physical submission and results are
still pending. This does not enable clipboard in the headless client. No runtime
edits or global replacement. Current journal cursor `jc_H7E57Z5SJH71M`.

### Session-qualified Copy replaces the push experiment

Pushed native-only checkpoint `918563f`. The physical client's explicit Ctrl+C
requests `bee.desktop:copy` on its exact admitted session. The retained supervisor
queues a correlated `bee.copy` key marker behind prior input, then checks its
pending request, recipient and mount before replying. The marker orders work;
it grants no authority. The presenter consumes it and returns the frozen text.
Native decoding and the final mount check fence output to the requesting client.
No selection forwards ordinary Ctrl+C once. Definite selection refusal is visible
without disconnect; uncertain results never replay. Copy key releases are consumed.

The unsolicited inbox from `003fe91` was removed because copy needs no push path.
No runtime edits. The native checkpoint requires the updated external Bee source;
its owner protocol, client/presenter and pure decoder changes remain in this
shared checkout. Full selected-window copy through the new launcher is not yet
proved, and observer-local selection remains pending.

Checks: strict lint315; source/pack architecture517; Wippy pure decoder3/3;
physical clipboard race/vet1.036s on the selection runtime; Hive/session1.059s/
4.138s and full actual-source composition58.096s on the launcher runtime.
Logs: `/tmp/bee-copy-output-complete.log`, `/tmp/bee-copy-final-binding.log`,
`/tmp/bee-copy-final-composition.log`, `/tmp/bee-copy-final-pack.log`, and
`/tmp/bee-copy-refusal-lua.log`. Full `make test` still stops at the old toolchain's
missing Hive activation listener (`/tmp/bee-copy-lua-check.log`).

Global Bee remains unchanged, SHA256
`1b71dff9845e25fe1bb3033d18ef1aed25c7dd65fbb21cdd30ae4b2c6a6da008`.
Runtime journal611–614 reports cluster progress, not the required combined
launcher/selection candidate. Current journal cursor: `jc_H7E57Z5SJH71M`.

### Clipboard cancellation and real-owner denial

Pushed native checkpoint `1d977fb`. A deterministic test reproduced a clipboard
write after cancellation during native grant checking; physical output now
rechecks cancellation after that check. Physical race/vet passes1.039s. Evidence:
`/tmp/bee-copy-cancel-check-before.log` and `/tmp/bee-copy-cancel-check-after.log`.

Expanded real-source composition passes60.585s
(`/tmp/bee-copy-owner-denial-check.log`): a second native stack/client observes
but Copy is DENIED, substituted session is DENIED, retired session is NOT_FOUND,
and the controller retains working shell input. This proves the owner denies
those requests, not observer-local selection. Global/runtime remain unchanged;
the combined launcher/selection runtime and selected-window acceptance are still
required before release. Cursor remains `jc_H7E57Z5SJH71M`.

### Full selected-window acceptance checkpoint

Pushed native-only checkpoint `bf6b54f` on
`checkpoint/native-client-binding-20260910`. It requires current external Bee
source through `BEE_OWNER_TEST_SOURCE`. `local-owner-selection-check` drives
rendered selection, immediate Ctrl+C, exact clipboard output, continued input
and reconnect without replay. Its compiled-runtime prerequisite fails explicitly:
launcher `944736c999` lacks `tty.text.plain` and physical `Clipboard`. The full
selection path remains unverified (`/tmp/bee-selection-target-gate.log`).

Ordinary owner/client composition remains green at 61.786s after the harness
changes (`/tmp/bee-selection-gate-baseline.log`). Runtime journal through 621
contains no combined launcher/selection candidate. Both runtime checkout HEADs
remain unchanged. No runtime edits or global installation occurred. The global
executable is on PATH with the same SHA256 recorded above; automatic owner/client
launch and the embedded-default/overlay upgrade remain release gates.

### Upgrade regression preserves a nondefault Settings value

`tests/native_upgrade.py` now selects Ocean through the old binary's Settings UI,
requires a populated identity and migration ledger, and checks Ocean after launching
the new binary. The Sep 8 rollback versus installed global run passes those
preconditions and Settings recovery, then fails at the missing Hive Manager as
expected. Evidence: `/tmp/bee-upgrade-settings-check.log`. This separates retained
Settings from the stale deployment catalog; the full upgrade remains red.
The test change remains in the shared Bee checkout, outside the native-only
checkpoint branch. No runtime, global binary or user store was modified.

### Global owner/client candidate installed — journal 686

The user authorized assembling the combined runtime and opening required PRs.
Runtime `674b58a1a1` now combines native launch with plain text, clipboard,
scrollback, fragmented input and embedded-default deployment selection. Runtime
PR [726](https://github.com/wippyai/runtime/pull/726) is stacked on launch PR 703
and assigned to Rodrigo (`skhaz`); nothing was merged.

Bee native `70441e040ed2` adds embedded-default selection. Preceding checkpoints
fix Ctrl+Q local detach and honor the native scheduler's typed cancellation, so
client exit no longer waits for the shutdown grace. Mesh/physical race tests pass.
Frozen source is `/tmp/bee-global-final-crjl7na9`. The actual standalone binary
passes cold startup, clipboard, wheel/burst scrolling, retained shell and F12,
explicit app/alias launches, and upgrade from the Sep 8 binary with Ocean Settings,
workspace identity and applied migrations retained. Registry history tests also
prove an authored entry survives a changed baseline. Evidence:
`/tmp/bee-final-binary-acceptance.log`, `/tmp/bee-combined-baseline-overlay.log`.

Installed `/home/wolfy-j/.local/bin/bee` SHA256:
`19d62d1771dda864b4040d00b6563af9edee155a574a90bf335daa8543a3cdbd`.
Rollback: `/home/wolfy-j/.local/bin/bee.rollback-20260910T133445Z`.
The broader frozen `make check` continues in `/tmp/bee-final-full-check.log`;
no final passing foundation-suite claim yet. Public external enrollment,
independent observer selection and runtime-main release remain unfinished.

## 2026-09-10 — Native client slow-exit correction

Codex reproduced a 3.9-second physical exit with a stalled test owner. Native
`f02e10111c36` bounds detach acknowledgment to 200 ms; uncertainty is preserved
and the native actor retires for eventual owner monitor cleanup. Session race
tests/vet and actual standalone client acceptance pass, including the new stalled
owner regression (exit within two seconds, terminal restored, owner alive).
Global Bee updated atomically; see GLOBAL_BUILD.md for exact digest and rollback.
Private copies of user state passed --base and ordinary boot, five large-terminal
reconnects and 45 seconds idle. Unexpected mount retirement is not reproduced;
immediate reconnect after abrupt death can still encounter a controller busy
refusal. Full make check failed at drag_failure initial blank-frame wait. No
user owner was stopped and no user database was modified by these probes.

## 2026-09-10 — Warm launch and reproducible crashed-owner failure

Codex installed native `08a5761b809d` with unchanged runtime `674b58a1a1`.
The runtime application lock routes warm launch directly to admission, avoiding
the redundant owner contender, read-only probe and per-invocation log. Actual
standalone retained desktop readiness measured 0.204s; launch race/vet and full
native-client acceptance pass. GLOBAL_BUILD.md records digest and rollback.
The broader crash test now reproduces the user's failure: controller busy after
SIGKILL, then readiness timeouts after roughly30s. Test-only owner stack captured
at /tmp/bee-crashed-client-owner-stack.txt. Luna is investigating the cause;
production crash recovery is not fixed. No user process was stopped. Cold-start
file-based error reporting remains to be corrected.

## 2026-09-10 — Current remote-monitor failure verified

Luna reran `make -C native mesh-monitor-check` against the exact combined runtime
`674b58a1a1`: exit2, missing EXIT after completed native client actor, with a FIFO
barrier and transport kept alive. Runtime handoff recorded at Bee Harness698.
This explains the unreleased controller after crash; the later supervisor retry
and owner-readiness timeout still need service-specific evidence. A diagnostic
subscriber is being added only to a disposable native test helper. Current
status docs now distinguish explicit-detach reconnect from unsupported reliable
crash cleanup, and record the failing full-suite initial-frame wait accurately.

## 2026-09-10 — Preparing-owner startup race fixed and installed

Codex installed native1abf5b28a0e5 with unchanged runtime674b58a1a1. Direct warm
attachment now waits for discovery publication if the owner already holds the
runtime lock but is still preparing. The actual old-binary test failed on missing
mesh-owner.json; the new standalone test passes waiting, publication, admission,
physical quit and retained owner. Warm readiness0.208s, full native-client target
passes alongside session/launcher race/vet. See GLOBAL_BUILD.md for hash/rollback.
Remote monitor gate remains red and handed to runtime lane at journal698.


## 2026-09-10 — PR716 closed; responsive Hive candidate

Runtime PR716 is closed without merge by explicit user direction. Bee runtime
674b58a1 does not include its remote subsystem, and the cluster lane retains
responsibility for native lifecycle work. Journal791 records the closure.

Hive Manager now draws known local supervisor/membership state before querying
peers. Source/pack delayed-query checks prove input and close remain responsive.
The standalone candidate and idle-reconnect checks pass; see GLOBAL_BUILD.md
for installation and full-gate status. The user's recurring retained-Bee
attachment failure was recovered by an authorized restart, but its cause is
still unproven (journal784). The pinned runtime's generic revoked-mount error
can mask an earlier viewport RPC error (journal787); no runtime workaround was
added. Continue using journal handle jc_H7E57Z5SJH71M for this Bee lane.


## 2026-09-10 — Responsive Hive Manager installed globally

The complete foundation run passed (485 Lua tests, 517 source/pack entries,
new desktop-store migration/bootstrap, recovery and UI gates). The standalone
and repeatable idle-reconnect gates passed. Global bee now has SHA256
53c7ce500d06546cbf44df6656dc6aee308374bb06de2da2a4d39634d76af1d0,
from production checkpoint ad23c45 and unchanged native/runtime pins.
The user's Bee was restarted with saved state preserved: desktop1.323s,
reconnect0.131s, detach0.113s. Installed Hive Manager first frame1.030s in the
isolated Start-menu smoke. Current Bee PID552200 is recorded in
/tmp/bee-current-user-owner-pid. See GLOBAL_BUILD.md for evidence paths.
The recurring viewport/connection failure remains unproven; this is not a
claim that the UI scheduling change fixed transport recovery.

## 2026-09-10 — Physical crash recovery separated from node reincarnation

Pinned runtime674b58a1 and the compiled native client pass the physical
SIGKILL/rejoin proof with a single replacement mesh process. The destination
shell and its variable survive; detach and terminal settings restore correctly.
Evidence: /tmp/bee-mesh-physical-crash-proof-r3.log (session24761, exit 0).
The test allows the established 40-second node-departure window; it does not
prove immediate actor exit. A five-second retry bound still refused the new
controller (r2 log, session71589, exit2).

The earlier Python retry restarted node-2 after each admission refusal, causing
same-name/new-port membership conflicts (original crash log, session30640,
exit2; this corrects seq797's provisional session label). Retries now stay in
one compiled fixture process, apply only to typed explicit negative receipts,
and never replay uncertain outcomes. Native runtime code is unchanged. The
same-name rejoin issue and user's intermittent retained-Bee mount failure remain
unresolved. Global binary is unchanged pending the membership UI build/gates.

## 2026-09-10 — Membership UI installed, complete gate pending

Global bee SHA dd674d645a59bd9ec3708ac2626e225f0934e0eed68c0d0912df5de4f2550eeb
is installed from source7d4a7f1 with unchanged runtime/native production pins.
Standalone checks and the actual Hive Manager smoke pass. User stores survived
the authorized restart; PID839818, first frame1.398s, warm reconnect0.225s,
detach0.109s. See GLOBAL_BUILD.md. Shared journal checkpoint805.
Full foundation check69756 remains running; poll it before claiming a pass.

## 2026-09-10 — Two native physical presentations share one retained shell

The observer variant of hive-desktop-admission-check passes on runtime674b58a1
with the race-enabled native fixture. One controller and one separately enrolled
observer have separate PTYs; both see the same shell variable. Native input and
resize checks deny observer authority, observer typing does not mutate the shell,
and observer detach preserves the controller. F12 and resize retain the shell.
Evidence /tmp/bee-mesh-observer-proof.log, session44191 exit 0 (57.62s test).
Only test harnesses/docs changed; public observer/desktop selection remains open.

## 2026-09-10 — Public bee observe installed

Global Bee SHA c1f5d871f419b1bffa08e5dc3aa978e90a65e4bb687f83adf0c973571d69a94d
adds `bee observe`: read-only same-account presentation of the existing desktop.
No running Bee means prompt refusal; no new owner, database or application is
created. Controller input continues after observer detach. Native launch race/vet,
public observer acceptance and complete standalone client/binary suites pass.
See GLOBAL_BUILD.md and shared journal810 for exact evidence.

Installation was atomic and did not restart retained PID839818. Its `/proc/exe`
now names the old unlinked image, so the earlier restart helper's exact executable
path assertion must be revised against verified binary identity before reuse.
Installed observer0.221s, detach0.081s. Runtime remains674b58a1; native pin142e753.
Full foundation check69756 still running; do not report it passed until terminal.


## 2026-09-10 — Foundation run completed successfully

Session69756 is terminal exit 0; do not poll it again. Full make check passes:
486 Lua tests, 517 source/pack entries, storage and migration proofs, source/pack
UI/client/launcher/recovery and bundled apps. 16-window exit 0.323s. All 365 frozen
production files match the installed observer build. Native observer race/vet and
standalone checks passed separately. Evidence /tmp/bee-membership-foundation-check.log;
shared journal813 supersedes the earlier pending-gate notes. The full goal remains
open for public external enrollment, desktop selection, immediate crash recovery,
and the recurring retained-Bee viewport failure.

## 2026-09-10 — Durable desktop catalog ready for supervisor integration

The private client store now lists `{desktop_id, is_default}` using one bounded
query, default first and stable ID ordering. No layout content, availability or
permissions are inferred. Selected-desktop/closed handles refuse the operation;
ambiguous IDs and excess rows fail without partial output. No migration or
permission change. Source/pack catalog restart, capacity, corruption and populated
upgrade checks pass via make client-storage-check (session90810, exit0), with
lint clean (session12982, exit0). Evidence /tmp/bee-desktop-catalog-storage.log.
Public allocation and selection still require integration into the supervisor;
the existing global binary and running Bee are unchanged.

## 2026-09-10 — Scoped storage methods and window-retirement correction

The real source/pack function test passes for bee.client:list_desktops and
bee.client:allocate_desktop: exact resource grants, separate read/write authority,
caller SQL denial before/after, no schema creation on denied calls, durable retries,
default-ID conflict and strict inputs. No current app/supervisor gained these grants.
Evidence /tmp/bee-desktop-storage-authority-check.log, session11407 exit0.

Full catalog run57240 ended exit2 in Process Manager's Settings-stop check:
Settings was removed but its revoked-view message survived. The presenter now
retires delivery on committed scene removal as well as close replies, and binds
view errors to their window identity. A deterministic injected-failure regression
fails on the old presenter (41881 exit2) and passes on fixed source/pack (58455
exit0); the original Process Manager source/pack check passes (32780 exit0).
Initial regression setups41231/5316 failed at foreground selection and are not
causal evidence; the final probe closes Settings through its window menu.
No runtime changes; this is not a fix for the distinct retained-node mesh failure.
The installed observer binary is unchanged. Combined full verification is next.

## 2026-09-10 — Combined candidate built; full gate remains active

Checkpoints27b4f0c (scoped desktop operations) and089e1c2 (window retirement) are
pushed. The uninstalled candidate /tmp/bee-retirement-global-candidate has SHA
 d65ff9000d0949f5e6a5bf17d551ba886e243ad1d95890f08d1d177c7d224632.
Standalone session6869 exited0. The additional function-level capacity/retry proof
session96064 exited0; it is a test-only addition after the frozen source snapshot.
Full make check38854 remains live in /tmp/bee-desktop-authority-check-089e1c2;
output /tmp/bee-desktop-authority-foundation-check.log. Poll that same handle.
Global c1f5d8 and retainedPID839818 remain unchanged. Shared journal823.

## 2026-09-10 — Combined candidate installed and actual-user launch verified

Full `make check` session38854 exited0: 486 Lua tests, 519 source/pack entries,
storage and migration proofs, delivery failures, window retirement, desktop and
launcher recovery, and bundled apps all passed. Evidence:
`/tmp/bee-desktop-authority-foundation-check.log`. Native standalone session6869
and the additional scoped allocation-capacity check96064 had already passed.

Global `/home/wolfy-j/.local/bin/bee` now has SHA256
`d65ff9000d0949f5e6a5bf17d551ba886e243ad1d95890f08d1d177c7d224632`.
It uses source089e1c2, native142e753 and runtime674b58a1; later checkpoint changes
are documentation and the separately verified capacity test. No runtime change.
The previous executable is archived as `bee.previous-20260910T203656Z`.

The verified retained process839818 was stopped and replaced by1322000, whose
executable digest matches the installed binary. Existing databases were preserved.
Actual-user cold startup reached the Bee header in1.568s; warm control in0.222s;
observe in0.219s. Detach took0.085s,0.091s and0.086s respectively. Evidence:
`/tmp/bee-retirement-user-install.log` and
`/tmp/bee-retirement-user-reconnect.log`.

The installed presenter now retires a removed window's attachment and its own
error. Protected desktop catalog/allocation methods are installed, but public
creation/selection is not yet wired. Whole-client mesh disconnection, immediate
crash/rejoin and external enrollment remain separate unfinished boundaries.

## 2026-09-10 — Retained supervisor storage adapter (source only)

Checkpoint6b0b545 connects the retained actor to protected catalog/allocation
functions asynchronously, with exact default-client-resource grants, a single
pending request, strict result decoding and a five-second uncertain timeout.
Normal and deliberately slow source/pack probes passed58228. Physical attachment
and shell input continue while storage is delayed; late completion cannot satisfy
a subsequent correlation. Reply delivery failure is logged without killing the
desktop. No public extra-desktop activation is claimed.

Full make check9543 is active in /tmp/bee-supervisor-catalog-full-check;
log /tmp/bee-supervisor-catalog-full-check.log. Poll that handle, do not restart it.
Global d65ff900 and retainedPID1322000 remain on the previously verified build.
Journal830 records this checkpoint. The screenshot's second-controller refusal
remains: next work is additional desktop activation on the existing host, followed
by public selection. Hive Manager has no authoritative display-only-role field;
do not infer that role from a node-name prefix or relabel a failed service query
as confirmed service health.

## 2026-09-10 — Additional desktop activation checkpoint

be1a22a is pushed. Normal and slow source/pack retained-desktop checks82600 pass:
allocated identity activation/replay, separate Terminals on one host, additional
F12, desktop save/reactivation with the same live shell, and first-desktop
continuity. The public Hive owner still publishes one desktop, so second-bee
automatic creation is not implemented or installed. Named desktops use independent
appearance; only the default uses legacy workspace-appearance bootstrap.

Full activation check87444 is live in /tmp/bee-desktop-activation-full-check,
log /tmp/bee-desktop-activation-full-check.log. The earlier storage-only check9543
is separately live in /tmp/bee-supervisor-catalog-full-check. Poll each exact
handle; their source snapshots differ. Global d65ff900/PID1322000 is unchanged.
Journal833 has details and failed approaches. Before exposing the public route,
audit pending copy/launch cleanup on an additional child EXIT and primary-phase
gating of additional lifecycle messages. Next: Hive catalog/session target mapping,
then native creation/selection on controller conflict, with public binary proof.

## 2026-09-10 — Desktop interruption and renderer independence

22416ff is pushed. Launch-exit baseline35278 failed with a missing reply; fixed
source/pack26258 passes and the launched Terminal's file proves the operation
committed before its reply was lost. Pending launch is retired as UNCERTAIN, and
the Hive adapter preserves its operation/idempotency identity. Copy-exit39312
passes: no text returned, slot cleared, next desktop copy succeeds.

Primary-render delay baseline85514 on be1a22a failed to replace the additional
presenter. Fixed source/pack58849 passes: additional F12 while the primary reply
is withheld, then primary timeout/F12 recovery. The default now keeps bounded
latest deferred renderer/quit values while additional lifecycle messages continue.

Full runs9543 (storage snapshot6b0b545) and87444 (activation snapshotbe1a22a)
remain live; they do not cover these subsequent changes. Preserve/poll their
separate logs/handles. The pinned linter exits0 but reports an InterprocFacts
convergence warning for desktop_lifecycle; evidence is preserved in
/tmp/bee-desktop-lifecycle-cleanup-lint.log. No cache reset or runtime edit.
Global d65ff900/PID1322000 remains unchanged. Journal836. Public catalog/create/
selection is the next integration boundary; second bee is not fixed in the
installed launcher yet.

## 2026-09-10 — Public second-launch diagnosis and bootstrap permission

Journal838: the installed launcher still reads a singleton default desktop catalog
and requests control of it. An existing controller is refused correctly, but the
Hive adapter maps that busy result to UNAVAILABLE. Public selection/creation is
unfinished; additional-desktop source fixtures do not establish that public path.
The unavailable mesh member in the screenshot has no authoritative display-only
role evidence; do not classify it by its node name.

Fixed the source Hive desktop host policy to allow fetching the two exact catalog
policies already selected by owner.start. Added a policy test covering those grants
and denial of unrelated policy reads, direct client SQL, and direct allocation.
Validation is running as session30491, /tmp/bee-desktop-bootstrap-policy-test.log;
no pass or global installation claim yet. No runtime edits.

Storage-only full check9543 completed exit0; its log ends with all app checks
passing. Activation snapshot87444 was still live at the latest poll. Neither
snapshot covers subsequent cleanup changes or this policy fix.

## 2026-09-10 — Hive catalog/create and selected-desktop sessions

The source Hive adapter now lists allocated identities with explicit is_default,
allocates caller-retained identities through bee.desktop:create, activates an
existing selected identity for control, and qualifies every session, cleanup,
launch and copy by its desktop. Observe never activates a dormant record.
Controller collision maps to BUSY and releases the definitely ungranted client
record immediately; unknown outcomes still retain cleanup responsibility.
Create requires desktop_id as its idempotency key; its durable allocation is the
retry authority, not an in-memory receipt. One asynchronous catalog slot is
bounded, timeout distinguishes reads from uncertain writes, and late replies
cannot settle a successor. Exact bootstrap catalog-policy reads are now granted.

Native91c4177 is pushed on checkpoint/native-client-binding-20260910. The manifest
pins v0.0.0-20260910213324-91c4177e461e. It adds strict Create, optional explicit
catalog defaults (legacy catalogs stay readable), default selection within a
single workspace, and bounded BUSY retries for catalog reads only. It does not
implement automatic desktop creation/selection after an attach collision.

Passing evidence: make test1538 (490 tests), source/pack architecture524, pack,
make hive-desktop-catalog-check20135 (two actual runtimes, simultaneous controllers
on distinct desktops, allocation replay, dormant-observer refusal, cross-target
session denial, original shell continuity, explicit detach/reconnect), and native
binding/session race tests plus vet39884/76745. Logs:
/tmp/bee-public-desktop-lua-check-after.log,
/tmp/bee-public-desktop-catalog-after.log,
/tmp/bee-public-desktop-native-check.log,
/tmp/bee-public-desktop-session-check.log.
The linter retains the known desktop_lifecycle InterprocFacts warning.

Preserved failures: full admission88925 passed the new probe then failed recovery
after remote actor crash (old controller still held); /tmp/bee-public-desktop-admission.log.
The separate catalog gate does not waive that existing runtime gate. Initial
simultaneous fixture7019 lacked process.spawn in its test-only scope; corrected
without changing production grants. Initial new unit test80022 used unsupported
qualified generic syntax; diagnostic JSON is preserved at
/tmp/bee-public-desktop-lua-diagnostic.json, and a Channel type alias fixed it.

Earlier full snapshots9543 (storage) and87444 (activation) both completed exit0.
Neither covers this new Hive route. Global d65ff900/PID1322000 is unchanged.
Remaining: automatic public second-client selection/reuse, actual executable
multi-client proof and full combined foundation validation before installation.

Bee8a1180e is pushed; Journal841 records the above. Full combined foundation
validation is now running on that frozen source in
/tmp/bee-public-desktop-full-check, session2617,
log /tmp/bee-public-desktop-full-check.log. Poll the same handle; do not restart
on an observation timeout. This run includes the public Hive adapter and all
prior retained-desktop cleanup changes, unlike completed snapshots9543/87444.
The two-node catalog gate20135 remains separate from make check and passed.

## 2026-09-10 — Codex: cold-node patience and quit/presenter correction (in progress)

User accepts a 60-second connection allowance for cold/flaky nodes. Source now
extends native mesh startup, supervisor readiness, attachment admission and Hive
call ceilings to 60 seconds; local publication and bounded detach retain their
existing limits. Successful calls do not wait out the deadline. The launch text
is `Connecting to Hive…`. This is not installed; reconnect presentation and the
reported current global hang remain unresolved.

The combined source acceptance found a real F12-during-quit deadlock: replacement
was deferred while quit waited for the presenter to answer its confirmation.
The source permits replacement during the dialog and defers accepted shutdown
until an in-flight renderer bind settles, preserving its request correlation.
The strengthened check requires a changed presenter identity before answering.
Evidence is pending in `/tmp/bee-close-confirm-render-fix.log`; native deadline
checks run in `/tmp/bee-node-deadline-check.log`.

User direction for the Hub lane: Bees can specialize, including a remote storage
Bee configured through governed installation and exposed typed operations.
Supervisor authorization/dispatch must stay asynchronous and bounded; application
workers own storage work, with correlated replies, cancellation and explicit retry
semantics. This is a requirement, not a claim that public remote installation or
recovery is complete. Mac/Linux catalog acceptance passed in the preceding unit;
its added owner-OS/file assertion still needs rerunning.

### Verified checkpoint f227945 / native 9750955

Close-dialog source/pack acceptance and all five retained-desktop fault variants
passed, including replacement while the primary renderer is stalled. Native
session, Hive, launch, mesh and physical race/vet checks passed. The mesh lifetime
fixture now outlives the 60-second startup deadline, proving admission disarms
that timer. The Mac/Linux catalog proof also passed with destination OS and
owner-only file evidence. Both checkpoint branches were pushed.

Standalone candidate `/tmp/bee-independent-desktops-candidate` built successfully
(SHA256 `49ea75a692680d8cc20a3a34035ecd23f9fd0ed9bab3fbe830dc3da4ba88bd74`).
Its three-desktop executable acceptance passed: simultaneous control, default
observer, F12 and reuse without allocating another identity. The broader native
suite first caught stale expected `Connecting to Bee` wording in its test; the
test now expects `Connecting to Hive` and is rerunning. Full frozen source
acceptance is running at `/tmp/bee-independent-desktops-full-check`, session 90930.
Global installation is still pending. Actual-user reconnect on the old global
binary remained stuck at 15 seconds; no root-cause claim is made.

### Global installed after native executable acceptance

Native launcher suite passed in full. Global Bee now has candidate SHA256
`49ea75a692680d8cc20a3a34035ecd23f9fd0ed9bab3fbe830dc3da4ba88bd74`, from source
f227945, native 9750955, runtime 674b58a1. Verified old process 1322000 was stopped
through its pidfd; no database was deleted. Previous binary was archived beside
the global executable. Actual-user cold frame took 1.572s and detach 0.103s; new
retained process is 1992601. Warm/observe evidence is in
`/tmp/bee-independent-global-reconnect.log`. Full repository gate remains running
(session 90930); the old idle-disconnection cause remains open. Journal fact 851.

### Idle reconnect evidence and lane coordination

Eight fresh physical clients rejoined one retained Bee after 20-second idle gaps;
all took 0.214–0.223s, retained the same Terminal variable and detached within one
second (`/tmp/bee-independent-idle-reconnects.log`, exit 0). This short soak does
not explain or resolve the former hour-old user's connection hang. Full frozen
source acceptance remains live at session 90930; source/pack storage, resources,
architecture and desktop smoke have passed.

Journal 852 assigns generic native mesh Stream work to the runtime lane; journal
853 assigns the private registry planner to another Bee agent. This lane remains
launch, client attachment and reconnect. Client-side 60-second connection/call
ceilings do not change destination operation limits, membership death detection,
or establish automatic live recovery. Journal evidence 856.

### Compact Hive UI installed — September 10

Global Bee is now source 9b58e4f, native 5172d7dc2396, runtime 674b58a1.
SHA256: `18ae084a81ade1deb9b71ed0108909449d5f1cdbc6e9ad2bd619721cdd4cb21c`.
The previous executable was archived and process 1992601 was verified and stopped
through its pidfd. Databases were preserved; retained process is now 2137218.
Actual-user cold frame: 1.558s; detach: 0.113s.

F9 or the workspace label opens a read-only Hive/node/workspace/display dropdown.
Hive Manager distinguishes explicitly advertised display clients from services,
keeps compact readiness counts, and moves full IDs/addresses to Details. Client
metadata suppresses irrelevant service probes; it never grants access. Native UI
acceptance and visual review passed. Shared Lua: 495 tests passed.

The earlier f227945 full check finished successfully (490 tests, 524 entries).
The newer frozen UI full check is running: session 31926,
`/tmp/bee-hive-role-full-check.log`; its first invocation failed because the
isolated worktree had no default runtime binary, then was rerun with the explicit
candidate runtime. Two 600-second idle reconnects passed in 0.241s and 0.235s,
retaining the same shell. This does not resolve the earlier hour-idle hang.
Both checkpoint branches are pushed; no runtime changes or main merge.

### UI safety follow-up and preserved full-gate failure

Installed UI source full gate 31926 is terminal exit 2. Lua/storage passed, then
Process Manager acceptance proved unmodified-F9 handling was also swallowing
Alt+F9 minimize. The source now checks modifiers explicitly. Failed evidence:
`/tmp/bee-hive-role-full-check.log`.

A separate confirmation regression proved the old app attached a replacement
desktop after asking about the original. The pure model now previews without
pending state and compares node/workspace/desktop/owner generation on confirmation.
The app retains the exact proposed intent through its question. The old source
failed with the wrong fixture-session receipt; fixed source and pack pass, as do
all 19 Hive Manager Lua tests. These changes add no catalog or attachment grants.
Live app catalog browsing still needs an authorized read contract; do not expose
the native-client route indiscriminately. Journal evidence 881.

### Corrected UI installed after native acceptance

Global SHA256 `440890d7fec500ccc16b799e73c9e166c35d023a8c27731ed55226d83a291951`,
production source 0b44b0f (a90f1b4 adds executable Alt+F9 verification), native
5172d7dc2396, runtime 674b58a1. Alt+F9 Process Manager acceptance passes source
and pack; native Hive Manager minimizes/restores and F9/reconnect status passes.
Exact-target confirmation regression passes source and pack; 19 focused Lua tests
pass. The previous global and verified process 2137218 were retired with the
same guarded install; databases remain. New retained process: 2197478.
Actual-user cold frame 4.027s, detach 0.141s; no timing-cause claim.
Full corrected frozen check session 46307 remains active, log
`/tmp/bee-hive-safe-full-check.log`. Do not rerun the terminal failed31926.
Checkpoint branch `checkpoint/hive-confirmation-20260910` is pushed.

### Full UI gate coverage and one-hour idle diagnostic

Checkpoint ea6ff95 moves the connection dropdown acceptance into `desktop-check`,
so `make check` includes it. Production source remains the installed 0b44b0f.
Full run 46307 has passed Lua, architecture (525 entries), storage, thread
subscription restart and resource checks, and has entered desktop acceptance.
Native documentation-only checkpoint 15631f7 corrects installed behavior and
deadline descriptions; the executable's native pin remains 5172d7dc2396.

One-hour idle reconnect diagnostic 50459 is live, log `/tmp/bee-one-hour-idle.log`,
script `/tmp/bee-one-hour-idle.py`. It uses `/tmp/bee-hive-safe-candidate` and
disposable state `/tmp/bee-retained-reconnect-soak-_4xcpep_`. Initial Terminal
state is retained; after 3600 seconds it will allow 65 seconds to observe rejoin.
This is pending evidence, not a claim that the earlier hour-idle hang is fixed.
The actual user's Bee is untouched. Shared journal checkpoint 886.

### Neutral display identity follow-up

User reiterated multiple clients on one machine, each a neutral display choosing
a workspace. Display identity must remain independent of node/workspace choice.
The session attachment carries those targets; switching must not recreate apps.

Checkpoint c3b2c9f (`checkpoint/hive-session-identity-20260910`) qualifies Hive
Manager's session labels/control affordance by node and owner generation.
Matching workspace/display IDs on another node cannot inherit the first node's
session. Owner replacement and catalog removal retire stale labels, and delayed
old-owner outcomes cannot restore them. All 20 focused Wippy tests pass; source/
pack Hive Manager app, slow-query responsiveness and confirmation regressions
pass (69779 terminal exit 0, `/tmp/bee-hive-session-identity-app.log`).
This follow-up is not installed yet. Full old-source gate 46307 and hour-idle
diagnostic 50459 remain live; do not restart them. After 46307 finishes, run the
new source's full gate and executable verification before installing c3b2c9f.
Native manifest remains 5172d7dc2396; docs-only native head is 15631f7.
Global remains SHA440890d7..., retained PID2197478. Journal evidence890.

### Session identity executable acceptance

Isolated candidate `/tmp/bee-hive-session-identity-candidate` built from
3d149fe/c3b2c9f production source, native 5172d7dc2396 and runtime 674b58a1.
SHA256 `eddd5347ce277587541635f0b948ef7d6e3d1dc7b677be46044db6f8b9ced2b5`.
Build 20971 and native gate 84624 are terminal exit 0. Native status UI, three
independent desktops, first-controller continuity, default observer, F12 and
reconnect without new allocation pass. Logs: `/tmp/bee-hive-session-identity-native-ui.log`
and `/tmp/bee-hive-session-identity-desktops.log`. Candidate is not installed.
Full previous-source 46307 remains live, now Terminal acceptance after control
delivery, drag and window retirement. One-hour diagnostic 50459 remains live.
The next full-source run must use this isolated identity checkpoint, not the
shared checkout's unrelated new node/sync lane. No runtime implementation changed.

### Concurrent isolated full checks

The staged identity full check is now running as session 61042 in
`/tmp/bee-hive-session-identity-20260910`, log
`/tmp/bee-hive-session-identity-full-check.log`. Production is c3b2c9f; later
commits only record evidence. This supersedes the plan to wait for 46307 before
starting it: both runs have independent frozen source and disposable state.
The installed-source run 46307 passed navigation/selection/lifecycle and is
now in client-desktop acceptance. Its 16-window load fixture used 2% of one CPU
core and exited in 0.374s. Both full gates and hour-idle 50459 remain active.
Do not restart any of these jobs while their exact handles are live.

### Installed corrected UI full gate passed

Session 46307 is terminal exit 0. `/tmp/bee-hive-safe-full-check.log` proves
full make check for installed production 0b44b0f: 493 Lua tests, 525 registry
entries, source/pack dropdown, Alt+F9, exact-target confirmation, storage/journal
upgrades, permissions, client lifetimes, cold recovery and bundled app checks.
The existing desktop_lifecycle InterprocFacts convergence warning remains.
This does not waive runtime owner-isolation/session-loss recovery (journal894).
Global SHA440890d7... remains installed; no restart or reinstall this turn.
Newer candidate full 61042 and one-hour diagnostic 50459 remain live.
Do not poll/restart completed 46307. Journal milestone900.

### Explicit desktop selection candidate accepted locally

Native ced4008999f4 and runtime674b58a1 build successfully into
`/tmp/bee-explicit-desktop-candidate` (50939 exit0). Executable selection12947,
connection UI35638 and three independent desktops53275 pass. Exact selected
observation and retained-shell rejoin work; occupied/foreign selection refuses
without allocation, and the first controller remains usable. Initial43853 failed
because the fixture closed a descriptor twice; corrected cleanup passes.
Native session/launcher race and vet62001 passed before this build.
The commands remain candidate-only; global440890d7 is unchanged. Full61042 and
hour-idle50459 remain running. Live neutral-display workspace switching remains
unfinished. Journal902 records the staged boundary; the following evidence fact
records the executable results.

### Full explicit-selection native gate passed

Session74144 exited0; `/tmp/bee-explicit-desktop-client-check.log` covers cold/warm
launch, observation denial, three independent displays, named commands, clipboard,
F12, bounded stalled exit and client-crash retained-shell recovery. Candidate SHA
`cbb6d6a5bc71b5c37b281f2b3075122e990296c50830d641c8fa21939f389e59`.
Exact-selection rerun11198 passed after cleanup was made unconditional with
ExitStack. The old failed fixture2343130 was retired by exact pidfd/digest/state
checks. Checkpoint3688b8c specifies the still-unimplemented neutral-display
attachment boundary. Its production Lua is unchanged from the61042 full-gate
source. Full61042 and idle50459 remain running; global440890d7 is unchanged.
The guarded installer `/tmp/bee-install-explicit-selection.py` is prepared but
has not run. Do not reuse the previous install script with outdated digests.

### Global explicit-selection build installed — journal908

Full61042 is terminal exit0:494 Lua tests,525 registry entries, complete
foundation gates. Standalone79123 and native-client74144 also exited0.
Do not poll/restart those completed jobs. Global Bee now has SHA
`cbb6d6a5bc71b5c37b281f2b3075122e990296c50830d641c8fa21939f389e59`,
productionc3b2c9f/nativeced4008999f4/runtime674b58a1. Installer86645 exited0;
old2197478 was retired with exact identity/digest guards and current user Bee
is2452472. Databases preserved; archive `bee.previous-20260910T232822Z`.
Cold1.486s, warm.215s, observe.221s; all detach under.1s. Evidence:
`/tmp/bee-explicit-selection-global-install.log`,
`/tmp/bee-explicit-selection-global-reconnect.log`. Actual `bee desktops` lists
two durable targets. Shared native manifest now matches the verified build.
One-hour50459 is still live on the preceding immutable candidate. Workspace
switching, multi-host composition and public remote recovery remain incomplete.

### Fresh global reconnect failure — journal909

The user reproduced mount-expired/revoked and detach timeout on the newly
installed cbb6d6a5 binary. The same process2452472 then failed a read-only
`bee desktops` after60.045s. Evidence:
`/tmp/bee-user-failure-catalog-20260910.log`. Exact pidfd/executable/state checks
preceded SIGQUIT capture to `/tmp/bee-user-stuck-owner-2452472.stack` (432731 bytes).
The selected stack extract is `-selected.stack`. TLS reader was waiting for a
frame and writer was idle; no blocked TLS writer was established. Cause remains
unassigned; short passing acceptance is not proof this is fixed.
Same binary and databases restarted as2493278: cold1.439s, warm control.208s,
observe.209s, detach.078–.099s. Logs are `/tmp/bee-user-failure-restart-20260910.log`
and `/tmp/bee-user-failure-reconnect-20260910.log`.

Neutral-session branch `/tmp/bee-neutral-session-20260910` exists at65a5196 but
has no code changes. Refactor paused for the live failure. One-hour50459 still
runs untouched. New diagnostic99066 runs `/tmp/bee-hive-manager-idle.py`, logging
`/tmp/bee-hive-manager-idle.log`: Hive Manager retained plus another desktop,
ten60s detach/rejoin cycles, disposable state only, stack capture on failure.

Diagnostic correction:99066 exited1 during menu setup, not an idle failure.
Hive Manager is under Tools. The corrected87211 is live with its first60s idle
interval, log `/tmp/bee-hive-manager-idle-r2.log`, fixture
`/tmp/bee-hive-manager-idle-nhjncua8`. Do not treat the first fixture's dump as
user-failure evidence. Hour50459 remains live. Checkpointdcd0905 is pushed.

### Reconnect diagnostic follow-up — journal 913

Read-only `bee desktops` against the restored actual-user process returned both
displays in 0.208s (exit 0), without a restart or binary change. Evidence:
`/tmp/bee-user-catalog-followup-20260910.log`. Hour-idle session 50459 completed
exit 0, reconnecting to the retained Terminal in 0.236s; that probe used the
previous candidate. Current-build Hive Manager diagnostic 87211 remains live;
its first five reconnects passed in 0.221–0.232s. The actual-user mount failure
and subsequent catalog timeout remain unexplained. Runtime journal 910 describes
in-progress monitor recovery work, not an established cause or fix here.

### Overlapping-display failure — journal 915

The current global binary reproduced detach uncertainty under concurrent display
reconnects: temporary probe round 10, then the repository diagnostic at round 9.
In the latter case the service still answered a read-only catalog request in
0.291s, before the fixture stack was captured. Evidence:
`/tmp/bee-overlapping-reconnect-check.log`, fixture
`/tmp/bee-native-reconnect-xd2wivrb`. This differs from the actual-user expired
mount followed by a 60-second catalog timeout; that cause remains unresolved.
Another 30-round overlapping probe passed. Idle diagnostic 87211 completed all
ten reconnects; hour-idle 50459 passed on the earlier candidate.

A private candidate increases detach acknowledgment from 200 to 750 ms, with
exit-under-one-second acceptance still required. Native session race/vet passed
57592. Native checkpoint `094d0c4416dd` is pushed; build 64032 is pending at
`/tmp/bee-detach-budget-build.log`. Nothing new is installed. The opt-in
`make native-reconnect-check` preserves failed disposable fixtures and probes
service responsiveness before stack capture.

### Candidate exit gate failed — journal 917

The 750 ms acknowledgment candidate is not installed. Native client5945 and
standalone71778 passed; stress20084 failed round46 at successful exit1.090s,
above the one-second limit. Post-failure catalog answered in1.739s. Evidence:
`/tmp/bee-detach-budget-reconnect-check.log`, fixture
`/tmp/bee-native-reconnect-i94l7w7b`. Build pin is restored to nativeced4008999f4;
the published experimental native branch remains separate. External syscall
diagnostic49371 is live against the original candidate, output
`/tmp/bee-reconnect-syscalls.log` and `.trace`. Trace overhead invalidates direct
timing comparisons; use it to locate detach versus teardown stages.

Syscall diagnostic49371 subsequently completed exit0: all30 rounds passed.
The trace is a healthy comparison, not evidence of the failure cause. No
diagnostic jobs remain live from this stretch; do not repoll completed handles.
Global cbb6d6a5 and the existing user process remain unchanged.

### Detach stage diagnosis — journals 920–921

The failing syscall trace places a missing reply before client teardown: the
retained process read the client's encrypted request bytes promptly, but the
existing socket carried no reply before the 200 ms deadline. The client exited
287 ms after terminal restoration. This is not proof of Lua request admission.
The actual-user read-only catalog remains responsive (0.193s).

A separate diagnostic profile is pushed as
`checkpoint/detach-stage-trace-20260910` at6eca698. It selects an opt-in
`beediagnostic` native factory5912947 and logs Hive dispatch/result plus retained
grant/unmonitor stages through the existing log event stream. It is not a release
profile and must never be installed globally. The production pin staysced4008.
The first stage run28307 reproduced successful exit1.152s using the original
200 ms budget; post-failure catalog1.811s. That slow exit is therefore not caused
solely by the rejected750ms experiment.

Library logger context was corrected, rebuilt9094, and verified to emit all nine
stages. Combined trace2773 is live at `/tmp/bee-detach-full-stage.log` and `.trace`,
fixture `/tmp/bee-native-reconnect-hgvhrztz/state/owner-3771906929.log`. First100
complete detach dispatch groups took at most2.818ms. Parsers:
`/tmp/bee-detach-stage-timing.py` and `/tmp/bee-trace-timing.py`. Do not poll
completed builds1784/9094 or first stage run28307. No user processes restarted.

### Proven cancellation-order fix; independent timeout remains — journal 925

Native checkpointa0fc01e088b2 drains canceled physical input before closing its
viewport. The new regression failed the original code with ErrMountExpired;
fixed mesh/physical90369, session56803 and retained-owner49054 race/vet passed.
Real late delivery errors remain visible, including genuine ErrMountExpired.
The clean candidate `/tmp/bee-cancel-drain-candidate` built86977 (SHA256
2c1f11099dd970c12be11ee8cf7e51ad1521e093c94f1a880cfd1602d7908a61),
without diagnostic code or timeout changes. Native-client63685 and
standalone83568 acceptance passed. Stress14828 failed round4 at the pre-existing
detach acknowledgment timeout; catalog still answered in0.386s. Evidence:
`/tmp/bee-cancel-drain-reconnect-check.log`, fixture
`/tmp/bee-native-reconnect-359cj4kf`. No global installation or user restart.

The diagnostic's cleanup attempted a second close of earlier completed clients
after this failure; those clients are now removed from its cleanup list as each
close completes. The original failure remains preserved.


### Slow exit localized to native stack shutdown — journal 927

Diagnostic native `539b63e` and Bee `21d027e` reproduced a successful but slow
exit in reconnect session 28295, round 47: 1.128 seconds. The client's existing
`Stack.Stop()` call consumed 1.110 seconds; actor, TTY and names cleanup each
consumed under 0.1 ms, enrollment cleanup 10.355 ms. All returned nil. The matching
supervisor detach dispatch through reply completed in 0.375 ms. Catalog afterwards
answered in 2.172 seconds. This narrows slow exit to stack shutdown, without yet
separating internode from membership shutdown. Runtime implementation stays with
the cluster lane; no runtime changes or global installation were made.

Evidence: `/tmp/bee-cleanup-stage-reconnect.log`, fixture
`/tmp/bee-native-reconnect-05vc5m98`, failing client `client-2842851.raw`, and
`state/owner-2485849863.log`. The original expired-mount/60-second stalled catalog
and intermittent missing detach acknowledgment remain unresolved. Diagnostic
build `/tmp/bee-cleanup-stage-candidate` is not a release candidate. All current
build/test sessions are finished; do not repoll them.


### Detach timeout traced past Hive admission — journal 931

Diagnostic `da7ccdb` built/linted successfully. Strict stress 80321 failed on
another successful slow exit (1.255 s, stack shutdown 1.225 s). The explicit
attachment-focused mode in diagnostic `2862702` records slow successful exits
and continues; it does not relax standard exit acceptance. Run 80008 then failed
round 57 on an actual missing detach acknowledgment. The request entered Hive
at 1789087145.211802006; local dispatch at .211907625 reached retained handling
at .539417744, 327.510 ms later. Revocation/unmonitor/reply finished at .539510489;
Hive processed the result at .542191029, after the 200 ms deadline. No success
reply was sent after expiry. This reproduction narrows the problem to the local
send/handling interval, without yet identifying what delayed it. The original
initial expired-mount failure remains unresolved.

Evidence: `/tmp/bee-attachment-focus-reconnect.log`, fixture
`/tmp/bee-native-reconnect-scwp0cci`, client `2885497`, owner log
`state/owner-1716549607.log`. Catalog afterwards answered in 2.091 s. Diagnostic
`1525a72` adds send begin/end and retained-select timings; lint 16238 passed and
build 37361 is running, output `/tmp/bee-local-dispatch-trace-build.log`, target
`/tmp/bee-local-dispatch-trace-candidate`. Poll that exact handle before running
its next focused diagnostic. All earlier test handles are terminal. Global Bee,
user processes and runtime source remain unchanged. Live global catalog followup
r3 answered in 146 ms. Runtime lane checkpoint 929 has been read; it is not a
pushed/merged runtime cutover and is not claimed to fix Bee's symptoms.


### Accepted local send waited 599 ms for retained select — journal 935

Run 96915 failed round 67 on a 20-second startup stall; two peers attached,
but client 2928543 emitted only the connection banner. The owner had only two
catalog callers for that round. The diagnostic previously killed such a client
without a stack. Harness `20eae6c` now preserves that original failure, observes
the remaining connection window, and takes an exact-subprocess pidfd stack when
still live. This does not relax the normal first-frame gate.

Repeat 27804 then reproduced the detach timeout in round 4. Local process.send
returned successfully in 21.219 microseconds. Retained channel.select, entered
before the send, returned 599.164 ms after its acceptance; no retained handler
ran between the select begin/end markers. Revocation/unmonitor/reply then took
under 0.2 ms. This locates the delay in local delivery/wakeup/scheduling rather
than Bee revocation; the precise runtime mechanism remains unproved. Client
stack shutdown in this failure was only 32.296 ms, separating it from the other
slow-exit issue. Catalog afterwards answered in 447 ms.

Evidence: `/tmp/bee-local-dispatch-trace-r2-reconnect.log`, fixture
`/tmp/bee-native-reconnect-yhovcyf4`, `state/owner-2879045078.log`,
`client-2940102.raw`. Request: `01a08ded-c40e-790b-bf2b-1ff04c05a696`.
Diagnostic binary `/tmp/bee-local-dispatch-trace-candidate`, SHA256
41d3742d9ccc822c77521247b02719cb20d65e13360c67fce05044b2bb26bd15.
All build/test jobs are terminal. Runtime lane owns the next investigation below
local send/select; no runtime or global changes, no user restart. The original
expired-mount failure remains unresolved. Detailed observations are journal 934–935.


### Global cancellation fix installed; reliability work remains — journal 937–938

Global `/home/wolfy-j/.local/bin/bee` now has native `a0fc01e088b2`, with unchanged
Bee source `c3b2c9f`, runtime `674b58a1` and builder. SHA256:
2c1f11099dd970c12be11ee8cf7e51ad1521e093c94f1a880cfd1602d7908a61.
The independently proven cancellation-order correction passed native-client,
standalone and focused race/vet. Actual-user read-only observation through the
installed binary reached its frame in 217 ms and detached in 87 ms. No owner
restart or database change. Backup `bee.previous-20260911T004912Z`; install and
live proof logs `/tmp/bee-cancel-drain-global-{install,observe}.log`.
Manifest and current-build docs are checkpoint `0d261ff`. Pre-existing startup,
mount and detach failures are explicitly not fixed by this installation.

Diagnostic run 87050 ended at round 84 on a client still exiting at two seconds.
The saved raw ends after names cleanup and before stack shutdown completion;
its eventual outcome was not retained. Catalog afterwards answered in 2.108 s.
Fixture `/tmp/bee-native-reconnect-_0kxc580`, client 2958461. Harness `564e1f6`
now additionally saves client raw/status after catalog pumping, so late cleanup
results are retained. Original first-frame capture includes the remaining cold
connection window and an exact pidfd stack. No startup failure recurred in this
run. All test/build handles are terminal. Runtime checkpoint 936 was read but
is not an installed/pushed cutover. Continue from the concrete local-send/select
and native-stack evidence rather than widening production timeouts.


### Read-only connections isolate slow mesh shutdown — journal 940–941

Diagnostic checkpoint `aa3261a` adds `native-catalog-reconnect-check`. It starts
one disposable retained desktop, then issues fresh authenticated `bee desktops`
commands, retaining stdout/stderr/status and exact-process timeout stacks. No
viewport attachment or detach occurs in those commands. Sequential run 60105
passed 120 queries: whole-command median 209 ms, max 316 ms; Stack.Stop max
76.155 ms. Fixture `/tmp/bee-native-catalog-reconnect-4jdoludz`, log
`/tmp/bee-catalog-startup-diagnostic.log`. CLI output happens after stack cleanup;
first-output timing must not be described as catalog-response latency.

Three-client batches reproduce slow Stack.Stop without any viewport or session
grant churn. At 127 completed queries, one 2.003-second command included 1.739 s
in Stack.Stop. This narrows the slow-exit reproduction to repeated native client
join/read/leave, independent of desktop detach semantics. It does not explain the
original expired mount or the accepted-local-send/select wake delay.

Run **8203 remains live**, 360 total queries in three-client batches, log
`/tmp/bee-catalog-concurrent-diagnostic.log`, fixture
`/tmp/bee-native-catalog-reconnect-65jc9eip`. Poll that exact handle. Binary remains
`/tmp/bee-local-dispatch-trace-candidate`; it is diagnostic-only. Global remains
the clean cancellation build installed at journal 937. Runtime source unchanged.


### Membership departure measured directly — journal 944–947

Read-only overlapping run 8203 completed all 360 commands: whole-command max
3.342 s, Stack.Stop max 3.026 s, first-30 median 354.5 ms versus last-30 median
3.247 s. No startup timeout occurred. The next diagnostic native `4134e93`
forwards only existing scalar membership stop/leave milestones; normal logging
remains unchanged. Owner/client race/vet 75495 passed, build 73748 passed,
manifest checkpoint `a958b48`; artifact `/tmp/bee-membership-stage-candidate`.

Initial query run 99807 failed writing evidence with ENOSPC. Completed temporary
build directories had already been auto-removed and 5.5 GiB was available at
followup, so no files were deleted. Retry 97881 completed all 120 commands.
Its slowest recorded Stack.Stop was 943.108549 ms, of which membership departure
(leaving-cluster-gracefully to left-cluster-successfully) took 942.840514 ms.
This directly identifies membership departure as the dominant cost in these
samples, without claiming a cause within memberlist or explaining other stalls.

Evidence: `/tmp/bee-membership-stage-catalog-r2.log`, fixture
`/tmp/bee-native-catalog-reconnect-us8vj6wi`, `query-0105-3035888.stderr`.
All jobs are terminal. Runtime lane owns departure policy and local wakeup
investigation. Global remains clean native a0fc with its cancellation correction.
Original startup/mount and accepted-send/select wakeup failures remain open.

Other Bee lane checkpoint 943 is ready for separate integration: full source
check, 508 Lua tests, 564 source/pack entries, two-node sync/inbox race proof and
focused final cursor regression passed. Current shared-source delta from c3b2c9f
is 35 files in sync, node metadata, inbox feeds and harness activation. It is not
in the global binary yet. Runtime checkpoints 942/945 are research results, not
a release/cutover. Preserve native lane boundaries when preparing that integration.


## September 11 — Codex: global app transfer installed

Global Bee SHA `2569142f` is installed from release checkpoint `8d16dc5`
(production `4e57054`), with runtime/native pins unchanged and databases preserved.
Right-click an app tab/title → Send to display moves the same live app between
independent clients. Observer views, initial restored-app assignment, failed
layout-save reconnect and prepared transfer recovery are covered. Public native
transfer, both executable suites, 529 unit tests and the completed source/pack
gate segments pass. Actual-user cold/warm frames: 1.433s/0.209s; detach about0.11s.
See GLOBAL_BUILD.md and wolfden seq1075. Live Hive Manager browsing/attachment,
workspace switching and broader remote recovery remain the next work. Source is
on `checkpoint/app-transfer-release-20260911`; shared source was not reset or
blanket-committed. No runtime changes.

September11: connection card follow-up installed globally, SHAaf1dc830, source27f0383.
Source/pack UI and native connection checks pass; running user node not restarted.
Full IDs now behind Details/D. Live browsing remains next; journal1076 has source evidence.

### 2026-09-11 Codex: generic driver configuration validated

Activated drivers now supply `configure`; carrier and placement use a shared
typed boundary and independently pinned registry data. Placement refuses missing,
substituted or changed configuration before intent. A third-driver fixture proves
private-home file materialization. Native harness scope management is selected
only by protected host admission and is documented as trusted authority.

All 565 unit tests, remaining `make check` recipes, native pack coverage
(14 modules / 586 entries) and standalone executable acceptance pass on the
unchanged candidate runtime. The existing desktop-lifecycle lint warning remains.
The candidate SHA is recorded in `RUNTIME_MAIN_CUTOVER.md`; global Bee is unchanged.
Project-state runtime cutover, authenticated provider turns, production terminal
cleanup, generic gateway extensions, profiles and Docker remain separate work.
No self-modification API work has started. Wolfden evidence: 1194–1197, followed
by the final integration checkpoint.

### 2026-09-11 — Codex: Agent integration checkpoint and scoped recovery boundary

Isolated branch `feat/agent-integration-20260911` integrates host profile
preflight, bounded Codex developer instructions and MCP argument validation.
At source `586956d`, 581 Lua tests, managed-window 3/3, source/pack foundation
and desktop recipes pass in segments. One packed fault-injection run exited
without its expected diagnostic; the focused rerun passes, but the original
failure remains unexplained. No uninterrupted full-check claim is made.
See `AGENT_INTEGRATION.md` for the evidence and remaining gates.

The user reiterated durable provider session identity and separate service,
user and agent scopes. Native Agent recovery must reuse app checkpoints and
retained-session resources, preserving current authorization and avoiding
prompt replay; `NATIVE_AGENT_RECOVERY.md` is the proposed next integration unit.
Global Bee and runtime source are unchanged. Runtime #726 and builder #7 are
still open on the tested heads and assigned to Rodrigo.

Parallel isolated work: governed authoring (`a4b4ef4`, 599 Lua tests and native
pack 15 modules / 607 entries), Go architecture-check parity, and claimed-hook
retention (`e4d87e2`, focused gateway check passes; real commit-followed-by-lost-
ack acceptance is being added). These branches have not been merged into this
checkpoint. The shared wolfden journal holds current coordination through seq
1242 under cursor `jc_H7E57Z5SJH71M`.

### 2026-09-11 — Codex: safe authoring and hook recovery integrated

Governed authoring and claimed-hook recovery are integrated on the isolated
`feat/agent-integration-20260911` branch. All 600 Lua tests pass on combined
source; source/pack headless boots pass. The actual gateway proof commits a
hook, revokes before acknowledgement, replays the exact commit once and then
acknowledges it. Two authoring boots preserve immutable binary snapshots,
retry receipts, author denial and the unchanged migration ledger. Stored
ownership does not bypass current operation or exact-workspace permissions.

The user explicitly rejected architecture tests. Both the obsolete Python
checker and its Go replacement are removed, along with their Makefile gate.
Keep module boundaries clear through review and verify runtime behavior.
No new Python, runtime changes, global replacement or main merge in this unit.
Interactive Agent cold-resume and public MCP/Hub/overlay activation remain open.
Wolfden coordination: journal 01a06e56-ba58-7c5a-bd69-b7feb109a05d,
`bee-harness/root`, cursor `jc_H7E57Z5SJH71M`, through seq 1245.

### 2026-09-11 Codex: native window hook delivery and cooperative close

Pushed `5b82a43` on `feat/agent-integration-20260911`. Native windows now attach
placement before PTY start. Protected host bindings select a bounded close
allowance; the Agent window can finish its hook drain and receipt, ordinary
apps keep 250ms, and explicit force stop remains immediate. A real shell child
submits duplicate HTTP hooks through generated configuration; with a three-second
claim delay, input stays responsive, exactly one observation commits, and the
cancellation receipt exists before the broker reports close. All 616 Lua tests
and three managed-window tests pass.

The broader check passed module, gateway, authoring, pack and headless gates.
Its cached lint error was preserved and fresh strict lint passed unchanged source.
The two-workspace fixture omitted its governance DB path; `8afb018` fixes that
and passes source/pack. Remaining source-free fixtures receive an explicit
working-directory governance path through their Makefile acceptance targets;
storage/desktop checks are still running. No Python edits or runtime changes.

Luna's next unit is isolated session-resource admission at
`/tmp/bee-window-session-admission-20260911`. Native conversation cold-resume,
public MCP and global project-state isolation remain open. Global Bee is
unchanged. Wolfden journal `01a06e56-ba58-7c5a-bd69-b7feb109a05d`,
`bee-harness/root`, cursor `jc_H7E57Z5SJH71M`, through seq 1259.

### 2026-09-11 Codex: window-close acceptance complete

The remaining storage/desktop continuation exited successfully. Together with
616 passing Lua tests, live delayed-hook acceptance, native/managed-window
checks and the corrected workspace-host fixture, every required foundation
check passed across the original run and targeted continuations. Source/pack
close/force stop, failed-delivery recovery, retained terminals, observer fences,
client transfer/reconnect, launcher/recovery and bundled apps all passed.
Evidence: `/tmp/bee-window-close-check-remainder-isolated-20260911.log`.
The earlier cached lint failure and two missing fixture DB paths remain recorded;
this is not a single uninterrupted full-run claim.

The user reiterated simplicity. Luna's `d9f154c` session-admission candidate stays
isolated and unaccepted: it lacks actual admission-to-HOME acceptance and reported
four gateway test failures plus lint failures. Do not enable app resume metadata
or adopt that policy based only on grant-field tests. Reuse the existing resource
and checkpoint contracts for the next recovery unit. Global Bee remains unchanged;
runtime #726 and builder #7 are still open at the previously tested heads.
Wolfden checkpoint seq 1262, cursor `jc_H7E57Z5SJH71M`.

### 2026-09-12 Codex: retained Agent file admission

Integrated the simplified optional `session_resource` field after real window
acceptance. Admission derives a session identity and obtains the authenticated
actor's attempt-bound writable resource grant; callers cannot supply either.
The Agent's protected host binding now permits obtaining that grant. Its ninth
policy exposed the old eight-policy limit; the decoder now allows sixteen and
tests reject oversized and sparse compositions.

The actual broker-spawned shell writes a marker into its retained HOME, closes
normally and leaves the marker readable. A distinct second launch keeps its
own marker and preserves the first. All four managed-window cases pass. The
earlier simplified admission candidate passed619 unit tests, strict source
lint, pack and standalone harness isolation. The combined source now passes620
unit tests, including the policy-bound regression, plus native/managed windows,
live hooks, module/gateway/authoring and source/pack host checks. The full run
continues through storage and desktop acceptance.

Temporary worktrees and test artifacts were absent on continuation. Committed
work was restored under `/home/wolfy-j/wippy/worktrees/`, and the exact pinned
toolchain was rebuilt through the Makefile. New evidence is retained under
`/home/wolfy-j/wippy/bee-evidence/0912/`; the live proof is
`retained-window-final.log`. Initial fixture failures and corrections remain
recorded there. Global Bee and shared main are unchanged. No Python or runtime
changes were included. Provider conversation recovery and public MCP/Hub
activation remain unfinished. Next, preserve acknowledged broker checkpoint
state before wiring Agent recovery; no separate persistence manager is needed.
Wolfden journal remains `01a06e56-ba58-7c5a-bd69-b7feb109a05d`, cursor
`jc_H7E57Z5SJH71M`. Integration checkpoint `488e1a6` is pushed; full acceptance
and the next isolated broker acknowledgement repair remain in progress.

### 2026-09-12 Codex: acknowledged broker checkpoints

The broker now keeps a pending checkpoint separately and updates its live
resume state only after a correlated successful owner acknowledgement.
Refusal and timeout preserve its previous acknowledged state. The real fixture
app forwards the receipt it received from the broker before the owner asks for
another attachment, so the test does not assume ordering across listener
channels. Host-selected fixture admission is restored even on failure.

Parent counterfactual evidence uses the same final fixture: the original broker
at `5981d89` fails after the explicit refusal receipt; the patched broker at
`dc93430` passes all five cases, including successful update and timeout.
Evidence lives in `checkpoint-parent-original.log` and
`checkpoint-parent-fixed.log` under the September12 evidence directory above.
The child's saved baseline logs unexpectedly passed and are not negative
evidence; this parent comparison replaces that claim.

The previous full run stopped at `tests/control_delivery.py`: the injected
failure exited nonzero but reported a terminated desktop dependency instead of
the original send failure. The dependency identity has not yet been established.
Luna is isolating that path on a separate branch. All earlier checks through
storage/restart, resources, connection UI, fresh pack, taskbar, personalization,
titles, interactions and close passed; later desktop gates remain outstanding.
No full-pass or conversation-recovery claim is made. Shared main, runtime and
the global executable remain untouched.

### 2026-09-12 Codex: standalone checkpoint slice verified

The combined checkpoint source passes620 Lua tests, strict fresh-cache lint,
all five managed-window cases and source/pack headless/two-host checks. The
remaining desktop recipes also pass (session58308 exit0): window retirement,
Terminal input/scrolling/selection, lifecycle/load, independent clients,
launcher/recovery and Inbox/Hive Manager/Timeline. The original delivery
diagnostic is still unresolved; its proposed supervisor guard remains isolated
without controlled cause evidence. This is segmented acceptance, not a new
uninterrupted full check.

The standalone candidate built from source19f09c8 packages15 components and
passes executable acceptance, including the public Agent picker. Its SHA256 is
`8d00806c50c0e377f48b1598f534c6b361a65e42e350f99bc6dfc82a067c4669`;
the candidate and `checkpoint-*.log` evidence are under the September12 evidence
directory above. Checkpoint changes are pushed through53feab9. Global remains
unchanged: runtime703/726 and builder7 remain open at unchanged heads, and the
per-project default-state requirement still gates installation.

Conversation recovery will read existing committed hook observations through
the thread owner's read_after operation. An experiment duplicating this data
in provider-session checkpoint fields was paused and is not integrated.
The next isolated placement slice prevents concurrent use of one retained
session home through the existing intent transaction. No new persistence or
lock owner is needed. Wolfden facts1272–1274 retain the evidence and decisions.

### 2026-09-12 Codex: retained-session components built and verified

Integration source `cf667d8` includes retained-home exclusion, committed-hook
interactive continuation and rejection of option-like provider resume IDs.
The combined source passed 625 Lua tests, isolation, five managed-window cases
and actual hook acceptance. Producer qualification has a controlled failing
counterfactual; final continuation/provider/config fixtures pass 18 tests.
The earlier exclusion implementation's trailing-nil SQL parameter regression
failed 55 tests before its fix; corrected exclusion and replay runs each pass
622 tests. Those failures remain in the evidence directory.

The final standalone builds 15 components / 610 entries and passes the native
executable suite, including the public empty Agent picker (detach 0.103s).
Artifact: `/home/wolfy-j/wippy/bee-evidence/0912/bee-agent-components-final`.
SHA256: `e9f38335e5b138a9433d2145f6b92ecce2c3341a59f2c5cf1ba48855ab623f98`.
Evidence: `agent-components-provider-fixtures.log` and
`agent-components-final-{build,native}.log`. This does not prove public provider
conversation recovery or fix the earlier control-delivery diagnostic.

Global remains unchanged. Fresh upstream checks confirm runtime main and
PRs 703/726 and builder 7 are unchanged; all three PRs remain open and assigned
to `skhaz`. Per-project default state selection before the runtime lock remains
the installation gate. Agent saved-state/fresh-admission recovery and refreshed
retained configuration are the next Bee work, without a new persistence owner.
Wolfden fact 1277 records the component build and current runtime boundary.

### 2026-09-12 Codex: fresh admission for recorded window continuations

Pushed `fa50d4d` on the Agent integration branch. The existing launch contract
accepts bounded original-request/predecessor/thread references, requires the
saved plan digest and an empty brief, verifies current owner records and obtains
fresh grants. It derives the same action and retained session and a new attempt;
caller-supplied session authority or provider resume strings remain rejected.

All 626 unit tests pass (122.8s), along with 23 focused admission/continuation
tests, source/pack harness isolation and five managed-window cases. Evidence is
in `recovery-admission-{all-tests,receipt,managed-window,window-app}.log` under
the September 12 evidence directory. The first managed-window invocation used
an incorrect Make target after isolation passed; the corrected target passes.
The admission fixture uses actual thread/resource owners but constructs its
completed placement state without starting a process. Native cleanup and cold
app recovery are still unproven. Foundation job 66125 is running separately.

Exact runtime `291f5c6` source confirms terminal attachment consumes the exec
handle before asynchronous process start. The returned terminal session has no
identity accessor; leader/PTY completion alone cannot prove group absence.
The existing placement cleanup remains the owner of that decision. No runtime
changes were made. Claude's CLI supports inline MCP/settings configuration,
which may avoid rewriting retained files; it needs driver integration and
acceptance. Codex hook/trust file refresh remains unresolved. A generic driver
configuration proposal must account for empty argv literals and Codex's
materialization-time HOME-dependent trust data before implementation.
Wolfden facts 1280–1281 record the evidence. Global Bee remains unchanged.

### 2026-09-12 Codex: driver-owned configuration delivery and review

The configuration worktree now gives each driver one bounded argument/file
delivery. Placement supplies the actual HOME and selected gateway, validates
and freezes the result in its existing intent, and both execution transports
consume it. The incomplete launch-side render and duplicated gateway/provider
formatting are removed. Stored requests and deliveries are decoded before
start; corrupted delivery cannot create a home or start a child. Native call
isolation is proven against the caller's original provider table, so no extra
copying layer was added. Unsupported Codex hook events now refuse explicitly.

All 629 Lua cases pass with the actual Claude/Codex binaries selected. The
launch regression fails on the old preflight and passes with the correction
(17 cases); the persisted-delivery regression fails on the old reader and
passes after decoding (24 cases). A fresh full `make check` is running in
`config-delivery-reviewed-check.log`. The prior candidate executable passed
native-binary acceptance; the reviewed source is being rebuilt separately.
The original remaining-foundation run reached desktop checks but caught a
transient typing error during the store edit; this was fixed before the fresh
run. These are not yet final complete-foundation or publication claims.

Actual loading of all 15 assembled packs found the older
`bee.hive_manager:fixture` sample-node table in production. Its removal and a
Go/Lua acceptance replacement are a separate worktree. Parent review rejected
the first exit-status-only test runner and requires clean completion markers,
bounded slow-query checks and a failing-probe counterfactual before acceptance.
The app pack has 610 entries and no embedded filesystem assets before removal.
Wolfden facts 1285–1286 record the findings. Global remains unchanged; the
runtime and builder heads still lack executable-selected per-project state.

Review follow-up: the reviewed configuration executable also passed acceptance
(SHA `4e0ebdcfb15730f8fe2452769b079250e32392637dcd39ad8e380c287c0eeba7`).
The full configuration check remains live in session 15767 and has progressed
past injected structural-delivery failures and window retirement. Hive cleanup
is committed separately as `ff90c03` (integration `1c8f002`); its final Go/Lua
source/pack application checks and explicit failed-probe check pass. Actual
loading of all 15 resulting release packs found 608 entries with no fixture/test
registrations, test-library references or embedded filesystem assets. Wolfden
fact 1288 records the cleanup evidence. Combined acceptance remains pending;
global is unchanged. No new Python files or Python edits are included.

### 2026-09-12 Codex: combined configuration and release-pack checkpoint

Integration `343eefa` combines configuration `6ac9f01` and Hive cleanup
`ff90c03` without conflicts. The combined build, native executable acceptance
and Hive source/pack application acceptance all pass (sessions 96129, 10805,
37658). Candidate `bee-config-hive-reviewed` has SHA-256
`a45e650d05e4ef9cc3bd4002bb0bc34de49ff1ec0a72c2b3e586284c6653abf8`.
Loading every assembled pack confirms 608 entries in 15 packs without test or
fixture registrations/references and no embedded assets. Full configuration
check 15767 is still live, through terminal/scroll and into lifecycle/recovery.
Runtime PR 726 and builder PR 7 remain open on the same pinned heads; obsolete
remote-monitor PR 716 is already closed. No runtime changes were made. Global
SHA remains `5c604fa7ab5f3c7eaa903c7ed2a79c8eb8b467fa6c0ee738b1c016471c9e026a`.

### 2026-09-12 Codex: completed foundation check and precise overlay gate

The full configuration `make check` (session 15767) completed with exit 0,
including 629 unit cases and all isolation, storage/restart, terminal, client,
lifecycle and application gates. The combined configuration/Hive source also
passes all 626 unit cases (session 78576, 209.2 seconds); three old fixture-only
cases were removed. Executable and assembled-pack evidence above remains valid.
The independently runnable managed-launch target now builds its Go HTTP fixture
itself; harness module documentation matches the public Agent/PTY path.

Native overlay gates are integrated as `506e299` and `a05cb9a`, using Go/Lua
fixtures outside production. The owner-only gate passes. The independent
composed durable-base requirement fails for the expected reason on runtime
`291f5c6`: a reviewed overlay at version 0 commits alongside the dependency
changed at version 1. The fixture reads both effective values before emitting
`GOVERNANCE_COMPOSED_BASE_STALE_ACCEPTED`; a crash cannot count as this evidence.
Parent review added explicit initial dependency/base assertions and removed a
post-Wait process-group kill. Evidence: `overlay-owner-reviewed.log` and
`overlay-composed-reviewed.log`. This adds no runtime API or production writer.
Other-overlay fencing, exact expansion and activation lifecycle remain unproven.

Required-executable test guards are being tightened separately: an explicitly
selected native binary must not turn missing runtime capability into a green
non-execution. No Python changes or global installation accompany this work.

### 2026-09-12 Codex: required native-executable evidence corrected

Terra's `7c75a28` is integrated as `dcdbeb3`. Configured Codex now fails the
direct authentication, placement authentication and gateway proof cases when
stdin closure is missing. The existing Python runner is unchanged; no replacement
test framework was needed. Its positive gate passes 268 cases with both actual
executables against isolated provider endpoints, exit 0 after 191.9 seconds.
The disposable negative fixture forces missing capability in the placement case:
267 pass, one fails specifically with `the configured Codex executable requires
placement stdin_close`; the required runner rejects the missing proof. Evidence:
`managed-executable-evidence-{gate,counterfactual}.log`. Strict runtime lint and
Go vet pass; the known interprocedural convergence warning remains.

User hook integration clarification: configured managed agents wire admitted
hooks through their scoped gateway and fenced carrier into committed
`bee.harness.hook` thread observations. Durable subscriptions can consume those
records. Both real harnesses cover SessionStart, UserPromptSubmit, PreToolUse,
PostToolUse and Stop. This is not every possible hook, synchronous approval
interception, default production profile setup or global gateway activation.

### September 12 — scoped authoring and additive overlay priority

Current Wolfden coordination remains Bee Harness,
`01a06e56-ba58-7c5a-bd69-b7feb109a05d`, graph `bee-harness`, node `root`.
Parent cursor is `jc_H7E57Z5SJH71M`; incoming Hub collaborator is
`jc_J1A1GNYY6D2AP`. Facts 1308–1311 record the user's first priorities and storage
split: Hub/system definitions use durable registry history; app/component edits
persist in Bee DB and project through additive registry overlays without history.
The core stays small; component installation does not depend on Keeper.

The authoring boundary uses two function entries and the existing named-scope
API. Public `workspace_call` checks exact workspace operation authority;
private `workspace_backend_call` requires its own execution permission and
preserves the authenticated actor. Ordinary apps retain their database and
scope-creation denials. All 626 unit cases pass. Two actual boots prove frozen
binary files, exact retry receipts and the unchanged migration ledger, plus
direct DB, private scope and backend denial before and after public calls.
Evidence: `authoring-scoped-final-restart.log`, `authoring-scoped-check.log`.
The broader foundation check is still running at this checkpoint.

Native packaging passes: all 15 assembled packs load with 610 entries and no
test/fixture registrations or embedded assets (`authoring-scoped-pack-audit.json`).
No runtime, service, migration or core change was added.
Hub installation, desired overlay publication/reconstruction and the native
composed-base publication fence remain unfinished.

User subsequently requested a global refresh with unfinished backends accepted.
Installed SHA `55b725aa8c4483037e3396d91860fc23159a6158e4b46c32435cade5298abe82`,
source `97a9af2`, with verified binary/provenance sidecars and a retained previous
binary. Native terminal/selector tests and the real installed-to-candidate upgrade
pass. Public client checks pass across the initial run and a focused continuation
after a temporary `.bash_history` cleanup race. Default state remains user-wide,
as in the previous install; this was disclosed before installation. Explicit
`--state-dir` isolates every database. No live user node was restarted.
See [the global build handoff](GLOBAL_BUILD.md); Wolfden fact 1327 records the install.

### September 12: full authoring source gate complete; Docker login requirement

Full `make check` session 43383 completed with exit 0: 626 unit cases, native
identity/installer/bundle, module isolation, permissions/storage, desktop and
launcher/recovery, Inbox, Hive Manager and Timeline. Evidence remains
`bee-evidence/0912/authoring-scoped-check.log`; the existing desktop-lifecycle
type-convergence warning remains. Global `55b725aa` is unchanged.

The user requires Docker Claude/Codex to automatically reuse the machine's
existing harness login. Existing broker API-key projection does not meet that
requirement. Private writable login-file materialization and the public launch
configuration are in progress; no production subscription-login or Docker claim
yet. Host homes must not be mounted wholesale, and credential contents must not
enter registry entries, persisted receipts, hashes or logs. Hub continues in
the collaborator lane; overlays remain deferred until agents work.

### September 12: separate harness packs and Grok integration

Claude and Codex now assemble as their own driver components, separate from the
shared contract/kit/transport pack (`8b5ee7e`, native-pack: 17 modules, 612 entries).
Grok's declarative component is integrated (`2b4e1b6`); its launch/configuration
and bounded protocol/state tests pass. The combined unit suite passes all 650
cases after removing the catalog fixture's fixed five-binding assumption.
Grok login and live MCP token interpolation remain unverified. The Agent picker
still needs production launch profiles; this is not a managed-agent release.

The optional userspace Docker module has local terminal-create work in
`8bd366b` and `7fd34c9`: a distinct grantable `create_terminal` method with the
same sandbox configuration checks and `Tty=true`. The focused runtime check and
namespace lint pass. Its full development host has existing dependency/boot
configuration failures, so full module acceptance is not claimed. Nothing from
that module was published or installed. The real same-container Go PTY proof
covers input, resize, detach, reattach and cleanup.

Credential file source/upgrade and retained writable login-home work continue
in isolated lanes. Random-port MCP requires the actual owned listener endpoint;
no port probing or reserve-close helper was added. Wolfden facts 1359 and 1361
record the integration boundaries. Global `55b725aa` remains unchanged.

The Codex ChatGPT-login configuration's full `make check` (session 79852)
completed with exit 0, including desktop and recovery checks. This validates
configuration selection, not automatic credential setup. The Grok native bundle
passes at 18 modules and 622 entries. Agy's child component is now integrated;
its shared activation and pack validation are the next combined gate.

Credential broker file support is integrated as `ff95d7c` (source commit
`76758ce`). Its revised full unit run passed 633 cases, including the populated
migration, source-policy denial and an actual direct-filesystem probe with an
authorized positive control. The four-driver bundle passes at 19 modules and
632 entries before the credential integration. Production profiles, automatic
login-home delivery and randomized-port MCP remain incomplete; global is unchanged.

The combined unit gate now passes 677/677 after `d441367` preserves bounded Agy
stream text and prevents partial tool output from becoming completion. File
credentials refuse before native placement intent until private-home delivery is
wired. The previously intermittent runner-loss test now injects the durable
missing-identity state directly: the old kill/sleep/erase setup allowed the
background sweep to prove exit before identity removal. It now always requires
uncertainty and refused cleanup. Full combined `make check` session 75912 is
still running at `bee-evidence/0912/four-driver-credentials-full-check.log`;
unit success does not yet constitute the full foundation gate.

### 2026-09-12 Codex: four-driver global refresh

Wolfden checkpoint 1379 records installed global `78aae0b0`, built from frozen
production `0e59a16` with unchanged runtime/native pins. Executable, complete
client and installed-version upgrade checks pass. All 19 packs/633 entries and
matching license/provenance files were verified; tests and fixtures are absent.
The 677-case unit gate and corrected hook/module fixtures pass; the broad
`make check` desktop remainder is still running. Current details and evidence
are in [GLOBAL_BUILD.md](GLOBAL_BUILD.md). Running nodes were not restarted.

The Agent picker still needs production profiles. Retained-login delivery is in
an isolated integration worktree, not this global build. Review found and fixed
file bytes falling through to environment assignment. A complete, authenticated
raw-child-environment probe now passes 28/28 placement cases and catches an
injected copy of that bug. Earlier negative-control attempts failed for fixture
reasons and are not regression evidence. Automatic login discovery, managed MCP
activation and Docker placement remain unfinished.

### 2026-09-12 Codex: driver components and visible profile readiness

Wolfden checkpoints 1387 and 1391 confirm the frozen four-driver foundation
check completed in segments. Retained-login delivery passed 680 unit cases and
native/managed/hook/resource checks; it remains separate from the global binary.
The Agent picker now keeps unavailable declared profiles visible, with the
admission refusal and disabled Open. Its updated 680-case unit gate passes;
actual selector acceptance passes, while a natural-completion grant-revocation
assertion in the same suite is being reproduced against the unchanged baseline.

Every harness keeps its own driver package, profiles and default launch
configuration for eventual separate Hub installation and management. Default
production declarations and automatic local setup are still being integrated;
this does not yet establish first-use launch, managed MCP or Docker.

The Hub lane installed global `acb59231` (checkpoints 1388–1389), preserving the
four drivers, and is investigating real retained-node attachment. This lane will
not replace its global during that investigation. Native host-path work is based
on the installed native revision `3e895bae936f`, not the older native sources in
the agent integration checkout; runtime remains `291f5c6b` with no new patch.

### 2026-09-12 — Combined Agent instructions global

Journal 1467–1468 records combined validation and the governance fixture fix.
Global `f1a29d08` now contains source `660b769`, preserving Hub rollback and
Agent recovery. All 772 unit cases and native desktop/Modules/Agent checks pass.
See GLOBAL_BUILD.md and `instructions-rollback-global-install.json`. No node restart.
MCP activation, Docker and editable instructions remain unfinished.

### 2026-09-12 — Managed MCP and hooks installed with current Hub/Modules

Journal 1487 records global `887d0769`, source `9da558b`, preserving the latest
Hub requirements/database support and Modules redesign. The four managed Agent
profiles now expose the two bound-thread read tools; Claude/Codex declare five
lifecycle hooks. Native fixture children authenticate and read/wait through
their generated MCP configuration. Native window hook delivery passes.
The six-file install receipt is `managed-mcp-modules-global-install.json`.
Running nodes retain their previous code and were not restarted.

The broad check passed through storage, thread restart and resources, then
stopped at the obsolete no-network-listener assertion (journal 1488). The
replacement checks one IPv4 loopback listener and rejects anonymous MCP tools;
desktop regression is running. Do not report full acceptance as green.
Docker, writable coordination tools, editable profile instructions/memory and
native-style instruction builders remain unfinished.

### 2026-09-12 — Docker process mount runtime PR

Runtime [PR #739](https://github.com/wippyai/runtime/pull/739), commit
`01d6bfb4`, adds authorized per-process Docker bind mounts from current main.
It is assigned to Rodrigo (`skhaz`), not merged or installed. The exec API,
native/Docker services and Lua exec race suites pass, including real Alpine
PTY processes with separate homes; scoped lint reports zero issues.
Source authorization checks a clean absolute path and does not claim symlink
confinement. Sources refer to the Docker daemon's host.

Bee's managed Docker launch/recovery integration remains unfinished. Global
`887d0769` is unchanged by this work. Desktop regression continues through
source/pack command handlers; full acceptance is not yet proven.

### 2026-09-13 — cancellation and real Agy recovery candidate

Journal 1602–1604 records the corrected materialization stop transition,
`child.not_started` cleanup evidence without schema changes, and independently
validated conversation IDs from occurrence-ambiguous hooks. Combined source
`f7fe2ab` is pushed. All 851 unit cases, native executable acceptance, offline
boot/reconnect and Claude fixture restart pass. Real managed Agy print-mode cold
continuation also passes exact token recall with stable conversation/HOME/app/thread
and fresh attempt/gateway, without replaying the task. Interactive Agy TUI recovery
is not established. Full source/pack acceptance is running; global `9b499f4e`
remains unchanged. Runtime PR #744 is still unmerged.

### 2026-09-13 — recovery candidate installed globally

Global `7d9182cb` now contains production `f7fe2ab`, with unchanged native
`fe8cb0d` and the fifth checksum-pinned runtime atomic-publication patch. Full
repeat `90717` passed (851 units and source/pack acceptance), alongside exact
native/offline/Claude fixture checks and strengthened real Agy cold recall.
All six artifacts were backed up and verified; databases and running nodes were
preserved. Actual Codex recovery is gated by a reproduced provider usage limit,
not a proven Bee defect. See GLOBAL_BUILD.md and the shared journal for the
installation receipt and remaining scope.

### 2026-09-13 — Docker component review and runtime-scope correction

Wolfden fact 1612 records the user's objection to premature runtime APIs.
The reference/inspection experiment is paused and uncommitted; no new runtime PR
or global artifact came from it. `userspace/docker` already has narrow lifecycle
operations. Exact managed-container terminal attachment, observation state and
ownership checks remain to be established for Bee.

The component's removal reconciliation falsely reported destruction when both
delete and later inspection failed. Draft [userspace PR #67](https://github.com/wippyai/userspace/pull/67),
assigned to `skhaz`, fixes this by preserving HTTP status and requiring confirmed
404. Five regression cases, existing narrow checks, isolated lint and an actual
Lua HTTP-client/private Unix-socket daemon fixture pass. Full component-host and
managed Docker acceptance remain open. Global `7d9182cb` is unchanged.

### 2026-09-13 — existing-container native terminal proof

Wolfden fact 1613 records a test-only Docker SDK implementation of the existing
`exec.PTYProcess` interface, driving unchanged `proxy.New`/`Run` at Bee's runtime
pin. Structured input, rendering, resize and exact-container close pass, including
the focused race test. No Docker CLI attachment process or image download was
used. This is not a production attachment API, its admission, cold rejoin or
managed Agent-window proof. The general reference/inspection experiment remains
paused. See the Docker handoff for archived source and evidence.

Draft userspace PR #67 now also preserves actual daemon state/image identity and
requires a terminal observation for stop success (`8488864`). Baseline failures,
corrected regressions, existing narrow checks and isolated lint pass. Full module
acceptance and publication remain outstanding; global Bee is unchanged.

### 2026-09-13 — native Docker blocked-input cancellation reproduced

Wolfden fact 1614 records a failing real Docker executor/terminal proxy test at
the exact Bee runtime pin. A non-reading container blocks a 16 MiB paste;
context cancellation cannot progress within eight seconds. Killing only the
fixture child releases the operation. The race run fails in 8.961s; reproduction
and log are archived under `bee-evidence/0912/docker-blocked-input-proof_test.go`
and `docker-native-blocked-input-cancel.log`. No production runtime changes or
global installation occurred. Check current runtime/patch overlap before fixing
the existing cancellation path. The broad runtime API experiment remains paused.

### 2026-09-13 — runtime terminal cancellation correction proposed

Wolfden fact 1615 records [runtime PR #745](https://github.com/wippyai/runtime/pull/745)
at `9444ddb1db`, assigned to `skhaz`, unmerged and uninstalled. Current-main
regressions reproduce blocked cancellation and blocked TERM-to-KILL escalation.
The fix moves existing shutdown supervision out of the input loop and joins it
on return; public APIs remain unchanged. Deterministic tests, real Docker input
cancellation, terminal/native/Docker/Lua exec race suites and scoped lint pass.
Evidence is archived under `bee-evidence/0912/bee-terminal-cancel-*.log`.
Global SHA `7d9182cb` is unchanged. Production Docker attachment admission and
container-reachable scoped gateway remain unfinished; no managed Docker claim.

### 2026-09-13 — existing Docker create admits PTY mode

Wolfden fact 1616 records draft [userspace PR #68](https://github.com/wippyai/userspace/pull/68)
at `05a459b`, stacked on #67 and assigned to `skhaz`. A one-line production
change accepts explicit boolean `Tty` through the existing narrow create path;
all sandbox checks remain intact. Baseline/fixed regressions, isolated lint,
existing narrow checks and real Lua HTTP-client/fake-daemon requests pass.
Tests remain outside the component pack. Local Docker lacks advertised AppArmor,
which this contract requires; full hardened-container and managed Bee acceptance
remain unverified. No component publication, runtime install or global refresh.

### 2026-09-13 — existing exec handle bridge verified externally

Wolfden fact 1617 records an external-package proof using the runtime's public
Lua `exec.NewProcess` constructor to expose a supplied PTY as `exec.Process`.
Its existing methods work; hostless attachment refuses before consuming the
handle. The race proof passes at Bee's exact runtime pin without runtime edits.
This is an extension-point proof, not actual container authorization or terminal
grant acceptance. Evidence is archived as `external-exec-process-proof` under
`bee-evidence/0912`. A native component can reuse that handle boundary; no new
generic runtime reference API is justified. Global Bee remains unchanged.

### 2026-09-13 — optional native Docker attachment backend

Wolfden fact 1618 records native candidate `e2ee130`, pushed on
`feat/docker-attachment-component-20260913` from installed native base `fe8cb0d`.
`native/docker` now supplies an existing-container PTY with identity checks,
failed-attachment cleanup and cancellable waiting. Its isolated Makefile race/vet
gate passes, including real Docker input/resize/exact-container exit. See the
Docker handoff for evidence and non-atomic daemon-control limitations.
The component is unregistered: Lua admission, actual Bee terminal grants,
sandbox/profile and scoped gateway integration remain open. Global is unchanged.

### 2026-09-13 — scoped Docker Lua boundary and runtime terminal grant

Wolfden fact 1619 records native candidate `32e632f`: a host-bound `docker_pty`
module returning the existing exec handle after daemon-qualified container
permission checks. Wrong/malformed/unauthenticated requests are refused before
daemon I/O. The real Docker fixture uses actual runtime frames and a system TTY
viewport grant; an authorized actor renders, inputs, resizes and closes, while
a child lacking the non-inherited terminal port is refused. Native race tests
and vet pass. This is not Bee broker/placement acceptance. Public registration,
admitted-record policy and Docker profile/gateway integration remain open.

### 2026-09-13 — real Docker restart admission proof

Wolfden fact 1620 records pushed native candidate `ecbe700`. A real restart
preserves the container ID but changes its execution timestamp. Old attachment
signal/resize and old admission are refused; fresh admission attaches and resizes.
The Docker integration race/vet target passes (6.590s), without pulls. This
proves completed-restart fencing, not atomic daemon control or managed Bee
Docker integration. Global is unchanged. Placement still combines common
admission with native process creation/identity; the gateway is loopback-only.
Both seams need implementation before a usable Docker profile can be offered.

### 2026-09-13 — Docker execution observation and placement review

The existing userspace observation now preserves optional daemon `started_at`
without losing precision (PR #67 `a37e91a`, stacked PR #68 `4a0e62d`). The
baseline loses it; fixed regression/lint and actual Lua HTTP-client timestamp
proof pass, alongside sandbox, removal and PTY creation checks. Neither PR is
merged or published. Luna's review identifies the existing window child
construction as the shared terminal seam. Durable attempt-derived Docker
admission, container configuration projection and gateway delivery remain open;
the descriptor must not become caller-selected window authority. Global unchanged.

### 2026-09-13 — Docker configuration projection passes the full gate

The optional `bee.placement.docker:configuration` library now projects explicit
host-admitted image, sandbox, command, home/project paths, access and labels into
the existing narrow create config. It grants nothing and exposes no placement
binding or Agent selector. Refusals cover unknown options/environment, mutable
images, host sharing, mount traversal/overlap and private-home exposure.

All 854 Lua tests and full `make check` pass (session 32725, exit 0); existing
fixpoint warnings remain. `make docker-configuration-check` also passes through
the actual userspace narrow runtime and Lua HTTP client with a private fake
daemon, exactly one create/inspection and no start. The repeatable boundary
fixture is Go and stays outside production. Evidence is archived under
`bee-evidence/0912/bee-docker-projection-{lint,unit,check}.log`.

Wolfden facts 1622–1623 record implementation and integration findings. Keep the
existing saved-profile schema: its reviewed definition already selects a host
policy. Docker paths must be bound before driver configuration is frozen; host
credential/file publication stays with the existing materializer. Codex/Agy
hook token environment delivery is a remaining contract gap, not something this
constructor silently omits. Actual admission, sandbox execution, gateway and
managed Agent acceptance remain incomplete. Global Bee is unchanged.

### September 13 — Docker resource mounts (Codex with Luna high)

Docker preparation now accepts a bounded list of admitted resources rather than
one project path. It preserves each mount's access, rejects ambiguous targets
and private-home exposure, and accepts a working directory under any selected
mount. The former workspace fields are refused. Source normalization is not
filesystem authorization; the placement owner still has to resolve and recheck
each grant before creating a container.

Strict lint, 854 Lua tests and the Go/real-Lua-HTTP-client Docker fixture pass.
The fixture checks simultaneous read-only project and writable output binds.
Full `make check` is running against the atomic-FS candidate; evidence is in
`bee-evidence/0912/bee-docker-mounts-check.log`. No Docker profile was enabled and
global Bee was not changed. Wolfden 1628 records the preceding ownership-policy
proof: existing principal-level expression policies avoid a required broker
spawn redesign, but do not replace the trusted durable-attempt check.
