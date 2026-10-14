local tty = require("tty")
local process = require("process")
local channel = require("channel")
local client = require("client")
local frame = require("frame")
local appearance = require("appearance")
local greeting = require("greeting")
local function main(value: unknown)
    local launch = assert(client.launch(value))
    local input = assert(tty.events())
    local lifecycle = assert(process.events())
    local states = assert(process.listen("bee.appearance.state", {message = true}))
    assert(tty.start())
    local output = assert(tty.surface())
    local width, height = tty.screen_size()
    local preferences = appearance.defaults()
    local function paint()
        local painter = frame.new(width, height, preferences)
        frame.header(painter, "HELLO BEE", "A tiny app")
        if height >= 4 then frame.line(painter, 2, greeting.message("Bee"), painter.theme.text) end
        frame.footer(painter, "Ready", "Esc closes", nil, {})
        assert(output:present(frame.rows(painter)))
    end
    assert(process.send(launch.broker_pid, "bee.appearance.request", {version = 1,
        request_id = launch.instance_id, op = "state"}))
    paint()
    client.ready(launch)
    while true do
        local event = channel.select({input:case_receive(), lifecycle:case_receive(), states:case_receive()})
        if not event.ok then break end
        if event.channel == lifecycle then
            if event.value.kind == process.event.CANCEL then break end
        elseif event.channel == states then
            local message = event.value
            local data: unknown = message:payload():data()
            if message:from() == launch.broker_pid and type(data) == "table" and data.version == 1 then
                local decoded = appearance.decode(data)
                if decoded then preferences = decoded; paint() end
            end
        else
            local data = event.value
            if data.type == "close" then break end
            if data.type == "resize" then width, height = data.width, data.height; paint() end
            if data.type == "key" and data.action == "press" and (data.key_type == "escape" or data.key_type == "esc") then break end
        end
    end
    process.unlisten(states)
    output:close()
    tty.stop()
end
return {main = main}
