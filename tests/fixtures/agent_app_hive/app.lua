-- MIT. Retained v2 application fixture for the source-free Hive delivery check.
local tty = require("tty")
local process = require("process")
local channel = require("channel")
local json = require("json")
local client = require("client")

local function main(value: unknown)
    local launch = client.launch(value)
    if not launch then error("Invalid application launch") end
    local count = 0
    if launch.resume_state ~= "" then
        local restored: unknown = json.decode(launch.resume_state)
        if type(restored) ~= "table" or type(restored.count) ~= "number"
            or restored.count < 0 or restored.count ~= math.floor(restored.count) then
            error("Invalid Agent App checkpoint")
        end
        count = restored.count
    end
    local saved = launch.resume_state ~= "" and count or -1
    local input = assert(tty.events())
    local lifecycle = assert(process.events())
    local receipts = assert(process.listen("bee.application.checkpoint_result", {message = true}))
    local pending: {number} = {}
    assert(tty.start())
    local output = assert(tty.surface())
    local width, height = tty.screen_size()
    local function paint()
        local canvas = tty.canvas(width, height)
        canvas:clear(" ")
        canvas:put(1, 1, "AGENT APP UPDATED", width)
        canvas:put(1, 2, "Count: " .. tostring(count), width)
        canvas:put(1, 3, "Saved: " .. tostring(saved), width)
        assert(output:present(canvas:rows()))
    end
    local function checkpoint()
        assert(client.checkpoint(launch, assert(json.encode({count = count}))))
        pending[#pending + 1] = count
    end
    paint()
    client.ready(launch)
    while true do
        local selected = channel.select({input:case_receive(), lifecycle:case_receive(), receipts:case_receive()})
        if not selected.ok then break end
        if selected.channel == lifecycle then
            if selected.value.kind == process.event.CANCEL then break end
        elseif selected.channel == receipts then
            local message = selected.value
            local data: unknown = message:payload():data()
            if message:from() == launch.broker_pid and type(data) == "table" then
                if data.error_code ~= "" then error("Agent App checkpoint was refused") end
                local acknowledged = table.remove(pending, 1)
                if acknowledged then saved = acknowledged; paint() end
            end
        else
            local event = selected.value
            if event.type == "close" then checkpoint(); break end
            if event.type == "resize" then
                width, height = event.width, event.height
                paint()
            elseif event.type == "key" and event.action ~= "release" then
                count = count + 1
                paint()
                checkpoint()
            end
        end
    end
    output:close()
    tty.stop()
end

return {main = main}
