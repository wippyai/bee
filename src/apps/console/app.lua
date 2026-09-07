-- Native local shell. The broker supplies its sole terminal producer capability.
local tty = require("tty")
local exec = require("exec")
local process = require("process")
local channel = require("channel")
local client = require("client")
local function main(value: unknown)
    local launch = client.launch(value)
    if not launch then error("Invalid application launch") end
    local input = assert(tty.events())
    local events = assert(process.events())
    assert(tty.start())
    local width, height = tty.screen_size()
    local executor = assert(exec.get("bee.console:executor"))
    local child, spawn_error = executor:exec("/bin/bash -i", {pty = {term = "xterm-256color", width = width, height = height}})
    if not child then executor:release(); error(tostring(spawn_error)) end
    local terminal, attach_error = child:attach_terminal()
    if not terminal then child:close(true); executor:release(); error(tostring(attach_error)) end
    -- Attachment creates the native proxy and transfers child ownership to it.
    client.ready(launch)
    local done = terminal:done()
    while true do
        local selected = channel.select({input:case_receive(), events:case_receive(), done:case_receive()})
        if not selected.ok or selected.channel == done then break end
        if selected.channel == events then
            if selected.value.kind == process.event.CANCEL then break end
        elseif selected.channel == input then
            local event = selected.value
            if event.type == "close" then break end
            if event.type ~= "start" then
                local sent = terminal:send(event)
                if not sent then break end
            end
        end
    end
    terminal:close()
    executor:release()
    tty.stop()
end
return {main = main}
