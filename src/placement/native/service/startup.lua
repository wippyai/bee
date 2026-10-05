-- SPDX-License-Identifier: MIT
-- The attempt supervisor owns the runner monitor for the runner's lifetime.
local process = require("process")
local channel = require("channel")
local sql = require("sql")
local store = require("store")
local bounds = require("bounds")
local service = require("service")
local protocol = require("protocol")
local function main(attempt_id: string, caller: string, reply_topic: string, runner_ref: string,
    host: string, gateway_binding: string?, materialization_key: string?, control_token: string, materialization_epoch: integer)
    local replies = assert(process.listen(reply_topic, {message = true}))
    local events = assert(process.events())
    local db = assert(store.open())
    local starting = store.transition(db, attempt_id, {expected_execution = "intended", execution = "starting",
        evidence = {kind = "runner.start_accepted", detail = "supervisor " .. process.pid()}})
    if not starting.ok then
        if starting.code ~= "CONFLICT" then
            assert(process.send(caller, reply_topic, {ok = false, error = {code = starting.code, message = starting.message}}))
            db:release()
            return
        end
        local attempt, read_error = store.attempt(db, attempt_id)
        assert(not read_error, read_error)
        assert(process.send(caller, reply_topic, attempt and {ok = true, value = attempt} or
            {ok = false, error = {code = starting.code, message = starting.message}}))
        db:release()
        return
    end
    local runner, spawn_error = process.spawn_monitored(runner_ref, host, attempt_id, process.pid(), reply_topic,
        gateway_binding, materialization_key, control_token, materialization_epoch)
    if not runner then
        local reason = "spawn runner: " .. tostring(spawn_error)
        assert(store.transition(db, attempt_id, {evidence = {kind = "child.not_started", detail = reason}}).ok)
        assert(store.transition(db, attempt_id, {execution = "start_failed", evidence = {kind = "child.start_failed", detail = reason}}).ok)
        assert(process.send(caller, reply_topic, {ok = false, error = {code = "UNAVAILABLE", message = reason}}))
        db:release()
        return
    end
    assert(store.transition(db, attempt_id, {fields = {runner_pid = tostring(runner)},
        evidence = {kind = "runner.monitored", detail = "runner " .. tostring(runner) .. " by " .. process.pid()}}).ok)
    local accepted = assert(starting.attempt)
    accepted.runner = tostring(runner)
    assert(process.send(caller, reply_topic, {ok = true, value = accepted}))
    local acknowledged = false
    local released = false
    local function notify()
        local row = assert(store.row(db, attempt_id))
        local recipient = bounds.id(row.recipient)
        if recipient then
            local sent, send_error = process.send(recipient, protocol.TOPIC_STARTED,
                {attempt_id = attempt_id, generation = bounds.count(row.attachment_generation)})
            if not sent then
                assert(store.transition(db, attempt_id, {evidence = {kind = "runner.state_delivery_failed", detail = tostring(send_error)}}).ok)
            end
        end
    end
    local function acknowledgement(sender: string, payload: unknown)
        if sender ~= tostring(runner) then return end
        local value = bounds.object(payload)
        if value and value.ready == true and not released then
            released = true
            assert(process.send(runner, reply_topic .. ".launch", {control_token = control_token}))
            return
        end
        if not value or type(value.started) ~= "boolean" then error("invalid runner startup acknowledgement") end
        if not value.started and not bounds.text(value.reason, 4096) then error("runner refusal has no cause") end
        local current = assert(store.attempt(db, attempt_id))
        if not value.started and not current.start_failure and current.execution_state == "starting" then
            local failed = store.transition(db, attempt_id, {expected_execution = "starting", execution = "start_failed",
                evidence = {kind = "child.start_failed", detail = assert(bounds.text(value.reason, 4096))}})
            assert(failed.ok, failed.message)
            current = assert(failed.attempt)
        end
        local started = assert(db:query("SELECT sequence FROM bee_placement_evidence WHERE attempt_id = ? AND kind = 'child.started' LIMIT 1", {attempt_id}))
        if value.started and (current.execution_state == "stopping" or #started == 0) then
            assert(store.transition(db, attempt_id, {evidence = {kind = "runner.ack_late", detail = "acknowledgement after " .. current.execution_state}}).ok)
        else
            acknowledged = true
            assert(store.transition(db, attempt_id, {evidence = {kind = "runner.ack_received", detail = "runner " .. tostring(runner)}}).ok)
        end
        notify()
    end
    while true do
        local selected = channel.select({replies:case_receive(), events:case_receive()})
        assert(selected.ok, "startup supervision interrupted")
        if selected.channel == replies then acknowledgement(tostring(selected.value:from()), selected.value:payload():data())
        else
            local event = selected.value
            if event.kind == process.event.CANCEL then
                local stopped = service.stop_attempt(assert(store.attempt(db, attempt_id)), "forced")
                assert(stopped.ok, stopped.error and stopped.error.message)
            elseif event.kind == process.event.EXIT and tostring(event.from) == tostring(runner) then
                -- A queued acknowledgement may precede EXIT in another mailbox.
                while true do
                    local queued = channel.select({replies:case_receive(), default = true})
                    if queued.default then break end
                    assert(queued.ok, "read queued startup acknowledgement")
                    if queued.channel == replies then acknowledgement(tostring(queued.value:from()), queued.value:payload():data()) end
                end
                local current = assert(store.attempt(db, attempt_id))
                if not acknowledged and not current.start_failure and current.execution_state == "starting" then
                    local result = bounds.object(event.result)
                    local reason = "runner exited before acknowledging startup: " .. tostring(result and result.error or event.kind)
                    assert(store.transition(db, attempt_id, {expected_execution = "starting", execution = "start_failed",
                        fields = {runner_pid = sql.NULL}, evidence = {kind = "child.start_failed", detail = reason}}).ok)
                elseif current.execution_state == "stopping" then
                    assert(store.transition(db, attempt_id, {evidence = {kind = "runner.exited", detail = "runner exit after explicit stop: " .. tostring(event.result)}}).ok)
                end
                notify()
                break
            end
        end
    end
    process.unmonitor(runner)
    process.unlisten(replies)
    db:release()
end
return {main = main}
