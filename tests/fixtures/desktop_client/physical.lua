-- MIT. A replaceable display actor over a retained desktop's native mount.
local tty = require("tty")
local process = require("process")
local channel = require("channel")
local time = require("time")
local input_decode = require("input_decode")

local function main(owner: string)
    local configure = assert(process.listen("physical.configure", {message = true}))
    assert(process.send(owner, "physical.boot", {}))
    local message = assert(configure:receive())
    assert(tostring(message:from()) == owner)
    local value: unknown = message:payload():data()
    if type(value) ~= "table" or type(value.mount) ~= "string" then error("Invalid physical attachment") end
    local view = assert(tty.attach(value.mount))
    assert(tty.start())
    local output = assert(tty.surface({alternate_screen = true, hide_cursor = true, synchronized_output = true}))
    local input = assert(tty.events())
    local events = assert(process.events())
    assert(process.send(owner, "physical.ready", {}))
    while true do
        local frame = view:snapshot()
        if frame then assert(output:present(frame.rows)) end
        local selected = channel.select({input:case_receive(), events:case_receive(), time.after("10ms"):case_receive()})
        if selected.channel == input and selected.ok then
            local event = input_decode.decode(selected.value)
            -- The physical display's close belongs to this attachment only.
            -- Forwarding it would close the retained desktop behind the mount.
            if event and event.type == "close" then break end
            if event then assert(view:send(event)) end
        elseif selected.channel == events and selected.ok then
            break
        end
    end
    output:close()
    view:close()
    tty.stop()
    process.unlisten(configure)
end
return {main = main}
