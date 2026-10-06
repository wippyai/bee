# bee.node

The node owner. It keeps the node's workspaces, desktops, app instances and
settings in the node database `bee:db`, runs apps as processes on the
`bee:workers` host, and serves the displays that watch it. A node runs per
folder; `bee node` runs it without a display and `bee client` displays a
running node.

| Entry | Responsibility |
|---|---|
| `bee.node.service:owner` | The owner process, registered as `bee.node`. It opens and closes app instances, mounts their viewports for watching displays, answers the app broker messages, tracks the installed apps and themes from registry changes and restores the desktops' instances at start |
| `bee.node:workspaces` | Workspaces (a folder on the machine; the folder the node runs in is always one), desktops (one set per node, each working in one workspace) and the app instances each desktop runs |
| `bee.node:settings` | Named string values stored together or not at all |
| `bee.node:broker` | The `bee.app.*` messages an app sends the owner: ready, title, close reply, query, checkpoint, request. The owner accepts each only from the app's process carrying its launch token |
| `bee.node:command` | Resolves `bee NAME` to an installed app |
| `bee.node:client` | The display side of the owner protocol |
| `bee.node:principal` | Reads the node identity |
| `bee.node:headless` | The `node` command |

## Commands

`bee NAME` opens the app that NAME resolves to. An app lists commands in
`meta.application.commands` (`name`, `arguments`, `fullscreen`), and a
`registry.entry` of `meta.type: bee.app_command` with `data.name`,
`data.definition_id`, `data.arguments`, `data.fullscreen` names an installed
app with the arguments it opens with. Names match `^[a-z][a-z0-9_-]*$`; `run`,
`runtime`, `update`, `client` and `node` are reserved. Two apps claiming one
name make it ambiguous.

## Owner protocol

Requests reach the owner as `bee.hive:protocol` operations on the route
`node` (`registry.entry`, `meta.type: bee.hive.route`, `data.prefix: node`,
`data.name: bee.node`): `list`, `watch`, `show`, `leave`, `open`, `attach`,
`close`, `answer`, `command`, `stats`, `move`, `themes`, `appearance`,
`workspaces`, `desktop_workspace`, `workspace_add`, `workspace_remove`,
`desktop_create`, `desktop_rename`, `desktop_close`.

## Workspace catalog

`bee.node.binding:read`, `:roots` and `:folders` are the functions apps call
for workspace rows. They decode the request, check the caller's
`bee.node.workspace.read` (or `bee.node.workspace.browse` for folders) permission,
then run the private `bee.node.binding:catalog` under the catalog scope.
Apps never hold the node database; the application boundary denies it.

The admitted roots are the `registry.entry` of `meta.type: bee.node.roots`
(`data.roots`: `root_ref`, `access` read or write); `bee.node:machine` is
the filesystem root. `bee.ui.picker:folder` is the picker model over these
operations.

## Application admission

A `registry.entry` of `meta.type: bee.node.application_admission` lists
`data.bindings` for the node's own apps (`definition_id`, `policies`,
`scope_management`, `close_grace_ms`). Other apps are admitted through
governance (`bee.gov.binding:application_admissions`). Security groups
`application` and `scope_managing_application` carry the boundary every app
runs under: it may message processes, but may not select security for other
processes, change the registry, or start the node's own services.

Migrations in `bee.node.migrations` create `bee_node_workspaces`,
`bee_node_settings`, `bee_node_desktops`, identities and instance workspace
columns.
