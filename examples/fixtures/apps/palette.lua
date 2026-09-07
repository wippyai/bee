local tty = require("tty")
local client = require("client")
local security = require("security")
local process = require("process")
local channel = require("channel")

local function main(value: unknown)
    local launch = client.launch(value)
    if not launch then error("Invalid application launch") end
    assert(not security.can("tty.observe", "foreign-surface"), "app inherited foreign surface authority")
    assert(not security.can("process.spawn", "bee.apps:welcome"), "app inherited spawn authority")
    assert(not security.can("registry.apply", "bee:definition"), "app inherited publication authority")
    assert(not security.can("process.security", "security"), "app inherited scope authority")
    assert(not security.can("exec.run", "bee:exec"), "app inherited exec authority")
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
            "  SURFACE LAB / default colors", "  Scope isolation checks passed",
            "  Blank cells inherit the same page as text.",
            "  \27[38;2;255;190;80mExplicit amber foreground\27[0m",
            "  \27[48;2;36;76;120mExplicit blue background  \27[0m",
            "  \27[7mReverse default colors\27[0m", "",
            "  Unicode: 界面 · café · λ · ✓",
            string.rep("Long bounded row / ", 24), "",
            "  Keys received here: " .. tostring(count),
            "  App PID: " .. tostring(process.pid()):sub(-24),
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
