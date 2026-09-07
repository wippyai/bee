local tty = require("tty")
local client = require("client")
local process = require("process")
local channel = require("channel")

local function main(value: unknown)
    local launch = client.launch(value)
    if not launch then error("Invalid application launch") end
    local input = assert(tty.events())
    local lifecycle = assert(process.events())
    assert(tty.start())
    local output = assert(tty.surface())
    local width, height = tty.screen_size()
    local count = 0
    local function paint()
        local canvas = tty.canvas(width, height)
        canvas:clear(" ")
        local lines: {string} = {
            "", "  B E E   /   workspace desktop", "",
            "  Small shell. Independent applications.", "",
            "  Ctrl+N   Open another Welcome",
            "  Ctrl+P   Open Colors",
            "  Alt+Tab  Switch application",
            "  F11      Toggle fullscreen",
            "  Ctrl+W   Close this view",
            "  Ctrl+Q   Exit desktop", "",
            "  App PID: " .. tostring(process.pid()):sub(-24),
            "  Keys received here: " .. tostring(count),
        }
        for y, line in ipairs(lines) do
            if y <= height then canvas:put(1, y, line, width) end
        end
        assert(output:present(canvas:rows(), {cursor = {x = 1, y = 1, visible = false}}))
    end
    paint()
    client.ready(launch)
    while true do
        local selected = channel.select({input:case_receive(), lifecycle:case_receive()})
        if not selected.ok then break end
        if selected.channel == lifecycle then
            if selected.value.kind == process.event.CANCEL then break end
        else
            local event = selected.value
            if event.type == "close" then break end
            if event.type == "resize" then
                width, height = event.width, event.height
            elseif event.type == "key" and event.action ~= "release" then
                count = count + 1
            end
            paint()
        end
    end
    output:close()
    tty.stop()
end
return {main = main}
