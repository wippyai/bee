# Global Bee build — September 12, 2026

## Current install: configure missing dependency parameters

Global SHA `4f93cc36b6bb3e2b95fc81908f78c2344a9836de5feba63f64bf1843670d6b64`
contains source `c5f636e`. Missing dependency parameters can be edited directly
from plan rows or Configure required (E). Saving invalidates the old plan;
publication still requires a new measured plan and confirmation.
Strict lint, source/pack editing/replan/recovery checks and full native binary
acceptance pass. About, Modules redesign and global MCP are preserved.
Evidence: `hub-missing-configuration-check.log`, `hub-plan-config-native-check.log`,
`hub-plan-config-global-install.json`. The combined full repository gate runs
separately in `hub-current-full-check.log`; completion is not yet established.
The installer fenced against `adeb373c`, backed up/hash-verified the executable
and five sidecars, and checked matching runtime/native/patch identity. No nodes
were restarted. Earlier checkpoint sections follow.

## Current install: About and Modules override reset

Global SHA `adeb373c181a5f0f3e4de67aa570c3d215951622111f04ed8ea25ac6ac90dbe6`
contains production source `491ad5b`. Settings → About shows the loaded bundle's
version, build/source revision, runtime commit and patch identity, native version
and website. Long fields wrap and scroll. Development source explicitly reports
unknown build details, and dirty builds retain that marking. Modules adds Clear
override to restore a declared default without publishing an installation.

This release preserves global MCP source `9da558b` and the Modules redesign.
Runtime base `291f5c6b`, existing HTTP patch SHA `e6903cb4` and native revision
`0f63d30bd718` match the previous global install; this lane changed none of them.
Source/pack About and override-reset checks, 11 packaging tests and combined
native desktop/Modules/About/Agent acceptance pass. All 777 units passed on
pre-MCP About source `541220c`; that is not a full combined-suite claim.
The earlier full repository run on source `2d9cd31` ended with exit 143 without
a test-failure report and remains incomplete.

Evidence: `about-source-pack-check-3.log`, `about-unit-check.log`,
`about-current-native-check.log`, `hub-requirement-reset-check.log`, and
`about-global-install.json` under September 12 local evidence. The installer
fenced against `887d0769`, backed up and hash-verified the executable and all five
sidecars, and verified matching runtime/native pins and patch hashes. Backup:
`global-before-about-887d0769`. No running nodes were restarted; they continue
using their loaded UI until restart. Earlier checkpoint sections follow.

## Current install: managed MCP and lifecycle hooks, latest Modules UI

Global `887d0769562a5f8c64362313e833ad513374b6aa41c330ddf7c1e4e89e045fc9`
uses combined source `9da558b`. It preserves Hub requirements, package database
migrations and the redesigned Modules UI, and enables the native loopback
port-zero gateway. All four managed window profiles declare `thread_read` and
`thread_wait`; Claude/Codex also declare five lifecycle hooks. Agy/Grok HTTP
hooks remain unsupported.

The native selector proves Claude/Codex fixture children use their generated
configuration and delivered token to initialize MCP, list exactly two tools,
read their bound thread and wait. Separate native-window acceptance proves hook
delivery into threads. Two-runtime gateway checks and combined native binary,
Modules and Agent acceptance pass. The earlier MCP snapshot passed 776 unit
cases; the combined Hub slice passed 71 focused cases. Full regression remains
running, so this is not a complete release acceptance or real-provider proof.
Docker, writable coordination tools and editable profile memory/instruction
builders remain unfinished.

Receipt: `managed-mcp-modules-global-install.json`; all six files were fenced,
backed up and verified. Backup: `global-before-mcp-modules-9c70d927`. Running
nodes were retained and keep their loaded code. Use a fresh node for this build.

## Previous install: Modules layout and configuration dialog

Global SHA `9c70d927590a5988ad3239b378bcb10885a488770642b31254d4e85041c85ebf`
contains source `7649cd7`. Modules separates titles, versions and descriptions,
exposes search/filter buttons, opens package details on README and presents a
configuration dialog. Invalid JSON keeps the editor open. All prior Hub and
Agent features are preserved; runtime/native pins are unchanged.

72 focused cases, source/pack interaction and full native binary acceptance pass.
Rendered catalog, README and editor screens were inspected. Evidence:
`hub-redesign-final-focused.log`, `hub-redesign-ui-4.log`,
`modules-redesign-native-check.log`, `modules-redesign-global-install.json`.
The installer verified and backed up the executable and five sidecars against
previous global `7ba0b747`. No running nodes were restarted; retained nodes keep
their loaded UI. About/build information remains in progress.

## Previous install: Hub requirements and package databases

Global SHA `7ba0b747ff45661f93be0cbcfec4bfc588b9cb17deeaf4558e0e5067e6d7ed29`
contains production source `bd95d44`. It preserves Agent profile details and
persistent instructions from `d05b47c`, and adds the Modules Requirements tab
(`E`): inspect declarations, view default/selected JSON and targets, and edit
values by exact identifier. Defaults remain implicit until changed.

Hub now supports package-created SQL resources with captured database definitions,
an empty-ledger checkpoint, crash recovery and rollback. Migration calls retain
host grants while stripping Hub's private publication and worker permissions.
Runtime remains `291f5c6b`; native remains `0f63d30bd718`.

Strict lint, 71 focused Hub cases, source/pack requirements and recovery UI,
Go SQLite migration/checkpoint/crash/rollback acceptance and full native binary
acceptance passed. Acceptance source `766aa42` includes the Go test port.
Evidence: `hub-requirements-editor-unit.log`, `hub-requirements-editor-ui.log`,
`hub-database-go-service.log`, `hub-requirements-native-check.log`, and
`hub-requirements-global-install.json` under local September 12 evidence.
The full repository gate remains outstanding; these focused results do not
establish completion of all Hub/module-management work.

The installer fenced against `4a35163e`, backed up and verified the executable
and five sidecars. Backup: `global-before-hub-requirements-4a35163e`.
No running nodes were restarted; retained nodes continue their loaded code.

## Previous install: visible Agent profile summary

Global SHA `4a35163ef401c974b3087640460548a9027314c8c880fcb6a37c0cec1d96a340`
uses source `d05b47c`, retaining Agent instructions and Hub rollback. The picker
shows selected folder policy, whether instructions are configured, and configured
tool count. The count does not claim live MCP activation or authorization.
Native Claude/Codex launch checks prove all three details fit the default window;
private instruction text is excluded by the focused selection test.

Validation: initial 772 unit cases, final 14-case selection/view proof, strict
lint, standalone build and native selector (four profiles, F12, project cwd,
retained HOME, present/absent machine login). The initial native check caught an
incorrect fixture expectation and clipped wording; the final native check passes.
The previous combined source full gate remains running, not claimed passed.
Receipt: `agent-profile-details-global-install.json`. Executable and five sidecars
were fenced against `f1a29d08`, backed up and hash-verified after replacement.
Backup: `global-before-profile-details-f1a29d08`. No running node was restarted.
Production MCP, Docker and editable profiles/instructions remain unfinished.

## Previous install: Agent instructions plus Hub rollback

Global Bee SHA `f1a29d083ff1620e8e12757d80c954017833e82dc52d8caf18d06651bcfc4577`
contains production source from `660b769`: four-driver persistent instructions,
Agent recovery/machine login, and Hub history/migration rollback together.
Strict lint and 772 unit cases pass. Native desktop, Modules and Agent selector
acceptance pass, including project cwd, retained private HOME and present/absent
machine login. The Go Hub service acceptance includes rollback and crash recovery.
Source/pack connection UI passes after adding the missing governance database
fixture override; the earlier full gate's 1.052-second exit remains an unexplained
timing failure, not a passing full-suite claim.

Executable and all five sidecars were fenced against the previous `1da5b5c6`
installation, backed up, replaced and hash-verified. Receipt:
`instructions-rollback-global-install.json`; backup:
`global-before-instructions-rollback-1da5b5c6`. No running node was restarted.
Production MCP activation, Docker execution and editable instructions UI remain
unfinished. Older checkpoints below describe their respective installations.

## Previous install: durable migration rollback

Global Bee now has SHA
`1da5b5c66e897413c104502b1cf96a8a1e11a7c178564d9cd15eaa2fbb3cf7ea`,
source `b8dd68c`. Module removal can explicitly roll back migrations, including
orphaned dependencies. Confirmation lists the affected migrations. A durable
receipt precedes rollback; partial failure retains definitions and records
completed work. Recovery checks root, inventory, definitions and grants, skips
already-reverted ledger rows, and commits root deletion with its publication
receipt. Restart after deletion verifies inventory without calling removed code.

Strict lint, 69 focused Hub cases, real SQLite rollback/crash/partial-recovery
acceptance and source/pack rollback review/confirmation pass. Native desktop,
Modules and Agent acceptance passed on logic source `303b9e8`; `b8dd68c` changes
only the packaged Hub README and passes native Modules again. Exact evidence:
`hub-rollback-unit-2.log`, `hub-rollback-ui-2.log`, `hub-rollback-service-3.log`,
`hub-rollback-native-check.log`, `hub-rollback-release-modules.log` and
`hub-rollback-global-install.json`. Full rollback and preceding history checks
remain active in their respective `hub-rollback-full-check.log` and
`hub-history-release-full-check.log` files.

Runtime/native pins are unchanged. Executable and five sidecars were verified
and backed up before replacement, after rechecking global was still `2f3f8e5a`.
Backup: `global-before-hub-rollback-2f3f8e5a`. No running node was restarted.
Migration targets created by the same installation remain unfinished.

The separate Agent integration adds persistent instructions for all four harnesses.
Its combined history run passes 771 unit cases; the frozen full gate stopped
at a 1.052-second exit against the one-second limit. Instructions are not yet
installed. The built instructions/history candidate omits this rollback update
and must not replace the newer global executable.

## Previous install: Hub operation history and recovery review

Global Bee now has SHA
`2f3f8e5ab1f970c4acbe070da10530ba6ceec828b13972421052457f028001d3`,
source `efa29db`. Modules adds Operations (O), paged caller-owned receipts,
scrollable stored requests and migration results, and separate explicit recovery
confirmation. Status access remains read-only; retries use the original request
and digest. Older receipts without a stored request remain view-only.

The build passes 68 focused Hub tests, real history/privacy/migration acceptance,
source/pack cold recovery review/cancel/confirm/status and native desktop,
Modules and Agent checks. A source-free probe also opens the real empty history
and retains it across F12. The first history build and full regression exposed
a page-number inference error in a different lint composition; explicit integer
decoding fixes it. Strict release lint and service checks pass. The corrected
full run remains active in `hub-history-release-full-check.log`; the earlier
migration source full run passed in `hub-migration-full-check.log`.

Runtime and native pins are unchanged. Executable and five sidecar hashes were
verified before and after replacement, with a final check that global was still
`f276bc2b`. Evidence: `hub-history-global-install.json`,
`hub-history-native-check.log`, `hub-history-native-history.log`,
`hub-history-release-service.log`, `hub-history-ui-app-3.log` and
`hub-history-ui-unit-3.log`. Backup: `global-before-hub-history-f276bc2b`.
No running node was restarted. Migration rollback and databases first created by
the same installation remain unfinished.

## Previous install: Hub migrations plus default machine login

Global `/home/wolfy-j/.local/bin/bee` now has SHA
`f276bc2b0edaa85d1385e91783f4820156f41cb1730cefd410e3089e0546d100`,
source `f5beb06`. It retains installed Agent recovery and optional machine-login
behavior and adds host-granted Hub migration `up`, selected database requirement
planning, durable migration results, and explicit ledger/definition recovery.
Removal checks include orphaned dependencies; explicit `leave` preserves schema.
Migration `down`, newly installed database targets and operation-history UI remain
unfinished. See [Hub](../HUB.md) for exact grants and callable behavior.

The candidate passes 63 focused Hub tests and actual local-Hub publication/SQL
acceptance, including schema-commit SIGKILL/restart, partial failure/retry,
changed-definition refusal, linked database requirements and denied database
access. Native desktop, Modules and Agent present/absent machine-login checks
pass, as does native Modules install/update/uninstall. A native Agent fixture
initially lost unchanged rows in partial terminal redraws; its bounded screen
reader now passes the regression and actual selector acceptance. These are
focused combined-source and native results; the original Hub source's full
repository run has now passed, separately recorded in `hub-migration-full-check.log`.
That run covers source `0b63194`, not the later combined history UI source.

Runtime `291f5c6b708c` and native `0f63d30bd718` are unchanged. The executable and
five sidecars were verified against their provenance, backed up, and replaced
only after rechecking the previous `acab69b8` files. Evidence:
`hub-migration-final-source-check.log`, `hub-migration-final-native-check.log`,
`hub-migration-global-install.json`; backup `global-before-hub-migrations-acab69b8`.
No running node was restarted. Retained nodes continue their loaded code until
the user restarts them.

The Agent lane additionally proved both Claude and Codex with present/absent
synthetic login sources against the preceding `acab69b8` global; that provider
coverage is retained alongside this branch's current-screen reader. Evidence:
`claude-codex-global-login-check.log`. Combined coverage on the newer global passes as well: `make
native-agent-selector-check` exercised both providers with present and absent
synthetic login sources (`hub-agent-combined-selector-check.log`). This verifies
credential delivery and terminal behavior, not paid-provider authentication.

The combined source checkpoint passes lint and all 764 unit cases. Both Hub
migration acceptance entrypoints now run in Go, with SQL up/replay/down,
permission denial and schema-commit crash/restart checks passing through their
Makefile targets (`hub-migration-go-final.log`). Test sources remain outside the
production pack. These test changes do not require replacing the installed
executable, whose production source matches this integration.

## Previous install: default machine login plus Agent recovery

Global has since advanced to SHA
`acab69b8e487c4743cfa3967cf32a74add001f77cfba42e9e9ffe4454bd7036a`,
source `f4e3993` (the candidate preceded documentation/test-only final edits).
`machine-login-global-install.json` records native desktop, Modules and Agent
acceptance, preserved running nodes, and backup
`global-before-machine-login-849166aa`. The Hub migration integration now includes
this installed source plus selected migration database requirements. Its next
candidate has not yet replaced global.

## Previous install: Agent recovery plus Hub recovery

The executable and installed provenance now agree on SHA
`849166aaffa7a12688396513f8a7be688da7d75d3b43816a150dee21f9970028`,
source `32cd49f`. It adds retained Agent recovery and credential availability.
Runtime `291f5c6b708c` and native `0f63d30bd718` are unchanged. Local evidence is
`agent-recovery-global-install.json` and `agent-recovery-native-check.log`;
the latter passes native desktop, Modules and Agent selector/cwd/private-home
acceptance. The prior executable and sidecars are in
`global-before-agent-recovery-65b91124`. Running nodes were not restarted.

The Hub migration candidate merges this installed source with Hub commit
`0b63194`. It has not replaced global; combined acceptance remains pending.

## Previous install: Agent activity titles plus Hub recovery

Global was subsequently refreshed by the Agent lane to SHA
`65b91124c7dce25cc3b0c72ed51e31bd571bcbc15342caaf8b0c8b02d0dce7bb`,
source `3e0a3af`, retaining Hub recovery and adding confirmed-hook activity
titles. The installed provenance and `title-hub-global-install.json` agree.
Runtime and native pins are unchanged. Native acceptance is recorded in
`title-hub-native-check.log`; the previous executable and five sidecars are in
`global-before-title-hub-237d76a8`. Running nodes were retained. The segmented
foundation results below describe the preceding combined source and its fixture
corrections, rather than a full check of every subsequent Agent change.

## Previous install: Hub recovery and managed Agent profiles

Global `/home/wolfy-j/.local/bin/bee` has SHA
`237d76a84ff13494be90d9e360234ff43a3a172612121993ba2c0f3168edac61`.
Production source `c7bad34` retains the combined Agent build below and adds full
scrollable plan/confirmation effects plus explicit interrupted-publication
reconciliation. Acceptance checkpoint `f971b81` corrects desktop menu readiness
and the native selector's obsolete empty-catalog expectation. Runtime
`291f5c6b708c` and native `0f63d30bd718` are unchanged.

Focused Hub tests, Modules source/pack interaction, actual SIGKILL/restart and
later-conflict recovery, native desktop/Agent/Modules acceptance, and native
install/update/uninstall all pass. Evidence is under `bee-evidence/0912`:
`hub-combined-followup-check.log`, `hub-combined-native-corrected.log`, and
`hub-combined-lifecycle-check.log`. The earlier full Hub run passed 732 unit
cases but failed a Settings selector that matched the empty-desktop hint.
The corrected client-desktop suite passes all source/pack variants. The combined
run passes 746 unit cases, then stops on two managed-Agent fixtures (session-root
admission and a missing changed-profile notice). Updating those fixtures to the
current host root and setup refusal passes all five managed-window cases;
production permissions are unchanged. The continuation caught a transfer-restart
fixture admitting its replacement before host retirement. Checkpoint `f500961`
waits for the host's detach acknowledgment; source and pack now pass both failed
transfer directions. The complete foundation gate passes in segments after these
fixture corrections, including the separately completed launcher/recovery and
bundled-app tail. This is not an uninterrupted `make check` pass. Logs:
`hub-combined-desktop-check.log`, `hub-combined-full-check.log`,
`hub-combined-managed-corrected.log`, `hub-combined-check-remainder.log`,
`hub-transfer-retirement-check.log`, and `hub-combined-check-tail.log`.

The executable and five sidecars were verified after SHA-fenced replacement.
Previous `edf6a7c3` files are in `global-before-combined-recovery-edf6a7c3`;
`hub-combined-global-install.json` records the install. Running nodes and their
terminals were retained; the new executable takes effect on a fresh node.
Migration execution, operation-history UI and overlay activation remain
unfinished. See [Hub](../HUB.md) for the callable operations and recovery limits.

## Previous install: Hub and managed Agent profiles

Global `/home/wolfy-j/.local/bin/bee` has SHA
`edf6a7c3e3f0b8a767ab0a1075043d60ada03420b6c5d4192df9239e03ca6eeb`.
Production source is `c6d20c5`, combining installed Hub `93ad6d7` with Agent
`45b7cea`; native `0f63d30bd718`, runtime `291f5c6b708c`. All 20 packs and five
sidecars are retained. The prior `7764156f` executable and sidecars are backed up
under `bee-evidence/0912/global-before-agent-hub-7764156f`.

The combined source passes 745 unit tests. Actual native acceptance proves the
default profile picker, disabled unavailable selection, F12 and close without
creating work, plus Modules filters/F12/resize. The actual installed global
also launches a fixture Codex through Agent in the project cwd with a separate
session home; files survive app and node exit. Evidence is in
`bee-evidence/0912/agent-hub-{global,installed}-*`.

Run `bee agent`, or open Agent from the menu, on a freshly started node. Existing
retained nodes keep their loaded code until restarted. Automatic credential
setup, cold conversation recovery, production MCP activation, Docker, profile
replication and hook-driven titles remain unfinished. This is not complete
managed-agent acceptance. At this checkpoint the native selector script still
expected an empty catalog; default-profile acceptance was a temporary probe.
The current checkpoint above updates the permanent test.

## Previous install: Hub lane refresh

The Hub lane subsequently installed `acb59231c7aba26ec5eecdc9286e795821704b12088d09d9f574daf46094a876`
from production `3d82628`, retaining all four driver packages. Wolfden checkpoints
1388–1389 record its acceptance and an active real-user retained-node attachment
incident. The Hub lane owns that investigation. Agent UI changes below remain
separate; this lane has not replaced that binary.

## Previous install: four harness driver components

Global SHA256 `78aae0b0a16c3d65222f0c35425d3a5e1deb229e3ba8fe34ddda4f0d58d966dc`.
Production source `0e59a16`; checkpoint `bf8da36` adds test-only corrections.
Runtime `291f5c6b` and native `3e895bae936f` are unchanged. All 19 assembled
packs, 633 entries and license/provenance sidecars were verified before atomic
installation. No test/fixture entries or embedded assets ship. The previous
global is saved as `bee-evidence/0912/global-before-four-drivers-55b725aa`.
Running nodes were not restarted.

Claude, Codex, Agy and Grok now have separate driver packs and explicit host
activation. The credential broker includes bounded provider login-file sources;
this build still refuses their delivery to placement. Default production Agent
profiles, automatic login setup, managed MCP activation and Docker remain
unfinished. The public Agent picker is still empty. Retained-login delivery is
verified separately and is not part of this installed binary.

Native binary and the complete native client suite pass, including retained
terminals, observation, independent displays, concurrent cold admission and
reconnect after client SIGKILL. The installed-to-candidate upgrade preserves
Settings, workspace identity and applied migrations. All databases respect
explicit `--state-dir`; the default remains user-wide `~/.config/bee`.

The source gate passed 677 unit cases, native/managed windows and corrected hook
and module-isolation fixtures. The remaining `make check` desktop gates completed
successfully, including source/pack Hive Manager and Timeline. This is a segmented
full check after fixture corrections, not an uninterrupted run. Evidence is under `bee-evidence/0912`:
`four-drivers-global-{build,acceptance,install}.log`,
`four-drivers-installed-upgrade.log`, `four-drivers-pack-audit.json`,
`resources-module-go-check.log`, and `four-driver-credentials-check-remainder.log`.
The historical `native-upgrade-check` requires a pre-Hive Manager predecessor;
its refusal of the current installed predecessor is not upgrade evidence.

## Previous install: managed-agent components and scoped authoring

Global SHA256 `55b725aa8c4483037e3396d91860fc23159a6158e4b46c32435cade5298abe82`.
Source `97a9af2` on `feat/agent-integration-20260911`; runtime `291f5c6b`,
native `3e895bae936f`. Built through `make standalone` as
`bee-evidence/0912/bee-authoring-global-candidate` and installed atomically with
license/provenance sidecars. The previous global is retained in
`bee-evidence/0912/global-before-authoring-5c604fa7`. Running nodes were not
restarted; they retain their loaded code.

The user requested a global refresh with unfinished backends accepted. Native
terminal, scrolling/copy, presenter rejoin and the empty public Agent picker pass.
Managed profiles, provider configuration and five-hook integration components
are included, but default production profile setup, MCP listener activation,
Docker, Hub installation and DB-backed overlay activation remain unfinished.
The new authoring boundary preserves caller storage/scope denials while allowing
explicitly admitted workspace operations. All 626 unit cases and two-boot
authoring checks pass. The complete source `make check` also passed (session
43383, `authoring-scoped-check.log`), including native identity/installer/bundle,
module isolation, storage, source/pack desktops, launcher/recovery and app gates.
The existing desktop-lifecycle type-convergence warning remains.

The real installed-to-candidate upgrade preserves Settings, workspace identity
and applied migrations. All manifested databases respect explicit `--state-dir`.
Both the previous and current binaries default to user-wide `~/.config/bee`;
automatic per-project node selection remains unfinished. This limitation was
disclosed before installation; no launcher wrapper was added.

Public client acceptance covers retained terminals, independent displays,
observation, concurrent cold admission and reconnect after client SIGKILL.
Its initial run passed behavior checks but hit a temporary-directory cleanup race
when a shell recreated `.bash_history`; the unchanged concurrent-start and
crash-recovery continuation passes. This is segmented client validation, not an
uninterrupted client-suite pass. Evidence under `bee-evidence/0912`:
`authoring-global-{build,native,client,client-continuation,upgrade}.log`.
All 15 assembled release packs load with 610 entries and no test/fixture
registrations or embedded assets (`authoring-scoped-pack-audit.json`).

## Previous install: live local Hive display catalog

Global SHA256 `5c604fa7ab5f3c7eaa903c7ed2a79c8eb8b467fa6c0ee738b1c016471c9e026a`.
Production source `7bee2ab`, artifact `/tmp/bee-live-catalog-locality-20260911`.
Native `2a2117ad4fe7`, runtime `674b58a1`, builder `70acb10175fb` unchanged.
Atomic installation verified binary and provenance/license sidecars; backup
`bee.previous-live-catalog-20260911T172742Z`. No running user process restarted.
Existing running nodes keep their loaded source until restarted.

Hive Manager can now browse the local workspace's retained displays through
supervisor-authorized catalog reads. Unknown occupancy is shown honestly;
listing grants no attachment or native control authority. Remote browsing,
connecting through the app and workspace switching remain unfinished.

Candidate acceptance passed 535 unit tests, source/pack architecture573 and
application checks, native client/transfer/catalog/connection checks. The final
local-only PID fix passes a real-actor admission/revocation test, which fails when
the old comparison is restored. Final rebuilt binary catalog and connection
checks pass with two physical clients, exact retained identities, F12 and reconnect.
This is focused/segmented validation, not a new uninterrupted full make check.
Evidence: `/tmp/bee-catalog-locality-reader.log`,
`/tmp/bee-live-catalog-locality-native.log`, `/tmp/bee-install-live-catalog-20260911.log`.

## Previous install: compact connection card

Global SHA256 `af1dc830badf03028deb071874a05152413b9b900bd93aace0369b4c3fdf5b79`.
Source matches `27f0383` (connection card `2385b82` plus honest unknown display
occupancy). Native/runtime/builder pins are unchanged from the transfer build.
Artifact `/tmp/bee-connection-refined-20260911`; verified atomic installation
with license/provenance sidecars, backup `bee.previous-connection-card-20260911T164814Z`.
No running user process was restarted; existing displays retain their loaded UI.

F9 now shows a compact44×13 card with aligned Hive/node status and grouped
workspace/display names. Click Details or press D for full identities. Inside
clicks no longer dismiss the card. Source and pack acceptance cover Details,
F9/Escape, F12, stable identities and42×12 terminals. Standalone connection UI
acceptance passes, including controller reconnect. Build and lint pass with the
existing desktop_lifecycle convergence warning. Occupancy projection changes
passed530 Lua tests before the card edits. This small follow-up has focused UI
acceptance, not a new full foundation run.

Evidence: `/tmp/bee-connection-refine-check.log`,
`/tmp/bee-connection-refined-native-check.log`, `/tmp/bee-install-connection-20260911.log`.
Live Hive Manager browsing/switching remains unfinished.

The broader compact-card validation has now completed in segments on frozen
checkpoint `6c9d850`: source/pack storage and subscription restart, resources,
desktop interactions, independent clients, app transfer, retained-supervisor
recovery, local launcher, recovery and bundled apps all passed (tail process
14472, exit 0). The earlier composite stopped because its temporary fixture
captured an unfinished catalog edit; that edit was never installed. This is
segmented acceptance, not an uninterrupted full `make check`.

## Previous install: app transfer between displays

Global SHA256 `2569142fc3ba3b6fc95ffbf5fc09f9377ab3e4ceca742b5661917ab076a0e847`.
Production source `4e57054`, build checkpoint `8d16dc5`. Native `2a2117ad4fe7`,
runtime `674b58a1` and builder `70acb10175fb` are unchanged.
Artifact `/tmp/bee-app-transfer-final-20260911`; backup
`bee.previous-app-transfer-20260911T163644Z`. Installed atomically with verified
provenance/license sidecars. The exact previous Bee process was retired through
its validated pidfd; application databases were preserved.

Right-click an app tab/title → **Send to display** moves its control assignment
to another available display in the workspace. Two public native clients prove
the same shell PID and in-memory state survive; the neighboring app and source
F12 remain intact. Read-only observers keep their selected views independently
of control assignment. First controlling bind claims an exact live restored app
when it has no assignment yet; pending and foreign assignments stay fenced.

Validation: 529 final unit tests, source/pack architecture572, both final executable
suites, public native app transfer, complete client-desktop suite, full launcher,
recovery and bundled-app tail pass. The foundation run passed module, headless,
workspace-host and storage/resource gates. Desktop acceptance was completed in
segments after fixing duplicate binds, observer projection and initial restored
assignment; an obsolete two-migration recovery assertion was updated to three.
There is no claim of one uninterrupted final `make check`. The existing
`desktop_lifecycle` convergence warning remains.

Actual-user cold frame **1.433s**, warm frame **0.209s**, detach **0.101/0.112s**,
catalog **0.222s**, all exit zero. F9 confirms Antares and the same friendly
workspace/display identities. Logs: `/tmp/bee-transfer-global-install-20260911.log`
and `/tmp/bee-transfer-global-smoke-20260911.log`.

Live Hive Manager desktop browsing/attachment, workspace switching and broader
remote enrollment/recovery remain unfinished. This release does not establish
portable native-process recovery after workspace-host death.

## Previous install: friendly workspace and display labels

Global SHA256 `3e39e45f1d17c9a00a45ef4e4aa56f41d5f0f844ac9f24fd12309d004ed1e888`.
Sourcee3938a2 includes public display recoverye75eaa9 and lifetime81f72d1.
Native2a2117ad4fe7, runtime674b58a1 and builder70acb10175fb are unchanged.
Artifact `/tmp/bee-display-labels-candidate-20260911`; backup
`bee.previous-display-labels-20260911T135913Z`. Installed atomically with all
license/provenance sidecars, then restarted by validated pidfd; DBs preserved.

Stable friendly workspace/display names now appear in the shell, F9 dropdown,
Hive Manager and workspace-unavailable inbox messages. They are presentation
only; complete IDs remain in connection details and attach confirmation. Hash
fragments are not uniqueness guarantees. Source/pack dropdown checks prove full
ID visibility and F12 stability, including compact rendering. Hive Manager
interaction checks, architecture568, lint, build and both executable suites pass.
Actual-user cold frame1.551s, warm0.209s, detach0.114s each (exit zero),
catalog0.199s (exit zero). F9 reports the real local Hive service and Antares;
frame captured at `/tmp/bee-global-friendly-labels-frame-20260911.txt`.

Full foundation72192 completed successfully on lifecycle source81f72d1. It excludes
the later public activation and label deltas, which have focused source/pack and
executable proofs. App transfer and workspace switching remain unfinished.

## Previous install: public default-display reactivation

Global SHA256 `b3cebaaf9c39877ed1b153419e020071bb10356bbe3f0f0dea60a7ee7e4d2bdd`.
Sourcee75eaa9 includes independent retained display lifetimes81f72d1;
native2a2117ad4fe7, runtime674b58a1 and builder70acb10175fb are unchanged.
Artifact `/tmp/bee-default-reactivation-candidate-20260911`; backup
`bee.previous-default-reactivation-20260911T135154Z`. Atomic installation includes
all sidecars. The exact prior process was verified and restarted via pidfd;
application databases were preserved. Actual-user cold frame1.424s, warm0.215s,
detach0.164s/0.114s (exit zero), catalog0.200s (exit zero).

A fresh controlling attachment now activates any selected retained display,
including the default. Start → Exit closes that display; the next Bee invocation
reopens it with its running apps. Observers cannot activate a stopped display.
The executable negative proof returns NOT_FOUND on the prior binary; the new
binary preserves shell PID and an in-memory variable across close/reopen and
refuses the observer before control reactivation. The complete native-client
suite passes, including that new proof. Logs:
`/tmp/bee-default-reactivation-{negative,positive,observer,client-check}-20260911.log`.
Full foundation72192 passed on lifecycle source81f72d1; it does not
include the one-line public activation follow-up. Friendly labels are separate.
The cause of the earlier spontaneous display crash remains unexplained; these
changes prove containment and public recovery, not absence of future crashes.

## Previous install: independent retained display lifetimes

Global SHA256 `c91809cb6eac44e29d0268130193052f2ac5d1965a2b526b376909f0ea7b4aab`.
Source81f72d1, native2a2117ad4fe7, runtime674b58a1, builder70acb10175fb.
Artifact `/tmp/bee-display-lifetimes-candidate-20260911`; backup
`bee.previous-display-lifetimes-20260911T134612Z`. Atomic installation includes
all license/provenance sidecars. Exact process identity was checked before
pidfd restart; databases were preserved.

The initial retained display now uses the same lifecycle as other displays.
Its exit no longer shuts down the workspace and other apps. Six source/pack
retained scenarios and both native-client/binary suites pass. Actual-user cold
frame1.446s, warm0.222s, clean detach0.114s each, catalog0.204s. Full foundation
check72192 passed on this source. Friendly labels are not included.
The initial spontaneous display failure remains unexplained; the injected crash
proof establishes containment and direct retained reactivation only. Public Hive
admission still needs review for default-display reactivation after display exit.

## Previous install: Hive name recovery

Global SHA256: `82afdae8791a79fc45703ea61134f48c652794d96da3ba913a776702a9e7dc50`.
Application fix `6c6c574`, native `2a2117ad4fe7`, runtime `674b58a1`,
builder `70acb10175fb`. Artifact `/tmp/bee-hive-name-candidate-20260911`;
backup `bee.previous-name-recovery-20260911T133017Z`. Installed atomically with
license and provenance sidecars, then restarted using validated process identity
and a pidfd. Existing databases were preserved.

Bee's production policy now grants eventual-name unregister as well as register.
Previously a retained desktop exit could leave the supervisor name behind and
make every restart fail with `eventualreg: name already registered`. Cleanup
failures and the original retained-process result error are now reported.
Native regression `5545061` uses the production policy and real eventual naming:
removal releases the old name and re-add publishes a fresh PID. Removing the
unregister permission reproduces the stale-name failure; restoring it passes.

Candidate lint, 11 production policy tests, standalone build and native-client
acceptance pass. Actual-user installed smoke: cold frame 1.976s, warm frame
0.218s, detach 0.114s each (exit zero), catalog 0.203s (exit zero).
A private ten-minute diagnostic run completed 20 successful catalog requests
without a captured service failure. This does not explain the initial unexpected
retained desktop exit or establish sustained multi-node recovery. The full
foundation check on retirement source completed successfully (session 80193,
exit zero): 516 Lua tests, storage/module/permission gates, source/pack desktop
interactions, client lifetimes, recovery and bundled apps. Evidence:
`/tmp/bee-retirement-foundation-check-20260911.log`. This full run predates the
name-cleanup source delta, whose focused policy/native proofs are listed above.

The installed name-recovery build also passed a ten-minute, 20-cycle actual-user
reconnect run (session39137, exit zero). Catalog calls took0.139–0.229s,
frames0.102–0.224s and every detach0.114s. Evidence:
`/tmp/bee-global-reconnect-soak-20260911.log`.

A separate source candidate `81f72d1` gives the initial retained display the same
independent lifetime as all other displays. The baseline fails the injected
initial-display crash; the candidate passes source/pack with the other display's
shell and the original default shell preserved. All six retained lifecycle
variants and the standalone build pass. Full check72192, native-client70191 and
native-binary39180 are running. Artifact:
`/tmp/bee-display-lifetimes-candidate-20260911`. Not installed globally yet.

The installation records below are historical.

## Previous install: membership retirement

Global SHA256: `723fb40b8c32ee277d8dcda8041e51499bb1c0adf3f0cf54c01115f75303802f`.
Application source `6b2da06`, native `2a2117ad4fe7`, runtime `674b58a1`.
Artifact `/tmp/bee-retirement-candidate-20260911`; backup
`bee.previous-retirement-20260911T125322Z`.

Hive Manager retires departed presentation rows after 60 seconds of absence in
complete samples. Partial samples update reported members without proving other
nodes absent; the cache remains bounded. Returning nodes clear departure status,
and retirement clears stale selection hints. Saved layouts/apps remain intact.

All 516 Lua tests, standalone build, native-client and native-binary checks pass.
Logs: `/tmp/bee-retirement-recovered-test-20260911.log`,
`/tmp/bee-retirement-{build,client-check,binary-check}-20260911.log`.
A guarded restart loaded this install into the actual user's workspace: first
frame 1.428s, detach 0.090s, exit zero. Databases were preserved.
The intermittent catalog/startup stall remains unresolved. A separate private
trace build is for diagnosis and is not installed globally.

The installation records below are historical.

## September 11: installed detach acknowledgment update

Global `/home/wolfy-j/.local/bin/bee` SHA256:
`1206b961045cb761cb3cd7d4ba49aeb5a90d0c12043d372151cb0ebeafde4225`.
Application source: `80611ee`; native: `2a2117ad4fe7`; runtime:
`674b58a1a117fa79398f723c4311201cca8472e1`; builder: `70acb10175fb`.
The only native production change from `a0fc01e088b2` increases detach
acknowledgment allowance from 200 ms to one second; successful replies return
immediately. Backup: `bee.previous-recovery-20260911T123909Z`.

The standalone build, native-client acceptance, native-binary acceptance and
30 overlapping three-client reconnect rounds passed. Evidence:
`/tmp/bee-recovery-{build,client-check,binary-check,reconnect}-20260911.log`.

**Actual-user startup remains broken intermittently.** After installation, a
PTY attachment against `/home/wolfy-j/.config/bee` remained at Connecting for
25 seconds without its first frame. The probe client was stopped; the retained
Bee and databases were preserved. Evidence:
`/tmp/bee-global-real-workspace-20260911.log`. These passing isolated gates do
not establish a fix for the user's startup or expired-mount failure.
The 60-second departed-display retirement work is not in this install.

Everything below is historical installation evidence.

## Current install: display isolation and direct appearance routing

Global `/home/wolfy-j/.local/bin/bee` now has SHA256
`ac0871a31007c4638c84d9e6836d512750e1ebdbbd1447eb96adfa626424416b`.
Artifact: `/tmp/bee-greenfield-global`. Runtime remains `674b58a1`; native remains
`a0fc01e088b2`. Settings allows independent instances, display custom/inherit mode
is persisted, and workspace-wide appearance writes/unscoped fallback are removed.

Standalone executable and actual two-display appearance acceptance pass. The
actual user's prior Bee process was stopped with SIGTERM; databases were preserved.
The installed build reached the existing desktop in 1.941s, F9 opened, and the
client detached in 0.072s. Backup: `bee.previous-display-20260911T023511Z`.
Logs: `/tmp/bee-greenfield-global-{build,install,smoke,native,appearance}.log`.

The wider cleanup is unfinished. Full current-cleanup repository acceptance is
not complete; the predecessor passed 511 Lua cases, and remaining desktop checks
are still running on that predecessor. No sustained mesh-recovery claim is made.
The dated installation descriptions below are historical, not the current binary.


This page describes the current global executable and its verified capabilities.
[Earlier build history](GLOBAL_BUILD_HISTORY.md) preserves failed runs and older
measurements; those entries do not describe the current install.

The user has since reproduced a mount-expired/revoked failure on this installed
build, followed by a60-second read-only catalog timeout. A guarded restart
restored access; the cause remains unresolved. Journal909 records the actual
process stack and reproduction. Passing acceptance below does not prove sustained
reconnect reliability. The current retained process after recovery is2493278.

## Reconnect investigation

The opt-in `make native-reconnect-check` reproduced detach uncertainty twice
with three overlapping clients and retained Hive Manager. In one failure the
service still answered the following catalog request in 0.291s. A separate
30-round run passed, so this remains intermittent. Ten idle reconnects with
Hive Manager also passed.

A private 750 ms detach-budget candidate (`094d0c4416dd`, binary
`/tmp/bee-detach-budget-candidate`, SHA256
`deb6a3e888e04ba178aeb61577eaa47289e6f1581152ab6f06bf72ac3fb788db`)
passed native race/vet, client acceptance and standalone acceptance. Its longer
stress check failed at round 46: successful detach took 1.090s, exceeding the
one-second exit requirement; the subsequent catalog took 1.739s. It is **not
installed or selected for builds**. The native pin now selects the separate cancellation fix `a0fc01e088b2`, retaining the original 200 ms detach budget.

A longer acknowledgment budget alone is insufficient. Diagnosis must distinguish
detach acknowledgment from native client shutdown. No cause or fix is established
for the separate actual-user expired mount and 60-second catalog stall.
Evidence: `/tmp/bee-detach-budget-reconnect-check.log`, fixture
`/tmp/bee-native-reconnect-i94l7w7b`.

## Installed

The global binary now includes the narrow physical cancellation-order fix:
cancel and join the input worker before closing its mount. A regression fails
without the change and passes with it; genuine delivery errors remain visible.
Native-client and standalone suites passed, as did mesh/physical, session and
retained-owner race/vet checks. The source and runtime are unchanged from the
previous install. Reconnect stress still reproduces pre-existing detach and
startup failures, so this is not a sustained-reliability claim.

Installed read-only attachment to the actual user's retained workspace reached
its first frame in 217 ms and detached in 87 ms. No owner restart or database
change was performed. Evidence: `/tmp/bee-cancel-drain-global-install.log` and
`/tmp/bee-cancel-drain-global-observe.log`. Backup:
`bee.previous-20260911T004912Z`. Artifact: `/tmp/bee-cancel-drain-candidate`.
The latest runtime-facing detach evidence is journal 935: accepted local send
in 21 microseconds, retained select resuming 599 ms later.

`/home/wolfy-j/.local/bin/bee` is the explicit-selection and Hive session-identity candidate:

| Component | Revision |
|---|---|
| Bee production source | `c3b2c9f` |
| Native Bee | `a0fc01e088b2` |
| Runtime | `674b58a1a117fa79398f723c4311201cca8472e1` |
| Builder | `70acb10175fbeb42a3a4d382677715a0c2a969e4` |
| Executable SHA256 | `2c1f11099dd970c12be11ee8cf7e51ad1521e093c94f1a880cfd1602d7908a61` |

The full foundation check passed (session61042, exit0): 494 Lua tests, 525
source/pack entries, storage, permissions, desktop/client lifetimes, recovery and
bundled applications. Evidence: `/tmp/bee-hive-session-identity-full-check.log`.
The existing `desktop_lifecycle` InterprocFacts convergence warning remains.

Plain `bee` loads embedded code with registry history and attaches through the
native mesh. A same-state lock conflict routes to authenticated attachment.
A second controller gets an independent retained desktop; an available desktop
is reused before another is allocated. `bee observe` explicitly shares the
default desktop read-only and refuses if no Bee is running.

Ctrl+Q and Ctrl+] detach the physical client and retain applications. F12 replaces
only the presenter. F9 or the workspace label opens compact Hive/node/workspace/
display status; Alt+F9 still minimizes. Named commands such as `bee terminal`
launch through the admitted workspace catalog. Native client-role metadata helps
Hive Manager distinguish clients from Bee services and grants no permissions.

Actual-user checks measured cold startup1.486s, warm control0.215s and
observe0.221s, with detach0.077–0.086s. These are individual measurements, not a
cold-start timing breakdown. The retained user process was2452472 after the
verified install; always revalidate the live process and executable before
restarting it. Logs: `/tmp/bee-explicit-selection-global-install.log` and
`/tmp/bee-explicit-selection-global-reconnect.log`.

## Explicit selection

The previous explicit-selection build artifact is `/tmp/bee-explicit-desktop-candidate`, from checkpoint
`checkpoint/explicit-desktop-selection-20260910`. Its production source is
`c3b2c9f`, native pin `ced4008999f4`, and runtime/builder are unchanged.
SHA256: `cbb6d6a5bc71b5c37b281f2b3075122e990296c50830d641c8fa21939f389e59`.
The previous executable is archived as `bee.previous-20260910T232822Z`.
Existing application databases were preserved.

It fences Hive Manager session presentation by node and owner generation and
adds authenticated commands against the running Bee selected by `--state-dir`:

```sh
bee desktops
bee attach WORKSPACE DISPLAY
bee observe WORKSPACE DISPLAY
```

Exact selection refuses occupied or foreign targets without allocating a
replacement. The executable passes explicit selection, the connection UI, three
independent desktops and the full native-client gate (74144, exit0), including
named commands, clipboard, stalled cancellation and client-crash reconnect.
Evidence: `/tmp/bee-explicit-desktop-client-check.log`.

The identical Lua source passed full `make check` (61042, exit0), and the
standalone binary gate passed (79123, exit0), including Settings recovery, native
Terminal, scrolling, selection/copy and source-free boot. Evidence:
`/tmp/bee-explicit-desktop-binary-check.log`.
The separate one-hour idle diagnostic50459 tests the previous installed candidate
in disposable state and remains pending.

## Remaining boundaries

Multiple neutral displays choosing and switching workspaces remains unfinished.
The current retained desktop client has one workspace host. Live Hive Manager
browsing/attachment, multi-host tab composition and public remote enrollment are
not implemented by the explicit local commands. See
[workspace attachments](../WORKSPACE_ATTACHMENTS.md).

The user's current reconnect failure is not explained by successful short
reconnect tests. New evidence: `/tmp/bee-user-failure-catalog-20260910.log` and
`/tmp/bee-user-stuck-owner-2452472.stack`. Runtime owner-isolation/session-loss completion recovery remains
a cluster-lane gate (journal894); no Bee monitor substitute is being added.
The candidate does not consume a released runtime main revision.

The initial Bee starts in its launching project directory; later same-state
clients do not change that directory. A binary update does not replace a running
Bee's loaded code. `--base` is a recovery choice, not required for embedded code.
Cold startup captures child output in private `owner-*.log` files; warm attachment
does not create an extra owner or log. Application databases are preserved.

## Rebuild and checks

Use the checkpoint's manifest and Makefile, keeping its pinned runtime:

```sh
make native-tools
make standalone
make native-client-check native-desktop-selection-check native-connection-ui-check
make native-binary-check
make check WIPPY="$PWD/.wippy/bin/bee-wippy"
```

Checkpoint branches are pushed for review. No Bee PR or main merge was made.
