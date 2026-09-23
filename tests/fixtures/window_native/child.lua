local process = require("process")
local channel = require("channel")
local time = require("time")
local funcs = require("funcs")
local window = require("window")
local protocol = require("protocol")

type StopResult = {ok: boolean, error: string}

-- Stops the attempt through the placement service once the window's control
-- listener answers, which it first does while executor:terminal() is starting
-- the child, and reports the stop reply on the returned channel.
local function stop_once_supervised(attempt_id: string): Channel<StopResult>
    local stopped: Channel<StopResult> = channel.new(1)
    local replies = assert(process.listen(protocol.TOPIC_STATUS, {message = true}))
    coroutine.spawn(function()
        local probe = 0
        local supervised = false
        while not supervised do
            probe = probe + 1
            process.send(process.pid(), protocol.TOPIC_CONTROL, {command = "status", attempt_id = attempt_id, probe = "startup-" .. tostring(probe)})
            local selected = channel.select({replies:case_receive(), time.after("5ms"):case_receive()})
            supervised = selected.channel == replies and selected.ok
        end
        process.unlisten(replies)
        local reply, call_error = funcs.call("bee.placement.native:stop", {attempt_id = attempt_id, mode = "cooperative"})
        local accepted = false
        if type(reply) == "table" then accepted = (reply :: {[string]: unknown}).ok == true end
        stopped:send({ok = call_error == nil and accepted, error = tostring(call_error or "")})
    end)
    return stopped
end

local function main(parent: string, attempt_id: string, mode: string)
    if mode == "startup_stop" then
        local stopped = stop_once_supervised(attempt_id)
        local facade, open_error = window.open(attempt_id, {width = 20, height = 8, term = "xterm-256color"})
        local stop = stopped:receive()
        local stop_seen, finished = false, false
        if facade then
            -- A returned window must end from the committed stop alone.
            local selected = channel.select({facade:done():case_receive(), time.after("5s"):case_receive()})
            stop_seen = selected.ok and facade:status() == "done"
            if not stop_seen then facade:close(); facade:done():receive() end
            finished = facade:finish()
        end
        process.send(parent, "bee.window.native.result", {phase = "startup_stop", ok = facade ~= nil, error = open_error or "",
            stop_ok = stop ~= nil and stop.ok, stop_error = stop and stop.error or "stop result missing", stop_seen = stop_seen, finished = finished})
        return
    end
    local facade, open_error = window.open(attempt_id, {width = 20, height = 8, term = "xterm-256color"})
    if mode == "foreign" then
        process.send(parent, "bee.window.native.result", {phase = "foreign", ok = facade ~= nil, error = open_error or ""})
        return
    end
    if not facade then
        process.send(parent, "bee.window.native.result", {phase = mode == "race" and "race" or "open", ok = false, error = open_error or ""})
        return
    end
    if mode == "race" then
        process.send(parent, "bee.window.native.result", {phase = "race", ok = true})
        facade:close()
        facade:done():receive()
        facade:finish()
        return
    end
    local duplicate, duplicate_error = window.open(attempt_id, {width = 20, height = 8, term = "xterm-256color"})
    process.send(parent, "bee.window.native.result", {phase = "open", ok = true, duplicate_ok = duplicate ~= nil, error = duplicate_error or ""})
    local resized, resize_error = facade:send({type = "resize", width = 30, height = 10})
    local sent, send_error = facade:send({type = "paste", text = "hello from window\n"})
    process.send(parent, "bee.window.native.result", {phase = "io", sent = sent, resized = resized,
        errors = tostring(send_error or resize_error or "")})
    local closes = assert(process.listen("bee.window.native.close." .. parent, {message = true}))
    local timeout = time.after("5s")
    local selected = channel.select({closes:case_receive(), timeout:case_receive()})
    process.unlisten(closes)
    local stopped = channel.select({facade:done():case_receive(), time.after("2s"):case_receive()})
    local state = facade:status()
    local stop_seen = stopped.ok and state == "done"
    local closed, close_error = facade:close()
    process.send(parent, "bee.window.native.result", {phase = "close", closed = closed, stop_seen = stop_seen, timed_out = selected.channel == timeout,
        error = close_error or ""})
    local done = facade:done()
    if not stop_seen then done:receive() end
    local finished, finish_error = facade:finish()
    process.send(parent, "bee.window.native.result", {phase = "finish", finished = finished, error = finish_error or ""})
end
return {main = main}
