-- MIT. Entry point for bee.placement:workdir_preparer setup method.
local worktree = require("worktree")
local bounds = require("bounds")
local M = {}

local function prepare(value: unknown, planning: boolean): {[string]: unknown}
    local obj = bounds.object(value)
    if not obj then return {ok = false, error = {code = "INVALID", message = "setup input must be an object"}} end
    local attempt_id = bounds.id(obj.attempt_id)
    if not attempt_id then return {ok = false, error = {code = "INVALID", message = "attempt_id is required"}} end
    local workdir = bounds.text(obj.working_directory, 8192)
    if not workdir or workdir:sub(1, 1) ~= "/" then
        return {ok = false, error = {code = "INVALID", message = "working_directory must be an absolute path"}}
    end
    local raw_roots = bounds.array(obj.write_roots, 64)
    if not raw_roots then return {ok = false, error = {code = "INVALID", message = "write_roots must be an array"}} end
    local write_roots: {string} = {}
    for _, item in ipairs(raw_roots) do
        local r = bounds.text(item, 8192)
        if not r or r:sub(1, 1) ~= "/" then return {ok = false, error = {code = "INVALID", message = "invalid write root"}} end
        write_roots[#write_roots + 1] = r
    end
    local options = bounds.object(obj.options)
    local is_dedicated = options ~= nil and options.worktree == "dedicated"

    if is_dedicated then
        if planning then
            local state, err = worktree.plan_dedicated(workdir, attempt_id, write_roots)
            if not state then return {ok = false, error = {code = "WORKTREE_FAILED", message = err}} end
            return {ok = true, value = {state = state}}
        end
        local planned, plan_error = worktree.decode_state(obj.state)
        if not planned or planned.attempt_id ~= attempt_id then
            return {ok = false, error = {code = "INVALID", message = plan_error or "attempt ownership mismatch"}}
        end
        local new_workdir, extra_roots, state, err = worktree.apply_dedicated(planned, write_roots)
        if not new_workdir or err then
            return {ok = false, error = {code = "WORKTREE_FAILED", message = tostring(err or "create dedicated worktree failed")}}
        end
        return {
            ok = true,
            value = {
                working_directory = new_workdir,
                handled_options = {"worktree"},
                extra_writable_roots = extra_roots or {},
                state = state,
            }
        }
    else
        if planning then return {ok = true, value = {}} end
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

function M.plan(value: unknown): {[string]: unknown}
    return prepare(value, true)
end
function M.handle(value: unknown): {[string]: unknown}
    return prepare(value, false)
end
return M
