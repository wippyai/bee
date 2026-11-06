-- MIT. How the node owner brings apps forward for the person: an agent's
-- open request, a request waiting for a decision, which opens Needs you with
-- an alert, and an application the person approved, which opens once it is
-- installed. Each opens on the desktops a display shows for the workspace.
local logger = require("logger")
local protocol = require("protocol")
local workspaces = require("workspaces")
local client = require("client")
local arguments = require("arguments")
local bounds = require("bounds")
local waiting = require("waiting")
local part_catalog = require("part_catalog")
local part_handover = require("part_handover")
local node_state = require("node_state")
local apps = require("apps")
local M = {}
type State = node_state.State
local APPROVALS_ROLE = "approvals"

-- present opens app with arguments on every desktop a display shows that
-- works in workspace_id and asks those displays to bring it forward; it
-- returns what it opened and why an open failed.
local function present(state: State, workspace_id: string, app: string, arguments: {string}, pending: {count: integer, title: string, approval_id: string, failed: boolean?, installed: boolean?}?, request: string?): ({{[string]: unknown}}, string?)
    local presented: {{[string]: unknown}} = {}
    local problem: string? = nil
    local seen: {[string]: boolean} = {}
    for _, desktop_id in pairs(state.watchers) do
        if desktop_id ~= "" and not seen[desktop_id] then
            seen[desktop_id] = true
            local desktop = workspaces.desktop(desktop_id)
            if desktop and desktop.workspace_id == workspace_id then
                local opened = apps.open(state, app, desktop_id, {arguments = arguments}, true, request)
                local value = opened.value
                if opened.ok and value then
                    assert(type(value.id) == "string", "Presented app has no instance identity")
                    local alert: client.Alert? = pending and {id = value.id, count = pending.count, title = pending.title,
                        approval_id = pending.approval_id, failed = pending.failed, installed = pending.installed, app = app, desktop = desktop_id, workspace = workspace_id}
                    for id, previous in pairs(state.alerts) do
                        if previous.desktop == desktop_id and previous.app == app and id ~= value.id then state.alerts[id] = nil end
                    end
                    if alert then state.alerts[value.id] = alert end
                    node_state.broadcast(state, {kind = "attention", id = value.id, alert = alert})
                    presented[#presented + 1] = value
                else
                    logger:warn("App not presented", {app = app, desktop = desktop_id, error = opened.error})
                    problem = tostring(opened.error)
                end
            end
        end
    end
    return presented, problem
end

-- open_requested serves an agent's open request: what an earlier attempt
-- started, else app presented on the desktops shown for workspace_id.
function M.open_requested(state: State, workspace_id: unknown, app: unknown, given: unknown, request: unknown): protocol.Reply
    if type(workspace_id) ~= "string" or type(app) ~= "string" or type(request) ~= "string" then
        return protocol.fail("present needs a workspace, an app and a request")
    end
    local literal = arguments.decode(given)
    if not literal then return protocol.fail("present arguments must be literal strings") end
    local earlier: {{[string]: unknown}} = {}
    for _, instance in pairs(state.instances) do
        if instance.request == request and instance.workspace == workspace_id and instance.app == app then
            local value = part_handover.describe(instance)
            value.existing = true
            earlier[#earlier + 1] = value
        end
    end
    if #earlier > 0 then return protocol.ok({opened = earlier}) end
    local presented, problem = present(state, workspace_id, app, literal, nil, request)
    if #presented > 0 then return protocol.ok({opened = presented}) end
    return protocol.fail(problem or "no display shows a desktop of workspace " .. workspace_id)
end

-- A request waiting for the person opens Needs you; an application the
-- person approved opens once it is installed; a window asked to show a
-- session another window already shows brings that window forward.
function M.attend(state: State, event: {[string]: unknown})
    local data = event.data
    if type(event.path) ~= "string" or type(data) ~= "table" then return end
    local workspace_id: string = event.path
    if event.kind == "session.viewed" then
        local viewer = type(data.viewer) == "string" and state.by_pid[data.viewer] or nil
        if viewer then node_state.broadcast(state, {kind = "attention", id = viewer, focus = true}) end
        return
    end
    local request = bounds.object(data.request)
    if request and (event.kind == "approval.requested" or event.kind == "approval.changed") then
        local title = event.kind == "approval.requested" and tostring(data.title or "Review request") or nil
        for _, id in ipairs(waiting.mark(state.instances, workspace_id, request, title)) do
            node_state.broadcast(state, {kind = "review", id = id, review = state.instances[id].review or false})
        end
    end
    if event.kind == "approval.requested" or event.kind == "approval.failed" then
        local inbox, inbox_error = part_catalog.role_app(APPROVALS_ROLE, workspace_id)
        if inbox_error then
            logger:error("Approvals app not resolved", {error = inbox_error})
            return
        end
        local approval_id = type(data.approval_id) == "string" and data.approval_id or nil
        if not inbox then logger:warn("No installed app handles approvals")
        elseif approval_id then
            local count = type(data.count) == "number" and math.floor(data.count) or nil
            local title = type(data.title) == "string" and data.title or "Review request"
            present(state, workspace_id, inbox, {"--approval", approval_id}, count and {count = count, title = title, approval_id = approval_id, failed = data.failed == true} or nil)
        else present(state, workspace_id, inbox, {}) end
    elseif event.kind == "approval.changed" and type(data.count) == "number" then
        for id, alert in pairs(state.alerts) do
            local instance = state.instances[id]
            if not alert.installed and (alert.workspace == workspace_id or (instance and instance.workspace == workspace_id)) then
                alert.count = math.floor(data.count)
                alert.failed = false
                if type(data.approval_id) == "string" then alert.approval_id = data.approval_id end
                if type(data.title) == "string" then alert.title = data.title end
                node_state.broadcast(state, {kind = "attention", id = id, alert = alert, changed = true})
            end
        end
    elseif event.kind == "application.applied" and type(data.component) == "string" then
        node_state.refresh(state)
        apps.update_instances(state)
        local prefix = tostring(data.component) .. ":"
        -- A window already running an earlier revision of the application
        -- restarts in place on the applied one; the others are presented.
        local running: {[string]: boolean} = {}
        for _, instance in pairs(state.instances) do
            if instance.workspace == workspace_id and instance.app:sub(1, #prefix) == prefix then
                running[instance.app] = true
            end
        end
        for _, app in ipairs(state.installed_apps) do
            local id = app.id
            if type(id) == "string" and id:sub(1, #prefix) == prefix and not running[id] then
                local approval_id = type(data.approval_id) == "string" and data.approval_id or nil
                present(state, workspace_id, id, {}, approval_id and {count = 0, title = app.title .. " installed", approval_id = approval_id, installed = true} or nil)
            end
        end
    end
end

return M
