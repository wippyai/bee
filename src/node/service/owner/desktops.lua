-- MIT. What displays ask the node owner about desktops and workspaces:
-- watching the node on a desktop of their own, switching desktops, adding and
-- removing workspaces, and creating, retargeting, renaming and, once the
-- person confirms, closing desktops. Each edit is validated and stored, and
-- the watching displays are told.
local process = require("process")
local workspaces = require("workspaces")
local protocol = require("protocol")
local confirmation = require("confirmation")
local seam = require("seam")
local node_state = require("node_state")
local apps = require("apps")
local M = {}
type State = node_state.State

-- node_desktops returns the node's desktops, creating the first, working
-- in the folder the node runs in, when it has none.
function M.node_desktops(state: State): ({workspaces.Desktop}?, string?)
    local desktops, err = workspaces.desktops()
    if not desktops then return nil, err end
    if #desktops > 0 then return desktops, nil end
    local created, create_error = workspaces.create_desktop(state.home_id, nil)
    if not created then return nil, create_error end
    return {created}, nil
end

-- free_desktop returns a desktop no display shows, creating one when every
-- desktop is shown, so each new display starts on its own desktop.
local function free_desktop(state: State): (string?, string?)
    local desktops, err = M.node_desktops(state)
    if not desktops then return nil, err end
    local shown: {[string]: boolean} = {}
    for _, desktop in pairs(state.watchers) do shown[desktop] = true end
    for _, desktop in ipairs(desktops) do
        if not shown[desktop.id] then return desktop.id, nil end
    end
    local created, create_error = workspaces.create_desktop(state.home_id, nil)
    if not created then return nil, create_error end
    return created.id, nil
end

-- watch starts sending node events to caller and chooses the desktop it
-- shows: the one it asks for unless another display shows that, else a
-- free one.
function M.watch(state: State, caller: string, desktop: unknown): protocol.Reply
    local chosen: string? = nil
    if type(desktop) == "string" and workspaces.desktop(desktop) and not node_state.shown_elsewhere(state, desktop, caller) then
        chosen = desktop
    end
    if not chosen then
        local free, err = free_desktop(state)
        if not free then return protocol.fail("choose desktop: " .. tostring(err)) end
        chosen = free
    end
    if not state.watchers[caller] then
        local monitored, monitor_error = process.monitor(caller)
        if not monitored then return protocol.fail("watch: " .. tostring(monitor_error)) end
    end
    state.watchers[caller] = chosen or ""
    node_state.announce_workspaces(state)
    local value = node_state.snapshot(state, caller)
    value.desktop = chosen
    seam.hold("bee.node.service.desktop_chosen")
    return protocol.ok(value)
end

-- leave forgets a display that stops watching this node.
function M.leave(state: State, caller: string): protocol.Reply
    if state.watchers[caller] then
        state.watchers[caller] = nil
        process.unmonitor(caller)
        node_state.announce_workspaces(state)
    end
    return protocol.ok({})
end

function M.show(state: State, caller: string, desktop: unknown): protocol.Reply
    if not state.watchers[caller] then return protocol.fail("show needs a watching display") end
    if type(desktop) ~= "string" or not workspaces.desktop(desktop) then return protocol.fail("no such desktop") end
    if node_state.shown_elsewhere(state, desktop, caller) then return protocol.fail("that desktop is shown on another display") end
    state.watchers[caller] = desktop
    node_state.broadcast(state, {kind = "catalog"})
    node_state.announce_workspaces(state)
    return protocol.ok({desktop = desktop})
end

function M.add_workspace(state: State, path: unknown, label: unknown): protocol.Reply
    if type(path) ~= "string" or not workspaces.absolute(path) then return protocol.fail("a workspace needs an absolute path") end
    local name: string? = nil
    if type(label) == "string" and label ~= "" then name = label end
    local workspace, err = workspaces.ensure(path, name)
    if not workspace then return protocol.fail(err or "workspace not added") end
    node_state.announce_workspaces(state)
    return protocol.ok({workspace = workspace.id})
end

-- remove_workspace forgets a workspace no desktop works in; the folder the
-- node runs in stays.
function M.remove_workspace(state: State, id: unknown): protocol.Reply
    if type(id) ~= "string" or not workspaces.workspace(id) then return protocol.fail("no such workspace") end
    if id == state.home_id then return protocol.fail("the node's own folder stays a workspace") end
    for _, desktop in ipairs(workspaces.desktops() or {}) do
        if desktop.workspace_id == id then return protocol.fail(desktop.title .. " works in that workspace") end
    end
    local removed, err = workspaces.remove_workspace(id)
    if not removed then return protocol.fail(err or "workspace not removed") end
    node_state.announce_workspaces(state)
    return protocol.ok({workspace = id})
end

-- create_desktop adds a desktop working in workspace_id, or in the folder
-- the node runs in.
function M.create(state: State, workspace_id: unknown, title: unknown): protocol.Reply
    local folder = state.home_id
    if workspace_id ~= nil then
        if type(workspace_id) ~= "string" or not workspaces.workspace(workspace_id) then return protocol.fail("no such workspace") end
        folder = workspace_id
    end
    local name: string? = nil
    if type(title) == "string" and title ~= "" then name = title end
    local desktop, err = workspaces.create_desktop(folder, name)
    if not desktop then return protocol.fail(err or "desktop not added") end
    node_state.announce_workspaces(state)
    return protocol.ok({desktop = desktop.id, title = desktop.title})
end

-- use_workspace makes desktop id work in workspace_id; apps opened on it
-- from then on start there.
function M.use_workspace(state: State, id: unknown, workspace_id: unknown): protocol.Reply
    if type(id) ~= "string" or not workspaces.desktop(id) then return protocol.fail("no such desktop") end
    if type(workspace_id) ~= "string" or not workspaces.workspace(workspace_id) then return protocol.fail("no such workspace") end
    local used, err = workspaces.use_workspace(id, workspace_id)
    if not used then return protocol.fail(err or "workspace not used") end
    node_state.broadcast(state, {kind = "catalog"})
    node_state.announce_workspaces(state)
    return protocol.ok({desktop = id, workspace = workspace_id})
end

function M.rename(state: State, id: unknown, title: unknown): protocol.Reply
    if type(id) ~= "string" or not workspaces.desktop(id) then return protocol.fail("no such desktop") end
    if type(title) ~= "string" or title == "" then return protocol.fail("a desktop needs a title") end
    local renamed, err = workspaces.rename_desktop(id, title)
    if not renamed then return protocol.fail(err or "desktop not renamed") end
    node_state.announce_workspaces(state)
    return protocol.ok({desktop = id, title = title})
end

-- desktop_target is what closing desktop id stops: its workspace, title and
-- the app executions running on it.
local function desktop_target(state: State, id: string): {[string]: unknown}?
    local desktop = workspaces.desktop(id)
    if not desktop then return nil end
    local apps: {{[string]: unknown}} = {}
    for _, instance in pairs(state.instances) do
        if instance.desktop == id then apps[#apps + 1] = {instance_id = instance.id, execution_id = instance.execution_id, definition_id = instance.app, revision = instance.revision} end
    end
    table.sort(apps, function(a, b) return tostring(a.instance_id) < tostring(b.instance_id) end)
    return {desktop_id = id, workspace_id = desktop.workspace_id, title = desktop.title, apps = apps}
end

-- confirmation opens the person's confirmation that closing a desktop
-- needs, or withdraws it.
function M.confirmation(state: State, args: {[string]: unknown}): protocol.Reply
    local id = args.id
    if type(id) ~= "string" then return protocol.fail("confirmation needs a desktop") end
    if args.operation == "cancel" then
        local review = type(args.approval_id) == "string" and state.desktop_reviews[args.approval_id] or nil
        if not review then return protocol.fail("no such desktop confirmation") end
        local canceled, err = confirmation.cancel(review)
        if not canceled then return protocol.fail(err or "withdrawal failed") end
        state.desktop_reviews[tostring(args.approval_id)] = nil
        return protocol.ok({})
    end
    local target = desktop_target(state, id)
    local desktop = workspaces.desktop(id)
    if not target or not desktop then return protocol.fail("no such desktop") end
    local review = confirmation.new({workspace_id = desktop.workspace_id, origin = {app_id = "bee.shell:shell", instance_id = id}})
    local opened, err = confirmation.open(review, "desktop.close", target, "dialog", "Close desktop", "Close " .. desktop.title .. " and stop its apps?")
    if not opened then return protocol.fail(err or "confirmation failed") end
    local approval_id = assert(review.pending).view.approval_id
    state.desktop_reviews[tostring(approval_id)] = review
    return protocol.ok({approval_id = approval_id})
end

-- confirm accepts a desktop close confirmation with the person's gesture.
function M.confirm(state: State, args: {[string]: unknown}): protocol.Reply
    local id, approval_id, gesture = args.id, args.approval_id, args.gesture
    if type(id) ~= "string" or type(approval_id) ~= "string" then return protocol.fail("confirmation identity is invalid") end
    local review, target = state.desktop_reviews[approval_id], desktop_target(state, id)
    if not review or not target then return protocol.fail("desktop confirmation is unavailable") end
    if gesture ~= "enter" and gesture ~= "space" and gesture ~= "click" then return protocol.fail("confirmation gesture is invalid") end
    local accepted, err = confirmation.accept(review, target, gesture)
    if not accepted then return protocol.fail(err or "confirmation failed") end
    state.desktop_reviews[approval_id] = nil
    return protocol.ok({})
end

-- close stops a desktop's apps and removes it; a desktop a display shows
-- stays.
function M.close(state: State, id: unknown): protocol.Reply
    if type(id) ~= "string" or not workspaces.desktop(id) then return protocol.fail("no such desktop") end
    for _, desktop in pairs(state.watchers) do
        if desktop == id then return protocol.fail("a display shows that desktop") end
    end
    for _, instance in pairs(state.instances) do
        if instance.desktop == id then
            local stopped = apps.stop(state, instance)
            if not stopped.ok then return stopped end
        end
    end
    local removed, err = workspaces.remove_desktop(id)
    if not removed then return protocol.fail(err or "desktop not removed") end
    node_state.announce_workspaces(state)
    return protocol.ok({desktop = id})
end

return M
