-- MIT. Entry point for bee.placement:workdir_preparer setup method.
local worktree = require("worktree")
local bounds = require("bounds")
local M = {}

function M.handle(value: unknown): {[string]: unknown}
    local obj = bounds.object(value)
    if not obj then return {ok = false, error = {code = "INVALID", message = "setup input must be an object"}} end
    local attempt_id = bounds.id(obj.attempt_id)
    if not attempt_id then return {ok = false, error = {code = "INVALID", message = "attempt_id is required"}} end
    local workdir = bounds.text(obj.working_directory, 8192)
    if not workdir or workdir:sub(1, 1) ~= "/" then
        return {ok = false, error = {code = "INVALID", message = "working_directory must be an absolute path"}}
    end
    local raw_roots = bounds.array(obj.write_roots, 64) or {}
    local write_roots: {string} = {}
    for _, item in ipairs(raw_roots) do
        local r = bounds.text(item, 8192)
        if r and r:sub(1, 1) == "/" then write_roots[#write_roots + 1] = r end
    end
    local options = bounds.object(obj.options)
    local is_dedicated = options ~= nil and options.worktree == "dedicated"

    if is_dedicated then
        local new_workdir, extra_roots, state, err = worktree.create_dedicated(workdir, attempt_id, write_roots)
        if not new_workdir or err then
            return {ok = false, error = {code = "WORKTREE_FAILED", message = tostring(err or "create dedicated worktree failed")}}
        end
        return {
            ok = true,
            value = {
                working_directory = new_workdir,
                extra_writable_roots = extra_roots or {},
                state = state,
            }
        }
    else
        local extra_roots, err = worktree.detect_git_roots(workdir, write_roots)
        if not extra_roots then
            return {ok = false, error = {code = "DETECT_FAILED", message = tostring(err or "detect git roots failed")}}
        end
        return {
            ok = true,
            value = {
                working_directory = nil,
                extra_writable_roots = extra_roots,
                state = nil,
            }
        }
    end
end

return M
