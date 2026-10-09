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
| `bee.node:application` | An app's definition, its admission, the actor an instance runs as and the scope that actor runs in; the owner starts apps with it and the test runner runs their tests with it |
| `bee.node.service:tests` | The test runner, registered as `bee.node.tests`; runs the application tests recorded in `bee_node_test_runs` and writes their results there |
| `bee.node.binding:tests_call` | The facade the `tests` MCP tool calls |
| `bee.node.binding:tests_backend` | Plans and records runs and reads results, in the private test backend scope |
| `bee.node:test_runs` | The run table's access |
| `bee.node:tests` | The tests request, its bounds and its reply envelope |
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

## Application tests

An application's pack may carry `function.lua` entries with `meta.type: test`,
optional `meta.suite` and `meta.timeout` (default `30s`), written with
`wippy.test:test`. The `tests` MCP tool accepts `list`, `run` and `status`.
Name an admitted application by its definition ID; an owned overlay name
remains accepted for overlay deliveries.

Discovery follows the installed application's registry ownership or admitted
overlay membership, across namespaces. A package with one application owns
its unqualified tests. A package with multiple applications associates each
test through `meta.application: <definition_id>`. An association cannot reach
another package or overlay. Host admissions associate tests explicitly through
`data.tests[definition_id]`, a list of registry IDs. Admitted applications delivered from Hub use the same
runner as overlay applications.

The facade takes the authenticated caller's workspace and actor and supplies
overlay ownership evidence to `bee.node.binding:tests_backend` under its private
scope. The backend verifies workspace admission and, for overlay delivery,
caller ownership before planning. It plans the tests, writes the run (workspace, actor, application, plan) as a row of
`bee_node_test_runs` and demand-wakes the runner. A message to the runner
is only a hint that a row waits: the runner reads the request from the row, trusts
no message field, and a forged message starts nothing.

A run starts at once and returns `run_id`; the runner executes the entries one
after another, each as the application: the actor and the exact scope
`bee.node:application` gives the app's own instances (the application boundary
plus its admission's policies), never the runner's authority. Each test is
awaited as the framework's runner awaits it: its case events arrive on a topic of
the run, and its own `meta.timeout` bounds it. The runner writes progress and the
final results to the row; `status` reads them from the database, so it needs no
runner round trip and survives a runner restart (a run the node stopped under is
reported `interrupted`). A run keeps at most 64 tests, 512 cases and 2048 bytes
per error text and reports what it dropped; 16 runs are retained, at most 4 run at
once, and a run is readable only by the actor that started it.

Migrations in `bee.node.migrations` create `bee_node_workspaces`,
`bee_node_settings`, `bee_node_desktops`, identities and instance workspace
columns.

## Application tools for agents

`bee.node:app_tools` discovers the tools a workspace's applications offer
agents: the definitions admitted in the workspace (host admissions, governed
overlays and packages), each application's live grant record holding
`agent.tools`, and each named tool entry decoded as an application tool.
Discovery reads registry metadata and grants, never namespaces; two
applications offering one alias offer neither (`ALIAS_COLLISION`).
`bee.node.binding:app_tools` lists them for the authenticated caller's
workspace, and `bee.node.binding:app_tool_call {tool, arguments}` re-reads
discovery and runs the tool as the application: actor
`bee.application:<workspace>:agent-<binding>` and the exact scope the
application's own instances run in, so the tool reaches the same granted
state the application's UI shows the person.

The test runner starts through supervised demand after a run commits. Boot
recovery finds pending or running rows; a new runner interrupts earlier running
rows once and executes pending rows. It requests quiet stop after every
execution coroutine finishes and the final results are durable. An enqueue
during quiet stop advances the demand generation and restarts the runner.
The Node owner waits for the registered boot gates before building its catalog.
Node and the runner depend on resident Hive, so restarting Node or starting
another run does not rerun the bootloader or governance recovery.
