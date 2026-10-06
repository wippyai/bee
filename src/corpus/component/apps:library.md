# bee.apps.library

`bee.apps.library:app` (Library) is the one place for every application and
driver a person can install. Three sources fold into one list per tab:

- versions this bee's agents made, delivered to this node through governance;
- versions other bees of the hive shared, replicated through the Sync feed
  `governance.application_versions`;
- Hub packages.

The tabs are Installed (what runs here, with Update available when a newer
version is shared or on the Hub), Shared (what could be installed, from a bee
or from the Hub) and History (past installs and removals, with the recovery
action of an interrupted Hub change). A row carries one status: Shared, Waiting
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
the person approves, and the row follows it. Install and update of a Hub
package open the package screens: details, changes, confirmation and result.

The app calls two facades and nothing else. `bee.gov.binding:destination_call`
runs under `bee.gov.delivery.read`, `manage` and `activate`; the operations it
uses are `available`, `list`, `activations`, `stage`, `get`, `changes`,
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
