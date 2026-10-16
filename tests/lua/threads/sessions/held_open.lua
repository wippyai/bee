-- MIT. A sessions catalog with one person-launchable definition and an open
-- that waits for its test to resume it and then refuses, so the test observes
-- the opener while the open is in flight.
local process = require("process")
local M = {}
M.WAITER = "bee.tests.threads.sessions.held_open"
function M.open(request: unknown): {[string]: unknown}
    local resume = assert(process.listen("bee.tests.held_open.resume", {message = true}))
    local waiter = process.registry.lookup(M.WAITER)
    assert(waiter, "held open has no waiting test")
    assert(process.send(tostring(waiter), "bee.tests.held_open.held", {}))
    resume:receive()
    process.unlisten(resume)
    local key = type(request) == "table" and request.operation_key or nil
    return {ok = false, error = {code = "DENIED", message = "held open refused", retry = "never", operation_key = key}}
end
function M.catalog(_request: unknown): {[string]: unknown}
    return {ok = true, value = {items = {{ref = "research:held", kind = "definition", title = "Held", status = "ready",
        checked_at = "2026-09-29T10:00:00.000Z", reasons = {}, features = {"presentation:start_menu"}, actions = {}}},
        complete = true, unavailable_count = 0, diagnostics = {}}}
end
return M
