# Working on Bee

This guide describes available development operations. In-app self-edit, Hub
installation and MCP tools are planned in [PACKAGE_BOUNDARIES.md](PACKAGE_BOUNDARIES.md);
there are no published Bee tools for those operations yet.

Read `README.md`, `docs/FOUNDATION_STATUS.md` and `docs/DEVELOPMENT.md` first.
The [local acceptance checkpoint](LOCAL_FOUNDATION_ACCEPTANCE.md) separates verified
foundation work from the still-required headless/client milestone.
`docs/README.md` distinguishes current contracts from historical/design pages.
Keep desktop responsibilities
in `src/core`, reusable appearance in `src/ui`, and standalone apps in `src/apps`.
Use registry imports, explicit typed values and authenticated process protocols.
App metadata describes an app; it does not grant capabilities. New apps require
reviewed admission and an explicit scope. Do not grant generic applications the
Process Manager's inspection permissions or Settings' preference-write route.

Use `make lint` while editing. Run `make check` for behavioral changes; it covers
unit tests, source/pack isolation and actual terminal interactions. Extend the
acceptance harness for changed input, lifecycle or window behavior. Inspect
intermediate synchronized frames when testing animation or drag handoffs; an
eventually correct screenshot cannot reveal a one-frame jump.

`make pack` produces `dist/bee.wapp`. Production loads only `src/`; fixtures and
test dependencies belong to temporary test workspaces. Never add local runtime
binaries, registry stores, credentials or legacy source to the pack. Do not edit
registry database tables directly to work around a source-loading problem.

F12 replaces only the presenter. If workspace, broker or session logic changed,
exit with Ctrl+Q and run `bee` again. For editable-source development, use
`make run` as described in the development guide. Preferences and opt-in application
checkpoints persist in the workspace database. Settings opts in; Terminal does
not restore a dead PTY. See `APPLICATION_CONTRACTS.md` for the actual version-1
protocol; native process stacks are not portable checkpoints.

For future package work, preserve definition IDs independently of versions and
paths. Carry expected revisions, capability changes and rollback information in
activation requests. Document whether an update supports live rejoin, app
checkpoint/restore or a full restart. Do not describe planned operations as
already callable.

The thread authority and durable subscriptions now supply the communication
slice; Timeline is the read-only application, and Test Status has been removed.
See [the build sequence](BUILD_SEQUENCE.md) for implemented driver and gateway
components and their remaining public activation gates. Do not route new
authority through the desktop merely because it is the visible client.
The shared source currently needs the candidate runtime described in
[the runtime gate](handoffs/STATUS_RUNTIME_GATE.md); historical standalone
acceptance does not prove a release of these newer changes.

## Continuing the host/client work

Public `bee` and `bee-app` select
the independent client, with `bee:client_db` alongside the workspace database.
Legacy migration, full `make check` and standalone acceptance pass. Older selected
deployments may retain their code; `bee --base` selects the embedded baseline
without resetting application databases.
Use [client state](CLIENT_STATE.md) and the current command metadata for launch wiring.

Read [client/host extraction](CLIENT_HOST_SPLIT.md) for current coupling and
implementation gates, [workspace attachments](WORKSPACE_ATTACHMENTS.md) for
identity, Hive and portable application content, and
[foundation next steps](FOUNDATION_NEXT.md) for the later driver/self-edit sequence.
Do not create a parallel mesh, naming system or registry reconciler.

Current evidence: the broker retains ready producers without a presenter, its
attachment module retains one controller and up to 16 observer recipient/grant records per instance, and stale
mounts lose observation/input/resize authority after detach. The named-host fixture
uses native LOCAL registration after startup readiness. `bee.host:main` owns its
broker and persistence without a physical TTY. The local supervisor starts it;
the low-level `bee-host` entry can run that owner on `bee:workers` without a
desktop. It does not yet expose supervisor admission or discovery. There is no
managed headless launch profile, workspace switcher or `bee hive` CLI.
The host admits supervisor-selected client actors with explicit operation
permissions and connection IDs. Source/pack tests cover two clients, detach,
re-admission, exit cleanup and retained native terminals. See the internal
admission contract in `CLIENT_HOST_SPLIT.md`; it is not a remote enrollment API.
Admitted actors receive separate, connection-qualified catalog and live-view
snapshots, including apps opened before admission. These descriptions carry no
mounts or checkpoints. Source/pack checks cover title/exit updates and publication
fencing on detach; the desktop client consumes them. `bee.host.reply` results include a bounded
inventory snapshot so independent channel ordering cannot resurrect a removed tab.
The host also supports supervisor-selected renderer replacement under an existing
client connection. Bind requests carry the current renderer generation. Source/pack
tests cover old-grant denial, failed revocation, renderer exit and queued detach.
`bee.client:main` composes a display, session, presenter and client
store against one admitted host. Source/pack checks prove two independent desktop
actors, selected-tab isolation, F12 and fresh-client reattachment to a retained
Terminal. Guarded-close dialogs are tested across F12 and client reattachment.
Settings theme persistence, isolation, F12 and denied writes also have source/pack
acceptance. The local entry also proves presenter-crash recovery, bounded
pause for readiness or renderer timeouts, and supervised normal/emergency exit.
Its supervisor explicitly grants workspace appearance: the host commits Settings
writes before updating producer pages and client chrome. Ordinary clients retain
independent chrome; see the appearance contract for cross-store recovery.
Mixed workspaces remain unimplemented. See the verified local client acceptance
and remaining remote boundary in `CLIENT_HOST_SPLIT.md`.
`CLIENT_STATE.md` documents the client store and import receipt. Source/pack
migration tests now boot the actual old combined actor, then the public client:
workspace/application identities, layout and the original migration ledger survive,
and subsequent boots preserve later client edits.
The short workspace ID in the header is informational.

Establish the local owner boundary first; then the Hive and agent-integration
branches can proceed independently:

1. Complete explicit per-client attachments and the single-controller contract.
   Keep full workspace/instance/view identity and fresh execution references.
2. Separate the TTY-free workspace host from the desktop client. Prove two local
   clients with independent layouts, retained apps on detach and denied stale control.
3. Route the same owner operations through native mesh names. Destination owners
   establish actor/scopes after admission. Prove two actual Bee runtimes before
   claiming Hive support or publishing a remote workspace selector.
4. Add the Hive Manager and compact switcher over those operations. Save explicit
   join configuration once; fresh installs remain local-only.
5. Once the local boundary in steps 1–2 is stable, add registry-bound harness
   drivers, thread/run ownership and scoped hook/MCP configuration. This local
   branch does not depend on completing remote discovery or Hive Manager.
   Reviewed publication and the real self-edit demo follow its acceptance checks.

The registry owns definitions/configuration/history. Workspace application state,
journal events and exported application data retain their respective owners.
Transfer declarative content and explicitly supported state, not local credentials,
live PIDs or mounts. Legacy drivers are source references outside the repository,
never runtime dependencies. The current `bee codex/claude/agy` aliases launch native
programs; they do not yet configure Bee tools or recover harness conversations.

Use `make check` for production changes. `tests/lifecycle.py::detached` is the
named-owner/revocation gate; `tests/recovery.py` covers durable identity and state;
`tests/native_binary.py` checks the assembled executable. Runtime TTY proofs do
not substitute for Bee host/client acceptance. Leave cluster/Raft implementation
to its existing owner, and reproduce a TTY gap before requesting a #653 change.
