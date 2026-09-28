-- MIT. Entry point for bee.placement:workdir_preparer cleanup method.
local worktree = require("worktree")
local bounds = require("bounds")
local security = require("security")
local types = require("types")
local M = {}

function M.handle(value: unknown): {[string]: unknown}
    local obj = bounds.object(value)
    if not obj then return {ok = false, error = {code = "INVALID", message = "cleanup input must be an object"}} end
    local attempt_id = bounds.id(obj.attempt_id)
    if not attempt_id then return {ok = false, error = {code = "INVALID", message = "attempt_id is required"}} end
    if not security.can(types.WORKDIR_PREPARER_CLEANUP, attempt_id) then
        return {ok = false, error = {code = "DENIED", message = "caller is not placement cleaning up attempt " .. attempt_id}}
    end
    local state = obj.state
    if state == nil then
        return {ok = true, value = {retained = false}}
    end

    local decoded, decode_error = worktree.decode_state(state)
    if not decoded or decoded.attempt_id ~= attempt_id then
        return {ok = false, error = {code = "INVALID", message = decode_error or "attempt ownership mismatch"}}
    end
    local retained, reason, err = worktree.cleanup_dedicated(decoded)
    if err then
        return {ok = false, error = {code = "CLEANUP_FAILED", message = tostring(err)}}
    end
    return {
        ok = true,
        value = {
            retained = retained == true,
            reason = reason,
        }
    }
end

return M
