# App capability catalog

App permissions: an app asks for host access by listing capabilities on its own application entry. Generated from the host catalog, revision 6. A listed capability requests review; it grants nothing until the person approves it.

Use docs search with topic capabilities and a task phrase, or ask `what can an app request to read workspace files`. Read the matching section here for the exact parameters and grants.

## Request shape

List what the app needs in `meta.application.capabilities` of its `process.lua` entry with `meta.type: bee.application`. Each item is `{capability, parameters, reason}`: `capability` is an exact ID below, `parameters` matches its parameter kinds (omit it for a capability that takes none), and `reason` is one line saying why the app needs it. The host generates the policies and attaches them to the application; do not write targets, paths or policies, and do not author an actor.

For example, a database for my app and read access to one workspace folder:

```yaml
- name: app
  kind: process.lua
  meta:
    type: bee.application
    application:
      api_version: 1
      lifetime: view
      title: Notes
      revision: '1'
      instance_policy: singleton
      menus: [bee.shell:apps_menu]
      capabilities:
      - capability: app.database
        parameters: {name: notes}
        reason: Keep the notes you write
      - capability: workspace.files.read
        parameters: {subpath: docs}
        reason: Show the documents in your docs folder
```

## How the person approves

Delivering or installing the app files one approval in Needs you. It shows each listed capability in plain words, the catalog text below with your parameters filled in, together with the app's version and pending migrations. Approving installs the generated policies, databases, folders and executors with the app in one step; denying installs nothing. A later version's approval lists what it adds, widens, narrows or removes. Uninstalling removes the grants and keeps the app's databases.

Risk class uses the catalog's confirmation class: standard means ordinary approval; explicit means deliberate confirmation for broader effects. Scope and the grant text describe the actual authority.

## Errors and fixes

Install preflight names the exact field and the value it expects. `<app>` stands for the application entry ID.

- `<app> has meta.application but meta.type bee.app; an application declares meta.type bee.application`: the application entry carries another meta.type; set `meta.type: bee.application`.
- `workspace artifact declares no application; declare one process.lua entry with meta.type bee.application and meta.application`: add the application's process.lua entry.
- `<app> meta.application.capabilities must be a list of at most 8 {capability, parameters, reason} objects`: write `capabilities` as a YAML list with at most eight items.
- `<app> meta.application.capabilities[1]: unknown field target; it takes capability, parameters and reason`: remove every other field; the host decides where the generated policy goes.
- `<app> meta.application.capabilities[1].capability: files.read is not a host capability; expected one of ...`: use an exact capability ID from this page.
- `<app> meta.application.capabilities[1].reason must be one line of 1 to 512 characters saying why the app needs app.database`: add a one-line `reason`.
- `<app> meta.application.capabilities[1].parameters.subpath must be a relative workspace path such as data/notes, or . for the whole workspace`: give the parameter in the form named after `must be`.
- `<app> meta.application.capabilities[1].parameters.depth is not a parameter of workspace.files.read; it takes subpath`: remove the parameter or use one the message lists.
- `<app> meta.application.capabilities[1].parameters.tools: app.notes:search is not a function.lua tool in package app.notes`: list only the package's own tool functions.
- `<app> meta.application.capabilities[1].parameters.definitions: acme:worker is not a registry.entry with meta.type bee.launch_definition`: name launch definitions only.
- `<app> meta.application.capabilities[1].parameters.operations: app.notes:run is not a function.lua in package app.notes with meta.hive open`: expose only the package's own functions whose `meta.hive` equals the requested mode.
- `<app> meta.application.capabilities[2] repeats <app> meta.application.capabilities[1]`: list each capability and parameter set once.
- `app.notes:database: an ns.requirement has no meta.capability; list {capability, parameters, reason} in the application's meta.application.capabilities`: move the request onto the application; keep `ns.requirement` for configuration and dependency bindings.
- `installed capability grant record of <app> binds ns.requirement entries this host no longer reads; uninstall the application and install it again`: the installed version used requirement entries for its capabilities; uninstall it in Library, then install the new version.
- `stored candidate requests capabilities through ns.requirement entries, which this host no longer reads; install the application again so the person reviews its meta.application.capabilities`: the node left that installed version out at startup and reported it; uninstall it in Library and install a version that lists its capabilities on the application.
- Preflight `APPLICATION_DESCRIPTOR`: `the desktop cannot open this application: meta.application.lifetime must be view`: fix the named `meta.application` field and freeze a new version.
- Preflight `MODULE_DENIED` naming `request capability process.exec ...`: list the named capability in `meta.application.capabilities`, or remove the module.

## Registry access and installed components

No app capability grants registry access. Read installed components through the agent's components tool with operation installed, under its host-selected bee.hub.read policy. hub.manage grants an app Hub reads and changes; there is no read-only app capability. Calling an owner also needs its permitted call path; a capability never admits arbitrary funcs calls.

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
