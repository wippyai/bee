-- MIT. Launch an application execution into a new or retained viewport.
local process = require("process")
local registry = require("registry")
local tty = require("tty")
local uuid = require("uuid")
local appearance = require("appearance")
local application = require("application")
local workspaces = require("workspaces")
local funcs = require("funcs")
local bounds = require("bounds")
local canonical = require("canonical")
local handover = require("handover")
local M = {}
type Instance = handover.Instance
type AppAlias = handover.AppAlias
local words = handover.words

function M.start(id: string, app: string, desktop_id: string, app_args: {[string]: unknown}, workspace_id: string?, retained: Instance?, current: appearance.Preferences, attest: (string, string, string) -> (AppAlias?, string?), retire: (AppAlias) -> ()): (Instance?, string?)
    local definition, problem = application.definition(app)
    if not definition then return nil, problem end
    local entry, entry_error = registry.get(app)
    if not entry then return nil, tostring(entry_error) end
    local digest, digest_error = canonical.digest(entry)
    if not digest then return nil, digest_error end
    local desktop, desktop_error = workspaces.desktop(desktop_id)
    if not desktop then return nil, desktop_error end
    local workspace, workspace_error = workspaces.workspace(workspace_id or desktop.workspace_id)
    if not workspace then return nil, workspace_error end
    local view, view_error = retained and retained.view or nil, nil
    if not view then
        view, view_error = tty.viewport({width = 80, height = 24,
            page = appearance.page(current.theme, definition.terminal)})
    end
    if not view then return nil, "viewport: " .. tostring(view_error) end
    local function abandon() if not retained then view:close() end end
    local grant = assert(view:grant())
    local actor, actor_error = application.actor(workspace.id, id, definition, 1)
    if not actor then
        abandon()
        return nil, actor_error
    end
    local scope, scope_problem = application.scope(definition, workspace.id)
    if not scope then
        abandon()
        return nil, scope_problem
    end
    local alias, alias_error = attest(definition.process, workspace.id, actor:id())
    if not alias then
        abandon()
        return nil, alias_error
    end
    local owner_pid = tostring(process.pid())
    local version = assert(registry.current_version())
    local token = tostring(uuid.v7())
    local execution_id = tostring(uuid.v7())
    local options: {[string]: unknown} = {appearance = current, owner = owner_pid, args = app_args, desktop = desktop.id,
        workspace = {id = workspace.id, path = workspace.path, label = workspace.label},
        version = 1, broker_pid = owner_pid, workspace_pid = owner_pid, workspace_id = workspace.id, instance_id = id, view_id = id,
        definition_id = definition.process, execution_generation = 1, execution_id = execution_id, definition_revision = definition.revision,
        registry_revision = version:string(), launch_token = token, resume_schema = definition.resume_schema,
        resume_state = type(app_args.resume_state) == "string" and app_args.resume_state or "", arguments = words(app_args)}
    -- The host context names the workspace; the functions an app calls
    -- authorize workspace-bound operations by it, never by the request.
    local launched, call_error = funcs.new():with_actor(actor):call("bee.node.service:launch", {terminal = grant, options = options})
    local launch_result = bounds.object(launched)
    local pid = launch_result and bounds.id(launch_result.pid)
    local spawn_error = call_error or (launch_result and launch_result.error)
    if not pid then
        retire(alias)
        abandon()
        return nil, "start " .. app .. ": " .. tostring(spawn_error)
    end
    local monitored, monitor_error = process.monitor(pid)
    local linked, link_error = false, nil
    if monitored then linked, link_error = process.link(pid) end
    if not monitored or not linked then
        process.cancel(pid)
        if monitored then process.unmonitor(pid) end
        retire(alias)
        abandon()
        return nil, "attach application ownership: " .. tostring(monitor_error or link_error)
    end
    local instance: Instance = {id = id, app = app, title = definition.title, desktop = desktop.id, workspace = workspace.id,
        view = view, pid = tostring(pid),
        terminal = definition.terminal, execution_id = execution_id, token = token, negotiate = false, closing = nil, dialog = nil, args = app_args,
        resume_schema = definition.resume_schema, singleton = definition.singleton, revision = definition.revision,
        definition = digest, update_target = retained and digest or nil, alias = alias,
        request = retained and retained.request or nil}
    return instance, nil
end

return M
