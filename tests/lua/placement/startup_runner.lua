-- MIT. A hosted runner claims the attempt but leaves startup unacknowledged.
local process = require("process")
local service = require("service")
local store = require("store")

local M = {}

function M.start(request: unknown): service.Reply
    return service.start_local(request, "bee.placement.native:startup_runner")
end

function M.main(attempt_id: string)
    local events = assert(process.events())
    local db = assert(store.open())
    local claimed = store.transition(db, attempt_id, {expected_execution = "intended", execution = "starting",
        fields = {runner_pid = process.pid()}, evidence = {kind = "runner.started", detail = "startup fixture"}})
    assert(claimed.ok, claimed.message)
    local row = assert(store.row(db, attempt_id))
    assert(type(row.recipient) == "string")
    assert(process.send(row.recipient, "bee.test.startup.pending", {attempt_id = attempt_id}))
    while true do
        local event = events:receive()
        if event.kind == process.event.CANCEL then break end
    end
    assert(store.transition(db, attempt_id, {execution = "exited", fields = {exit_source = "runner"},
        evidence = {kind = "child.not_started", detail = "startup fixture released without creating a child"}}).ok)
    db:release()
end

return M
