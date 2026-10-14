-- MIT. Test principals bound to one workspace, as the broker binds a host-issued
-- application identity and the gateway binds a subject to its binding's
-- workspace. Workspace-scoped policies compare the resource with this metadata.
local security = require("security")
local fixtures = require("fixtures")
local caller = require("caller")
type Reply = caller.Envelope
type ReplayedReply = {ok: boolean, error: caller.Fault?, value: unknown, replayed: boolean}
local M = {}
function M.reply(raw: unknown): Reply
    local reply = assert(caller.envelope(raw), "invalid fixture reply")
    return reply
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
M.items = fixtures.items
M.objects = fixtures.objects
M.strings = fixtures.strings

return M
