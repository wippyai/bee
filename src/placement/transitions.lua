-- MIT. The attempt state machine as a table: which execution transitions
-- exist, which cleanup transitions exist, and when cleanup may run. Pure.
local types = require("types")
local M = {}
local EXECUTION: {[string]: {string}} = {
    intended = {"starting", "uncertain"},
    starting = {"running", "exited", "uncertain"},
    running = {"stopping", "exited", "uncertain"},
    stopping = {"exited", "uncertain"},
    exited = {},
    uncertain = {"exited"},
}
local CLEANUP: {[string]: {string}} = {
    pending = {"complete", "uncertain"},
    uncertain = {"complete"},
    complete = {},
}
local function allowed(table: {[string]: {string}}, from: string, to: string): boolean
    for _, candidate in ipairs(table[from] or {}) do
        if candidate == to then return true end
    end
    return false
end
function M.execution(from: types.ExecutionState, to: types.ExecutionState): boolean
    return allowed(EXECUTION, from, to)
end
function M.cleanup(from: types.CleanupState, to: types.CleanupState): boolean
    return allowed(CLEANUP, from, to)
end
-- Cleanup removes an attempt home only when the process is proven gone:
-- exited, never uncertain, never while anything may still run.
function M.may_clean(execution: types.ExecutionState): boolean
    return execution == "exited"
end
function M.live(execution: types.ExecutionState): boolean
    return execution == "starting" or execution == "running" or execution == "stopping"
end
return M
