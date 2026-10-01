-- MIT. Fixture producer and viewer exercise independent terminal lifetimes.
local process = require("process")
local tty = require("tty")
local channel = require("channel")
local terminal_view = require("terminal_view")
local client = require("client")
local M = {}
function M.get(): {[string]: unknown} return {ok = true, value = {}} end
function M.viewer(value: unknown, observer: string)
    local launch = assert(client.launch(value))
    local release = assert(process.listen("bee.test.viewer_release", {message = true}))
    local input = assert(tty.events())
    local events = assert(process.events())
    local closes = assert(process.listen("bee.app.close", {message = true}))
    assert(tty.start())
    process.send(observer, "bee.test.viewer_ready", {})
    release:receive()
    local closing, err = terminal_view.run(launch, "fixture-session", input, events, closes)
    process.send(observer, "bee.test.viewer_finished", {closing = closing, error = err})
    tty.stop()
end
function M.producer(observer: string)
    local publish = assert(process.listen("bee.test.publish", {message = true}))
    local input = assert(tty.events())
    local events = assert(process.events())
    assert(tty.start())
    process.send(observer, "bee.test.producer_ready", {})
    local resized = false
    local output: tty.Surface? = nil
    while true do
        local event = channel.select({input:case_receive(), publish:case_receive(), events:case_receive()})
        if not event.ok or (event.channel == events and event.value.kind == process.event.CANCEL) then break end
        if event.channel == input and not resized and event.value.type == "resize" then
            resized = true
            process.send(observer, "bee.test.viewer_resized", {})
        elseif event.channel == publish then
            output = assert(tty.surface())
            assert(output:present({"retained prior terminal content"}))
        end
    end
    if output then output:close() end
    tty.stop()
end
return M
