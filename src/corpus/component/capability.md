# Capability model

`bee.capability:catalog` is the host-owned review vocabulary: capability ids
(for example `workspace.files.read`) with revision, parameters, review text,
confirmation level, the policies and resources each grant renders to, and a
`never` list of capabilities no application or agent may request (`env`,
`credentials`, `registry.write`, `security.policy.write`,
`security.scope.manage`, `approvals.decide`, `core.database`,
`lifecycle.auto_start`). Declarations are not grants.

Two optional template fields tie a capability to what it enables:

- `modules` names the runtime modules a granted application may load. A module
  outside the application profile is admitted only together with an approved
  request for a capability that names it: `exec` with `process.exec`,
  `contract` with `contract.call` or `agents.launch`.
- `tools` names the gateway tools through which an agent attempt exercises the
  grant: `process_run` for `process.exec`, `http_request` for `http.api`.

## Process execution

`process.exec` (confirm `explicit`) takes two parameters:

| Parameter | Kind | Meaning |
|---|---|---|
| `command` | `command` | The executable, a clean absolute path or a bare name the host resolves on its PATH, followed by fixed leading arguments; single spaces, no quotes, escapes or shell characters, at most 16 tokens |
| `directory` | `relative_subpath` | The folder relative to the workspace, `.` for the workspace itself; never `.wippy` |

The person reads `Run {command}, followed by any further arguments, in
workspace folder {directory} with your user's full file and network access and
no environment beyond the host PATH`. The grant lets the holder run that
command alone or followed by further arguments; any other command, a chosen
working directory or caller environment is refused.

For an application, activation installs a host-created `exec.native` executor
(`bee.gov.grants:executor.<digest>`) fixed to the approved folder and the host
PATH (`bee.capability:exec_path`), and a `security.policy.expr` grant that
admits `exec.get` on that executor and `exec.run` only for the approved command
with no `work_dir` and no environment names. The application finds its executor
through `bee.gov.binding:granted_resources` under `executors[command][directory]`.

For an agent attempt, the approval itself is the grant: `process_run` runs the
command through `bee.gateway.env:process_executor` in the approved folder of
the bound workspace.

## Application database

`app.database` (parameter `name`) provisions one SQLite database for the
application under `bee.capability:app_database_root`, outside every readable
workspace tree. Its migrations name it as `meta.target_db = <name>`; the
application and its agent tools open it by the id
`bee.gov.binding:granted_resources` returns under `databases[<name>]`.

## Agent tools

`agent.tools` (confirm `explicit`) takes `tools` (kind `own_functions`): the
application's own tool function ids. The person reads `Let agents you enable
call {tools} as this application, with this application's grants`. Each id must
be a `function.lua` of the same pack whose meta decodes as a tool
(`bee.values:agent_tool`), with schemas in the advertised subset and no
`security` block; aliases must be distinct. Approval generates a
`security.policy` letting the application scope `funcs.call` exactly those
functions. The node offers them to agents through the gateway's `app_tools`.

The pure `bee.capability:model` library decodes the catalog (`decode`), normalizes
and resolves capability requests (`normalize`, `resolve`, `render`), compares
grant scopes (`scope_contains`, `contains`) and installed against proposed
declarations (`compare`), builds revocation reports (`revocation_report`), and
maps granted capabilities to the modules they admit (`modules`,
`module_capabilities`). Gateway, Gov and their stores import it and keep their
own grant records.

Catalog meanings do not grant authority. Each owner checks and records grants
under its host-selected permissions.
