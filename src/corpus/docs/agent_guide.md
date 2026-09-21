# Working on Bee

Read [the repository README](../README.md), [development conventions](DEVELOPMENT.md),
and the [documentation map](README.md) before changing Bee. Source
under `src/` is the runtime; tests, fixtures and the legacy proof of concept in
`../bee-legacy/` are never runtime dependencies.

Bee-owned code and artwork are MIT. Preserve the upstream license for Wippy and
other dependencies when changing or copying runtime code. Keep core ownership,
standalone application processes, typed boundary decoders and host-selected
permissions intact. Registry metadata describes capabilities; it never grants
them. Native Terminal runs with the operating system user's authority.

Keep desktop responsibilities in `src/core`, reusable appearance and public
application helpers in `src/ui`, and standalone applications in `src/apps`.
Use the [UI brand book](UI_BRAND_BOOK.md) and the runnable UI Guide for
presentation and interaction rules. The guide is reference source, not a
widget framework. Apps use public contracts such as `bee.application:client`
and `bee.threads:client`; they do not import private broker or store modules.

The workspace owns application state, checkpoints and its migration ledger.
Registry configuration/history, thread records, approvals, resources and
credentials remain owned by their respective subsystems, even when stores
share a SQLite file. Never edit an applied migration, alter a migration
checksum, query another owner's tables, or reset a workspace database to hide
a migration failure. Use an owner operation for every state change.

Use typed values for every decoded message and request. Validate versions,
identities, strings, arrays, state and request IDs before changing state. A PID
is an execution address, not a credential. Authenticate the message sender and
the relevant instance, token or operation grant. A successful send means
queued; it does not mean ready, committed or stopped. Timeouts can leave an
unknown result and must not cause a blind retry.

Use the Makefile for development:

```sh
make setup
make lint
make check
make pack
make standalone
```

`make run` starts an editable source workspace. `make desktop-check` runs the
desktop acceptance against the built pack, and `make attachments-check` covers
host/client attachment grants and revocation. Use focused tests while editing,
then the checks required by the changed boundary. Documentation-only changes
need link and source consistency checks; they do not need a full terminal run.

Production loads only `src/`. Keep binaries, registry stores, credentials,
fixture data and temporary databases outside the pack. Inspect assembled packs
for test registrations and fixture dependencies. Do not add a local runtime
binary or legacy source to production, and do not edit registry tables directly
to work around source loading.

The desktop client may replace only its presenter with F12. Workspace, broker,
session, host or application changes require the owning process lifecycle and
recovery path. Preferences and opted-in application checkpoints persist in the
workspace database. Settings opts in to checkpointing; a dead native Terminal
does not become a portable checkpoint. See
[application contracts](APPLICATION_CONTRACTS.md) for launch, attachment,
checkpoint and close behavior.

The host keeps application execution independent from presentation. A producer
may be ready without a presenter, a client may observe a retained desktop, and
attachments carry recipient-bound observation, input and resize authority.
Detaching a client does not stop admitted applications. A stale attachment
loses its authority. The public client and local host are implemented; remote
workspace composition, public Hive enrollment/discovery, destination Hub
transfer/install, and managed headless or Docker launch remain unfinished.
Keep those operations labeled as proposals until their acceptance contracts
exist.

`bee observe` attaches a read-only display to a running local Bee and never
starts or displaces the controller. `bee recover <name>` selects the embedded
application pack for a named managed launch while preserving workspace and
application state. These commands keep the local owner boundary; they do not
provide remote enrollment or workspace switching.

The local Hub can inspect, plan and apply host-authorized components. Governed
overlays can stage bounded content, freeze an immutable candidate, obtain an
exact approval, apply it through the owning host and recover after restart.
Hub discovery or installation alone does not publish an admission binding or
grant an application authority. Publication, public enrollment and destination
package transfer are separate authority boundaries; see
[package boundaries](PACKAGE_BOUNDARIES.md) and [the system map](SYSTEM_MAP.md).

When changing a behavior, update the relevant implementation contract and run
the checks for that owner. Preserve stable definition IDs independently of
versions and paths. Carry expected revisions, capability changes and recovery
information in activation requests. Describe whether an update supports live
rejoin, application checkpoint/restore or a full restart; do not describe a
proposal as a callable API.
