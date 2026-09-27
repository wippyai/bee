-- MIT. Entry point for bee.placement:workdir_preparer cleanup method.
local worktree = require("worktree")
local bounds = require("bounds")
local M = {}

function M.handle(value: unknown): {[string]: unknown}
    local obj = bounds.object(value)
    if not obj then return {ok = false, error = {code = "INVALID", message = "cleanup input must be an object"}} end
    local state = obj.state
    if not state or type(state) ~= "table" then
        return {ok = true, value = {retained = false}}
    end

    local retained, reason, err = worktree.cleanup_dedicated(state)
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
