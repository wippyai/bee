# App capability catalog

Generated from the host catalog, revision 6. Declarations request review; they do not grant access.

Use docs search with topic capabilities and a task phrase, or ask `what can an app request to read workspace files`. Read the matching section here for the exact parameters and grants.

Risk class uses the catalog's confirmation class: standard means ordinary approval; explicit means deliberate confirmation for broader effects. Scope and the grant text describe the actual authority.

## Registry access and installed components

No app capability grants registry access. Read installed components through the agent's components tool with operation installed, under its host-selected bee.hub.read policy. hub.manage grants an app Hub reads and changes; there is no read-only app capability. Calling an owner also needs its permitted call path; a capability never admits arbitrary funcs calls.

## Request shape

Declare an ns.requirement with meta.value_kind security.policy, meta.capability set to the exact ID below, meta.parameters matching its parameter kinds, and a one-line meta.reason. Its only target appends to the app definition's .security.policies. The host generates the policy; do not refer to a private host policy or author your own actor.

## workspace.files.read

workspace.files.read: Read workspace files under {subpath}. Risk class: standard. Template revision: 1.

Parameters: subpath: relative_subpath.
Runtime modules admitted by this capability: none.
Agent tools for an approved attempt: none.

Grants:

- files.read on workspace, scope {"subpath": "$subpath"}
- fs.directory resource, mode readonly, selected by verified_workspace_subroot

## workspace.files.write

workspace.files.write: Write workspace files under {subpath}. Risk class: explicit. Template revision: 1.

Parameters: subpath: relative_subpath.
Runtime modules admitted by this capability: none.
Agent tools for an approved attempt: none.

Grants:

- files.write on workspace, scope {"subpath": "$subpath"}
- fs.directory resource, mode readwrite, selected by verified_workspace_subroot

## app.database

app.database: Use an isolated application database named {name}. Risk class: standard. Template revision: 1.

Parameters: name: name.
Runtime modules admitted by this capability: none.
Agent tools for an approved attempt: none.

Grants:

- database.use on $name, scope {"name": "$name"}
- db.sql.sqlite resource, mode dedicated, selected by host_app_database

## threads.read

threads.read: Read owned threads. Risk class: standard. Template revision: 1.

Parameters: scope: owned_scope.
Runtime modules admitted by this capability: none.
Agent tools for an approved attempt: none.

Grants:

- threads.read on threads, scope {"scope": "$scope"}

## threads.message

threads.message: Message child threads. Risk class: standard. Template revision: 1.

Parameters: scope: children_scope.
Runtime modules admitted by this capability: none.
Agent tools for an approved attempt: none.

Grants:

- threads.message on threads, scope {"scope": "$scope"}

## agents.launch

agents.launch: Launch managed agents from {definitions}. Risk class: explicit. Template revision: 1.

Parameters: definitions: definitions.
Runtime modules admitted by this capability: contract.
Agent tools for an approved attempt: none.

Grants:

- agents.launch on managed_agents, scope {"definitions": "$definitions"}

## contract.call

contract.call: Call app binding {binding} using {methods}. Risk class: explicit. Template revision: 1.

Parameters: binding: binding, methods: methods.
Runtime modules admitted by this capability: contract.
Agent tools for an approved attempt: none.

Grants:

- contract.call on $binding, scope {"methods": "$methods"}
- contract.binding resource, mode caller, selected by host_selected_binding

## http.api

http.api: Send HTTP requests to {origin} at {path_prefix} using {methods}. Risk class: explicit. Template revision: 1.

Parameters: origin: https_origin, methods: http_methods, path_prefix: url_path_prefix.
Runtime modules admitted by this capability: none.
Agent tools for an approved attempt: http_request.

Grants:

- http.request on $origin, scope {"methods": "$methods", "path_prefix": "$path_prefix"}
- http.client resource, mode scoped, selected by host_selected_origin

## process.exec

process.exec: Run {command}, followed by any further arguments, in workspace folder {directory} with your user's full file and network access and no environment beyond the host PATH. Risk class: explicit. Template revision: 1.

Parameters: command: command, directory: relative_subpath.
Runtime modules admitted by this capability: exec.
Agent tools for an approved attempt: process_run.

Grants:

- process.exec on $command, scope {"subpath": "$directory"}
- exec.native resource, mode scoped, selected by host_generated_executor

## agent.tools

agent.tools: Let agents you enable call {tools} as this application, with this application's grants. Risk class: explicit. Template revision: 1.

Parameters: tools: own_functions.
Runtime modules admitted by this capability: none.
Agent tools for an approved attempt: none.

Grants:

- agent.tools on application, scope {"tools": "$tools"}

## hive.call

hive.call: Call applications {applications} in workspaces {workspaces} on Hive nodes {nodes}, services {services}, operations {operations}. Risk class: explicit. Template revision: 1.

Parameters: nodes: hive_nodes, workspaces: hive_targets, applications: hive_targets, services: hive_names, operations: hive_names.
Runtime modules admitted by this capability: funcs.
Agent tools for an approved attempt: none.

Grants:

- hive.call on applications, scope {"applications": "$applications", "nodes": "$nodes", "operations": "$operations", "services": "$services", "workspaces": "$workspaces"}

## hive.expose

hive.expose: Expose Hive operations {operations} in {mode} mode to {audiences}. Risk class: explicit. Template revision: 2.

Parameters: operations: hive_operations, mode: hive_mode, audiences: hive_audiences.
Runtime modules admitted by this capability: none.
Agent tools for an approved attempt: none.

Grants:

- hive.expose on $mode, scope {"audiences": "$audiences", "operations": "$operations"}
- hive.operations resource, mode exposed, selected by host_selected_operations

## hive.view

hive.view: View Hive cluster membership. Risk class: standard. Template revision: 1.

Parameters: none.
Runtime modules admitted by this capability: none.
Agent tools for an approved attempt: none.

Grants:

- hive.view on cluster, scope {}

## desktop.application_stop

desktop.application_stop: Stop running applications from the process view. Risk class: explicit. Template revision: 1.

Parameters: none.
Runtime modules admitted by this capability: none.
Agent tools for an approved attempt: none.

Grants:

- desktop.application_stop on applications, scope {}

## hub.manage

hub.manage: Plan and apply Hub component changes. Risk class: explicit. Template revision: 1.

Parameters: none.
Runtime modules admitted by this capability: none.
Agent tools for an approved attempt: none.

Grants:

- hub.manage on components, scope {}

## hub.self_update

hub.self_update: Update Bee's live deployment root. Risk class: explicit. Template revision: 1.

Host-only: only the person-operated Library receives this grant; an authored app cannot request Bee self-update.

Parameters: none.
Runtime modules admitted by this capability: none.
Agent tools for an approved attempt: none.

Grants:

- hub.self_update on bee/bee, scope {}

## gov.delivery.manage

gov.delivery.manage: Prepare and publish governed delivery versions. Risk class: explicit. Template revision: 1.

Parameters: none.
Runtime modules admitted by this capability: none.
Agent tools for an approved attempt: none.

Grants:

- gov.delivery.manage on overlays, scope {}

## gov.delivery.activate

gov.delivery.activate: Activate accepted governed delivery versions. Risk class: explicit. Template revision: 1.

Parameters: none.
Runtime modules admitted by this capability: none.
Agent tools for an approved attempt: none.

Grants:

- gov.delivery.activate on overlays, scope {}

## Unavailable authority

No app capability grants: env, credentials, registry.write, security.policy.write, security.scope.manage, approvals.decide, core.database, lifecycle.auto_start. Use an isolated app database instead of Bee's core database; let the host select identity and policies; let the person decide approvals; run a view app when the person opens it instead of auto-starting a service.
