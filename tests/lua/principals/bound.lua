-- MIT. Test principals bound to one workspace, as the broker binds a host-issued
-- application identity and the gateway binds a subject to its binding's
-- workspace. Workspace-scoped policies compare the resource with this metadata.
local security = require("security")
local bounds = require("bounds")
local caller = require("caller")
type Reply = caller.Envelope
type ReplayedReply = {ok: boolean, error: caller.Fault?, value: unknown, replayed: boolean}
local M = {}
function M.reply(raw: unknown): Reply
    return assert(caller.envelope(raw), "invalid fixture reply")
end
function M.replayed_reply(raw: unknown): ReplayedReply
    local reply = M.reply(raw)
    if type(reply.replayed) ~= "boolean" then error("invalid reply replay flag") end
    return {ok = reply.ok, error = reply.error, value = reply.value, replayed = reply.replayed}
end
function M.actor(actor_id: string, workspace_id: unknown): security.Actor
    local meta: {[string]: string} = {}
    if type(workspace_id) == "string" then meta.workspace_id = workspace_id end
    return security.new_actor(actor_id, meta)
end
-- The workspace a request names; a principal acting on it is bound there.
function M.workspace(request: unknown): unknown
    if type(request) ~= "table" then return nil end
    return request.workspace_id
end
function M.items(raw: unknown): {unknown}
    if type(raw) ~= "table" then error("fixture list must be a table") end
    return assert(bounds.array(raw, #raw))
end
function M.objects(raw: unknown, maximum: integer?): {{[string]: unknown}}
    if type(raw) ~= "table" then error("fixture list must be a table") end
    local rows = assert(bounds.array(raw, maximum or #raw))
    local objects: {{[string]: unknown}} = {}
    for index, row in ipairs(rows) do objects[index] = assert(bounds.object(row)) end
    return objects
end
function M.strings(raw: unknown, maximum: integer?): {string}
    if type(raw) ~= "table" then error("fixture list must be a table") end
    local rows = assert(bounds.array(raw, maximum or #raw))
    local strings: {string} = {}
    for index, row in ipairs(rows) do
        if type(row) ~= "string" then error("fixture list item must be text") end
        strings[index] = row
    end
    return strings
end
return M
