-- SPDX-License-Identifier: MIT
local process = require("process")
local channel = require("channel")
local service = require("service")
local store = require("store")
local protocol = require("protocol")
local bounds = require("bounds")
local M = {}
function M.read_attempt(value: unknown): unknown
    local db = assert(store.open())
    local attempt, err = store.attempt(db, assert(bounds.id(value)))
    db:release()
    return assert(attempt, err)
end
function M.start(request: unknown): service.Reply
    return service.start_local(request, "bee.placement.native:startup_runner")
end
function M.main(attempt_id: string, supervisor: string, reply_topic: string, _binding: string?, _key: string?, control_token: string, _materialization_epoch: integer)
    local events = assert(process.events())
    local advances = assert(process.listen("bee.test.startup.advance", {message = true}))
    local controls = assert(process.listen(protocol.TOPIC_CONTROL, {message = true}))
    local launch = assert(process.listen(reply_topic .. ".launch", {message = true}))
    assert(process.send(supervisor, reply_topic, {ready = true}))
    local released = channel.select({launch:case_receive(), events:case_receive()})
    if released.channel ~= launch then return end
    process.unlisten(launch)
    local db = assert(store.open())
    local pending = assert(store.row(db, attempt_id))
    local pending_request = assert(store.request(pending))
    local recipient = pending.recipient
    assert(type(recipient) == "string", "fixture recipient")
    if pending_request.launch.argv[1] == "cancel_before_claim" then
        assert(process.send(recipient, "bee.test.startup.claim", {attempt_id = attempt_id}))
        local advanced = assert((advances:receive()))
        assert(tostring(advanced:from()) == recipient, "fixture claim barrier sender")
    end
    assert(pending.runner_pid == process.pid(), "fixture runner ownership")
    local claimed = store.transition(db, attempt_id, {evidence = {kind = "runner.started", detail = "controllable fixture"}})
    assert(claimed.ok, claimed.message)
    local row = assert(store.row(db, attempt_id))
    local cancelled = row.execution_state == "stopping"
    local request = assert(store.request(row))
    assert(type(row.recipient) == "string")
    assert(process.send(row.recipient, "bee.test.startup.pending", {attempt_id = attempt_id}))
    if cancelled then
        assert(store.transition(db, attempt_id, {execution = "exited", cleanup = "complete",
            evidence = {kind = "child.not_started", detail = "explicit cancellation before child creation"}}).ok)
        assert(process.send(row.recipient, "bee.test.startup.state", {attempt_id = attempt_id}))
    end
    while true do
        local selected = channel.select({advances:case_receive(), controls:case_receive(), events:case_receive()})
        if selected.channel == events then
            db:release()
            return
        elseif selected.channel == controls then
            local data: unknown = selected.value:payload():data()
            if type(data) == "table" and data.control_token == control_token and data.command == "stop" then
                cancelled = true
                assert(store.transition(db, attempt_id, {execution = "exited", cleanup = "complete",
                    evidence = {kind = "child.not_started", detail = "explicit cancellation before child creation"}}).ok)
                assert(process.send(row.recipient, "bee.test.startup.state", {attempt_id = attempt_id}))
            end
        else break end
    end
    if cancelled then
        assert(process.send(supervisor, reply_topic, {started = true}))
    elseif request.launch.argv[1] == "exit" then
        db:release()
        error("fixture runner crashed before acknowledgement")
    elseif request.launch.argv[1] == "refuse" then
        local reason = "fixture daemon refused containers/create"
        assert(store.transition(db, attempt_id, {execution = "start_failed", evidence = {kind = "child.start_failed", detail = reason}}).ok)
        assert(process.send(supervisor, reply_topic, {started = false, reason = reason}))
        db:release()
        return
    else
        local running = store.transition(db, attempt_id, {expected_execution = "starting", execution = "running", evidence = {kind = "child.started", detail = "fixture acknowledged"}})
        assert(running.ok, running.message)
        assert(process.send(supervisor, reply_topic, {started = true}))
    end
    if request.launch.argv[1] == "closure" then
        local message = assert((controls:receive()))
        local data: unknown = message:payload():data()
        assert(type(data) == "table" and data.control_token == control_token and data.command == "close_stdin")
        assert(process.send(row.recipient, "bee.test.closure.held", {}))
        assert((advances:receive()))
        assert(process.send(tostring(message:from()), protocol.TOPIC_STDIN, {attempt_id = attempt_id,
            generation = 1, probe = data.probe, closed = true}))
    end
    events:receive()
    db:release()
end
return M
