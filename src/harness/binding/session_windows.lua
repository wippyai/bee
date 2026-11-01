-- MIT. A removed session leaves no Agents window behind: every window that
-- shows it, by its session argument or by a checkpoint continuing its
-- thread, closes, so the node forgets it and never reopens it.
local json = require("json")
local system = require("system")
local bounds = require("bounds")
local client = require("client")
local recovery = require("recovery")
local M = {}
M.APP = "bee.harness.app:app"
type Object = {[string]: unknown}
type Reply = {ok: boolean, value: Object?, error: Object?}
local function fail(code: string, message: string): Reply return {ok = false, error = {code = code, message = message}} end

local function shows(item: Object, session: string, thread: string): boolean
    local arguments = bounds.array(item.arguments, 16) or {}
    if arguments[1] == "--session" and arguments[2] == session then return true end
    if type(item.resume_state) ~= "string" then return false end
    local decoded = json.decode(item.resume_state)
    local saved = recovery.decode(decoded)
    return saved ~= nil and saved.thread_id == thread
end

function M.forget(value: unknown): Reply
    local request = bounds.object(value)
    if not request or bounds.fields(request, {"session", "thread_id", "owner_id"}) then return fail("INVALID", "forget_session_windows takes session, thread_id and owner_id") end
    local session, thread = bounds.id(request.session), bounds.id(request.thread_id)
    if not session or not thread then return fail("INVALID", "session and thread_id must be identifiers") end
    local node = assert(system.node.id())
    local listed, list_error = client.call(node, "instances", {app = M.APP})
    local items = listed and bounds.array(listed.instances, 4096)
    if not items then return fail("UNAVAILABLE", list_error or "the node listed no Agents windows") end
    local closed: {string} = {}
    for _, raw in ipairs(items) do
        local item = bounds.object(raw)
        local id = item and bounds.id(item.id)
        if item and id and shows(item, session, thread) then
            local _, close_error = client.call(node, "close", {id = id, force = true, execution_id = item.execution_id})
            if close_error then return fail("UNAVAILABLE", "close Agents window " .. id .. ": " .. close_error) end
            closed[#closed + 1] = id
        end
    end
    return {ok = true, value = {session = session, closed = closed}}
end
return M
