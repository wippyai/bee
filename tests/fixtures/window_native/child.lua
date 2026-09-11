local process = require("process")
local channel = require("channel")
local time = require("time")
local window = require("window")
local function main(parent: string, attempt_id: string, mode: string)
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
    local closed, close_error = facade:close()
    process.send(parent, "bee.window.native.result", {phase = "close", closed = closed, timed_out = selected.channel == timeout,
        error = close_error or ""})
    local done = facade:done()
    done:receive()
    local finished, finish_error = facade:finish()
    process.send(parent, "bee.window.native.result", {phase = "finish", finished = finished, error = finish_error or ""})
end
return {main = main}
