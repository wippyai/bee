-- MIT. A sessions owner listing three sessions: Doomed until its test marks it
-- removed, Kept, and Shared, whose thread other sessions take part in. remove
-- and rename report to the waiting test and return once the test has
-- recorded them, so the list the Agents app reloads shows the outcome.
local process = require("process")
local M = {}
M.WAITER = "bee.tests.harness.app.remover"
M.MARKER = "bee.tests.harness.app.removed"
M.LISTENER = "bee.tests.harness.app.lister"
M.RENAMED = "bee.tests.harness.app.renamed"
M.NAME = "Release checks"
M.KEPT, M.DOOMED = "bs:n:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:kept", "bs:n:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:doomed"
M.SHARED = "bs:n:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:shared"
local STAMP = "2026-09-29T10:00:00.000Z"
local function snapshot(session: string, title: string, at: string, shared: boolean?): {[string]: unknown}
    return {session = session, revision = 1, incarnation = 1, title = title, lifecycle = "active", activity = "idle",
        execution = {state = "quiescent", evidence_at = at, stale = false}, queue_count = 0, thread_shared = shared == true,
        effective_limits = {}, continuity = {mode = "fresh"}, actions = {}}
end
-- report hands request to the waiting test and returns once it is recorded.
local function report(topic: string, request: {[string]: unknown})
    local recorded = assert(process.listen("bee.tests.harness.app.recorded", {message = true}))
    local waiter = assert(process.registry.lookup(M.WAITER), "the owner has no waiting test")
    assert(process.send(tostring(waiter), topic, request))
    recorded:receive()
    process.unlisten(recorded)
end
function M.list(_request: unknown): {[string]: unknown}
    local listener = process.registry.lookup(M.LISTENER)
    if listener then process.send(tostring(listener), "bee.tests.harness.app.listed", {}) end
    local items = {snapshot(M.DOOMED, "Doomed agent", STAMP)}
    if process.registry.lookup(M.RENAMED) then items[1].title, items[1].name = M.NAME, M.NAME end
    if process.registry.lookup(M.MARKER) then items = {} end
    items[#items + 1] = snapshot(M.KEPT, "Kept agent", "2026-09-29T09:00:00.000Z")
    items[#items + 1] = snapshot(M.SHARED, "Shared agent", "2026-09-29T08:00:00.000Z", true)
    return {ok = true, value = {items = items}}
end
function M.remove(request: unknown): {[string]: unknown}
    local input = type(request) == "table" and request or {}
    report("bee.tests.harness.app.remove", {session = input.session, history = input.history, operation_key = input.operation_key})
    return {ok = true, value = {operation = "bo:n:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:removal", session = input.session, state = "removing"}}
end
function M.rename(request: unknown): {[string]: unknown}
    local input = type(request) == "table" and request or {}
    report("bee.tests.harness.app.rename", {session = input.session, name = input.name, operation_key = input.operation_key})
    local name = type(input.name) == "string" and input.name ~= "" and input.name or nil
    return {ok = true, value = {operation = "bo:n:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:rename", session = input.session, title = name or "Doomed agent", name = name}}
end
return M
