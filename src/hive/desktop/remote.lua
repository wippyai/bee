-- MIT. Chooses the display a remote view attaches to on another node's
-- desktop bridge, through the bridge's own lease and attach path. The listing
-- names no owner execution and learns it from the answer; every attach then
-- names that execution. Control reuses the first display without a controller
-- and allocates a fresh one only after definite DESKTOP_CONTROLLED refusals;
-- observation uses the node's default display. Nothing is retried.
local types = require("types")
local bounds = require("bounds")
local contract = require("contract")
local display = require("display")
local M = {}
type Mode = "control" | "observe"
type Fault = display.Fault
-- The calls one selection makes. list pages no workspaces (limit 1) and names
-- no execution; create allocates one node display; open attaches one target.
type Operations = {
    list: () -> types.Reply,
    create: (string, string) -> types.Reply,
    open: (display.Target) -> (display.Handle?, Fault?),
    new_id: () -> string,
}
type Opened = {handle: display.Handle, target: display.Target}
M.MAX_DISPLAYS = 33
local function refused(reply: types.Reply, fallback: string): Fault
    local failure = reply.error
    if failure then return {code = failure.code, message = failure.message} end
    return {code = "UNAVAILABLE", message = fallback}
end
-- The owner execution and display identities a listing answered, default first.
function M.displays(value: unknown): (string?, {string}?)
    local object = bounds.object(value)
    if not object then return nil, nil end
    local execution = contract.workspace_id(object.owner_execution)
    local rows = object.desktops
    if not execution or type(rows) ~= "table" then return nil, nil end
    local ids: {string} = {}
    for index, raw in ipairs(rows :: {unknown}) do
        local row = bounds.object(raw)
        local id = row and contract.workspace_id(row.desktop_id)
        if not row or not id or index > M.MAX_DISPLAYS then return nil, nil end
        ids[#ids + 1] = id
    end
    return execution, ids
end
function M.choose(ops: Operations, node: string, workspace_id: string, mode: Mode): (Opened?, Fault?)
    local listed = ops.list()
    if not listed.ok then return nil, refused(listed, "The node did not list its displays") end
    local execution, ids = M.displays(listed.value)
    if not execution or not ids then return nil, {code = "INVALID_STATE", message = "The node answered a malformed display listing"} end
    local function attach(desktop_id: string): (Opened?, Fault?)
        local target, target_error = display.target(node, execution, workspace_id, desktop_id, mode)
        if not target then return nil, {code = "INVALID_ARGUMENT", message = target_error or "invalid remote target"} end
        local handle, fault = ops.open(target)
        if not handle then return nil, fault or {code = "UNAVAILABLE", message = "desktop attach refused"} end
        return {handle = handle, target = target}, nil
    end
    if mode == "observe" then
        local first = ids[1]
        if not first then return nil, {code = "NOT_FOUND", message = "The node has no display to observe"} end
        return attach(first)
    end
    for _, id in ipairs(ids) do
        local opened, fault = attach(id)
        if opened then return opened, nil end
        if not fault or fault.code ~= "DESKTOP_CONTROLLED" then return nil, fault end
    end
    local id = ops.new_id()
    local created = ops.create(execution, id)
    if not created.ok then return nil, refused(created, "The node did not allocate a display") end
    return attach(id)
end
return M
