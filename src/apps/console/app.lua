-- Native local shell. The broker supplies its sole terminal producer capability.
local tty = require("tty")
local exec = require("exec")
local process = require("process")
local channel = require("channel")
local client = require("client")
local command = require("command")
local function main(value: unknown)
    local launch = client.launch(value)
    if not launch then error("Invalid application launch") end
    local closes = assert(process.listen("bee.application.close", {message = true}))
    local input = assert(tty.events())
    local events = assert(process.events())
    assert(tty.start())
    local width, height = tty.screen_size()
    local executor = assert(exec.get("bee.console:executor"))
    local child, spawn_error = executor:exec(command.encode(launch.arguments), {pty = {term = "xterm-256color", width = width, height = height}})
    if not child then executor:release(); error(tostring(spawn_error)) end
    local terminal, attach_error = child:attach_terminal()
    if not terminal then child:close(true); executor:release(); error(tostring(attach_error)) end
    -- Attachment creates the native proxy and transfers child ownership to it.
    client.ready(launch, {negotiate_close = true})
    if #launch.arguments > 0 then client.title(launch, launch.arguments[1]) end
    local done = terminal:done()
    while true do
        local selected = channel.select({input:case_receive(), events:case_receive(), done:case_receive(), closes:case_receive()})
        if not selected.ok or selected.channel == done then break end
        if selected.channel == events then
            if selected.value.kind == process.event.CANCEL then break end
        elseif selected.channel == closes then
            local request = client.close_request(launch, tostring(selected.value:from()), selected.value:payload():data())
            if request then
                assert(client.close_reply(launch, request.request_id, {action = "confirm", title = "Close terminal?",
                    message = "The shell and any running commands will stop.", accept = "Close terminal"}))
            end
        elseif selected.channel == input then
            local event = selected.value
            if event.type == "close" then break end
            if event.type ~= "start" then
                local sent = terminal:send(event)
                if not sent then break end
            end
        end
    end
    process.unlisten(closes)
    terminal:close()
    executor:release()
    tty.stop()
end
return {main = main}
