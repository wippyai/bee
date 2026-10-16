-- MIT. Sessions fixtures for one session restored by two windows.
local process = require("process")
local M = {}
M.WORKSPACE = string.rep("b", 32)
M.SESSION = "bs:fixture-node:" .. M.WORKSPACE .. ":single-owner"
M.THREAD = "thread:single-owner"
M.OBSERVER = "bee.test.single_owner_observer"
function M.list(): {[string]: unknown}
    return {ok = true, value = {items = {{session = M.SESSION, title = "Claude Code", revision = 1, incarnation = 1,
        lifecycle = "active", activity = "idle", queue_count = 0, execution = {state = "quiescent", evidence_at = "2026-09-29T10:00:00.000Z", stale = false},
        effective_limits = {}, continuity = {mode = "fresh"}, actions = {}, thread_ref = M.THREAD, workspace = M.WORKSPACE}}}}
end
-- A second restorer admits a continuation; the observer counts each one.
function M.attach(): {[string]: unknown}
    local observer = process.registry.lookup(M.OBSERVER)
    if observer then process.send(tostring(observer), "bee.test.second_restorer", {}) end
    return {ok = false, error = {code = "CONFLICT", message = "fixture refuses a second restorer", retry = "never"}}
end
return M
