-- SPDX-License-Identifier: MIT
local process = require("process")
local channel = require("channel")
local service = require("service")
local store = require("store")

local M = {}

function M.start(request: unknown): service.Reply
    return service.start_local(request, "bee.placement.native:startup_runner")
end

function M.main(attempt_id: string, starter: string, reply_topic: string)
    local events = assert(process.events())
    local release = assert(process.listen("bee.test.startup.release", {message = true}))
    local db = assert(store.open())
    local claimed = store.transition(db, attempt_id, {expected_execution = "intended", execution = "starting",
        fields = {runner_pid = process.pid()}, evidence = {kind = "runner.started", detail = "startup fixture"}})
    assert(claimed.ok, claimed.message)
    local row = assert(store.row(db, attempt_id))
    assert(type(row.recipient) == "string")
    assert(process.send(row.recipient, "bee.test.startup.pending", {attempt_id = attempt_id, starter = starter, reply_topic = reply_topic}))
    local selected = channel.select({release:case_receive(), events:case_receive()})
    if selected.ok and selected.channel == release then
        local message = selected.value
        assert(tostring(message:from()) == row.recipient)
        local data: unknown = message:payload():data()
        assert(type(data) == "table")
        if data.command == "crash" then db:release(); error("startup fixture crashed") end
        if data.command == "acknowledge" then
            local running = store.transition(db, attempt_id, {execution = "running",
                evidence = {kind = "test.acknowledged", detail = "startup fixture released"}})
            assert(running.ok, running.message)
            assert(process.send(starter, reply_topic, {started = true, attempt = running.attempt}))
        else
            assert(data.command == "refuse")
            assert(process.send(starter, reply_topic, {started = false, reason = "startup fixture refused"}))
        end
        while true do
            local event = events:receive()
            if event.kind == process.event.CANCEL then break end
        end
    end
    process.unlisten(release)
    assert(store.transition(db, attempt_id, {execution = "exited", fields = {exit_source = "runner"},
        evidence = {kind = "child.not_started", detail = "startup fixture released without creating a child"}}).ok)
    db:release()
end

return M
