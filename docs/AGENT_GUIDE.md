# Working on Bee

This guide describes available development operations. In-app self-edit, Hub
installation and MCP tools are planned in [PACKAGE_BOUNDARIES.md](PACKAGE_BOUNDARIES.md);
there are no published Bee tools for those operations yet.

Read `README.md`, `docs/FOUNDATION_STATUS.md` and `docs/DEVELOPMENT.md` first.
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
exit with Ctrl+Q and run `./run.sh` again. Preferences and opt-in application
checkpoints persist in the workspace database. Settings opts in; Terminal does
not restore a dead PTY. See `APPLICATION_CONTRACTS.md` for the actual version-1
protocol; native process stacks are not portable checkpoints.

For future package work, preserve definition IDs independently of versions and
paths. Carry expected revisions, capability changes and rollback information in
activation requests. Document whether an update supports live rejoin, app
checkpoint/restore or a full restart. Do not describe planned operations as
already callable.

The local journal and Test Status app establish the first durable communication
slice; see [foundation next steps](FOUNDATION_NEXT.md). Agent drivers,
thread subscriptions, MCP and publication are not implemented yet. Do not route
new authority through the desktop merely because it is the visible client.
