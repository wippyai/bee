# bee.apps.library

`bee.apps.library:app` (Library) is the one place for every application and
driver a person can install. Three sources fold into one list per tab:

- versions this bee's agents made, delivered to this node through governance;
- versions other bees of the hive shared, replicated through the Sync feed
  `governance.application_versions`;
- Hub packages.

Hub inspection distinguishes host capability requests from missing dependency
parameters. Admitted Hub applications use the application's test runner by
registry association, including tests outside the application's namespace.
Hub application packages enter governed staging, preflight, review, selection
and activation. One approval covers the application, its pending migrations and
its capabilities. Application databases, agent tools, tests and menus use the
same host provisioning and admission as overlay deliveries. Library packages
and `bee/bee` self-update use the Hub dependency-root publisher; see
[Hub installation](../docs/hub_inspection.md).

The tabs are Installed (what runs here, with Update available when a newer
version is shared or on the Hub), Shared (what could be installed, from a bee
or from the Hub) and History (past installs and removals, with the recovery
action of an interrupted Hub change). Installed lists what the person uses (applications and drivers by the title
they declare, Hub packages the person installed) and Bee's platform as one row
("Bee 0.2.0-dev, built in, 6 packages", Enter lists them); packages other
installed things need are never offered for removal. Shared lists what the
hive made first and keeps the Hub catalog behind one collapsed row, because Hub
metadata does not say which uninstalled packages Bee can run as applications.
Rows carry the glyphs of `bee.ui:glyphs`. A row carries one status: Shared, Waiting
for your approval, Installing, Installed, Update available or Removed, and one
source: made on this bee, from bee `<node>` or from Hub. Words of the
machinery (overlay, staged, plan, preflight, activation, destination,
artifact, digest, descriptor, receipt) appear only in the details view (T).

A version names the agent that made it when its session says so: publication
reads the caller's session through the public Sessions contract and puts the
title of the definition it runs (for example Claude Code) in the version and its
manifest; the first author of a version stays. A row then reads `made by Claude
Code`; a version from another bee reads `from bee <name>`, where the name is
what that bee's node reports for itself, read through `bee.node.binding:names`
under the one action `bee.node.names.read` the Library holds. A bee that gives
no name shows the start of its identity.

An installed application opens from its row: the destination returns the
`bee.app` definition each applied activation declares and the Library asks its
own broker to open it through `bee.app:client`. Both removals ask first and name
what goes and what stays. Remove runs the destination's `uninstall`: the
application, its permissions and its menu entry are taken off this bee, its
databases and their data are kept and nothing is deleted, and installing it again
finds it as it was. Go back, offered when an earlier version exists, runs
`revert`: the application goes back to the version before it, applied migrations
stay where they are, and going back past a later version's database change stops
and says so. The removed version is listed in History as Removed.

Install on a shared version runs the local path in one move: it receives the
version, reads its checks, reviews, chooses it and prepares its activation,
which raises one approval in Needs you; the activation worker applies it once
the person approves, and the row follows it. An install whose approval expired,
was withdrawn or was denied leaves Installed: its version is back in Shared,
noted "Approval expired — install again" or "Denied", and History keeps the
attempt; Install asks the person anew. The header counts only installed
versions, not installs waiting or on their way. Install and update of a Hub
library package open the package screens: details, changes, confirmation and
result. Hub application plans enter the governed install flow and wait in Needs
you for one approval.

The app calls two facades and nothing else. `bee.gov.binding:destination_call`
runs under `bee.gov.delivery.read`, `manage` and `activate`; the operations it
uses are `available`, `list`, `activations`, `stage`, `stage_hub`, `get`, `changes`,
`review`, `select`, `prepare`, `step`, `status`, `recover`, `revert` and `uninstall`. The public Hub
facade `bee.hub.binding:call` runs under `bee.hub.read`, `bee.hub.manage` and,
for the Bee deployment root, `bee.hub.self_update`. The approval decision
belongs to the approvals owner (`component/approvals`); the activation owner
applies the version (`component/gov`); package credentials, registry writes
and execution authority stay inside `component/hub`.

Singleton, listed in `bee.shell:system_menu`. The libraries are `model` (the
list model), `governed` (versions delivered to this node), `hub` (Hub
packages), `view`, `hub_view` (the package screens) and `contents` (the
read-only package browser).
