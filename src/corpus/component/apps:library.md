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

Install on a shared version runs the local path in one move: it receives the
version, reads its checks, reviews, chooses it and prepares its activation,
which raises one approval in Needs you; the activation worker applies it once
the person approves, and the row follows it. Install and update of a Hub
package open the package screens: details, changes, confirmation and result.

The app calls two facades and nothing else. `bee.gov.binding:destination_call`
runs under `bee.gov.delivery.read`, `manage` and `activate`; the operations it
uses are `available`, `list`, `activations`, `stage`, `get`, `changes`,
`review`, `select`, `prepare`, `step`, `status` and `recover`. The public Hub
facade `bee.hub.binding:call` runs under `bee.hub.read`, `bee.hub.manage` and,
for the Bee deployment root, `bee.hub.self_update`. The approval decision
belongs to the approvals owner (`component/approvals`); the activation owner
applies the version (`component/gov`); package credentials, registry writes
and execution authority stay inside `component/hub`.

Singleton, listed in `bee.shell:system_menu`. The libraries are `model` (the
list model), `governed` (versions delivered to this node), `hub` (Hub
packages), `view`, `hub_view` (the package screens) and `contents` (the
read-only package browser).
