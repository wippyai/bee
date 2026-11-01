-- MIT. A sessions owner listing two sessions until its test marks the second
-- removed. remove reports to the waiting test and returns once the test has
-- recorded the removal, so the list the Agents app reloads omits it.
local process = require("process")
local M = {}
M.WAITER = "bee.tests.harness.app.remover"
M.MARKER = "bee.tests.harness.app.removed"
M.KEPT, M.DOOMED = "bs:n:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:kept", "bs:n:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:doomed"
local STAMP = "2026-09-29T10:00:00.000Z"
local function snapshot(session: string, title: string, at: string): {[string]: unknown}
    return {session = session, revision = 1, incarnation = 1, title = title, lifecycle = "active", activity = "idle",
        execution = {state = "quiescent", evidence_at = at, stale = false}, queue_count = 0,
        effective_limits = {}, continuity = {mode = "fresh"}, actions = {}}
end
function M.list(_request: unknown): {[string]: unknown}
    local items = {snapshot(M.DOOMED, "Doomed agent", STAMP)}
    if process.registry.lookup(M.MARKER) then items = {} end
    items[#items + 1] = snapshot(M.KEPT, "Kept agent", "2026-09-29T09:00:00.000Z")
    return {ok = true, value = {items = items}}
end
function M.remove(request: unknown): {[string]: unknown}
    local input = type(request) == "table" and request or {}
    local recorded = assert(process.listen("bee.tests.harness.app.recorded", {message = true}))
    local waiter = assert(process.registry.lookup(M.WAITER), "remove has no waiting test")
    assert(process.send(tostring(waiter), "bee.tests.harness.app.remove", {session = input.session, operation_key = input.operation_key}))
    recorded:receive()
    process.unlisten(recorded)
    return {ok = true, value = {operation = "bo:n:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:removal", session = input.session, state = "removing"}}
end
return M
