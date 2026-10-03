-- SPDX-License-Identifier: MIT
local process = require("process")
local channel = require("channel")
local protocol = require("protocol")
local decode = require("decode")
local bounds = require("bounds")
local service = require("service")
local types = require("types")
local M = {}
type Call = (string, unknown) -> service.Reply
type Watch = {states: Channel<process.Message>, exits: Channel<process.Message>,
    outputs: Channel<process.Message>, events: Channel<process.Event>, runner: string?, monitored: boolean,
    eof: {[string]: boolean}, consumed: integer}

function M.listen(): Watch
    return {states = assert(process.listen(protocol.TOPIC_STARTED, {message = true})),
        exits = assert(process.listen(protocol.TOPIC_EXIT, {message = true})),
        outputs = assert(process.listen(protocol.TOPIC_OUTPUT, {message = true})),
        events = assert(process.events()), runner = nil, monitored = false, eof = {}, consumed = 0}
end

function M.close(watch: Watch)
    process.unlisten(watch.states)
    process.unlisten(watch.exits)
    process.unlisten(watch.outputs)
    if watch.runner and watch.monitored then process.unmonitor(watch.runner) end
end

function M.attach(watch: Watch, call: Call, attempt_id: string)
    local reply = call("attach", {attempt_id = attempt_id, recipient = process.pid(), generation = 1})
    if not reply.ok then
        M.close(watch)
        error("attach: " .. tostring(reply.error and reply.error.message))
    end
end

local function status(call: Call, attempt_id: string): types.Attempt
    local reply = call("status", {attempt_id = attempt_id})
    if not reply.ok then error("status: " .. tostring(reply.error and reply.error.message)) end
    local value = assert(bounds.object(reply.value), "status did not return a value")
    local attempt, err = decode.attempt(value.attempt)
    if not attempt then error("status attempt: " .. tostring(err)) end
    return attempt
end

-- The suite timeout bounds a broken test; admission is not a child-start deadline.
function M.wait(watch: Watch, call: Call, attempt_id: string, require_success: boolean)
    local runner_exit: string? = nil
    while true do
        local attempt = status(call, attempt_id)
        if attempt.runner and not watch.runner then
            local monitored, monitor_error = process.monitor(attempt.runner)
            watch.runner = attempt.runner
            watch.monitored = monitored == true
            if not monitored then
                -- Completion can commit between the status read and monitor installation.
                attempt = status(call, attempt_id)
                if attempt.execution_state ~= "start_failed" and attempt.execution_state ~= "exited" then
                    error("monitor runner: " .. tostring(monitor_error) .. "; execution state " .. attempt.execution_state)
                end
            end
        end
        if attempt.execution_state == "start_failed" then
            if require_success then
                local cause = assert(attempt.start_failure, "startup refusal omitted its cause")
                error(cause)
            end
            return
        elseif attempt.execution_state == "exited" then
            if not require_success then return end
            if watch.eof.stdout and watch.eof.stderr then
                if not attempt.exit or attempt.exit.code ~= 0 then
                    error("child exited unsuccessfully: " .. tostring(attempt.exit and attempt.exit.code))
                end
                return
            end
        elseif attempt.execution_state == "uncertain" then
            error("attempt execution is uncertain")
        elseif runner_exit then
            error("runner exited before child completion: " .. runner_exit)
        end
        local selected = channel.select({watch.states:case_receive(), watch.exits:case_receive(),
            watch.outputs:case_receive(), watch.events:case_receive()})
        assert(selected.ok, "placement completion observation interrupted")
        if selected.channel == watch.outputs then
            local message = selected.value
            local output = protocol.decode_output(message:payload():data())
            if output and output.attempt_id == attempt_id and output.generation == 1
                and tostring(message:from()) == watch.runner then
                if output.eof then watch.eof[output.stream] = true end
                watch.consumed = math.max(watch.consumed, output.sequence)
                assert(process.send(watch.runner, protocol.TOPIC_ACK, {generation = 1, consumed_through = watch.consumed}))
            end
        elseif selected.channel == watch.events then
            local event = selected.value
            if event.kind == process.event.CANCEL then error("placement completion observation cancelled") end
            if event.kind == process.event.EXIT and tostring(event.from) == watch.runner then
                local result = bounds.object(event.result)
                runner_exit = tostring(result and result.error or event.error or event.kind)
            end
        end
    end
end

function M.cleanup(call: Call, attempt_id: string)
    local watch = M.listen()
    local ok, err = pcall(function()
        local attempt = status(call, attempt_id)
        if attempt.execution_state ~= "exited" and attempt.execution_state ~= "start_failed" then
            local stopped = call("stop", {attempt_id = attempt_id, mode = "forced"})
            assert(stopped.ok, stopped.error and stopped.error.message)
            M.wait(watch, call, attempt_id, false)
        end
        local cleaned = call("cleanup", {attempt_id = attempt_id})
        assert(cleaned.ok, cleaned.error and cleaned.error.message)
    end)
    M.close(watch)
    if not ok then error(tostring(err)) end
end

return M
