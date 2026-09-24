-- Runnable Bee UI reference. It owns no data or system authority.
local tty = require("tty")
local process = require("process")
local channel = require("channel")
local uuid = require("uuid")
local client = require("client")
local appearance = require("appearance")
local frame = require("frame")
local view = require("view")

local function main(value: unknown)
    local launch = client.launch(value)
    if not launch then error("Invalid application launch") end
    local broker = launch.broker_pid
    local input = assert(tty.events())
    local lifecycle = assert(process.events())
    local states = assert(process.listen("bee.appearance.state", {message = true}))
    assert(tty.start())
    local output = assert(tty.surface())
    local width, height = tty.screen_size()
    local preferences = appearance.defaults()
    local section: integer = 1
    local selected: integer = 1
    local hits: {frame.Hit} = {}
    local running, dirty, ready = true, true, false

    if broker then
        process.send(broker, "bee.appearance.request", {version = 1, request_id = uuid.v7(), op = "state"})
    end
    while running do
        if dirty then
            local drawn = view.draw(width, height, preferences, section, selected)
            hits = drawn.hits
            assert(output:present(drawn.rows, {cursor = {x = 1, y = 1, visible = false}}))
            if not ready then client.ready(launch); ready = true end
            dirty = false
        end
        local event = channel.select({input:case_receive(), lifecycle:case_receive(), states:case_receive()})
        if not event.ok then break end
        if event.channel == lifecycle then
            if event.value.kind == process.event.CANCEL then running = false end
        elseif event.channel == states then
            local message = event.value
            if broker and message:from() == broker then
                local decoded = appearance.decode(message:payload():data())
                if decoded then preferences = decoded; dirty = true end
            end
        else
            local data = event.value
            if data.type == "close" then running = false
            elseif data.type == "resize" then width, height = data.width, data.height; dirty = true
            elseif data.type == "key" and data.action ~= "release" then
                local key = data.key_type
                if key == "tab" or key == "right" then section = section % view.section_count() + 1; selected = 1; dirty = true
                elseif key == "left" then section = (section - 2) % view.section_count() + 1; selected = 1; dirty = true
                elseif key == "up" then if selected > 1 then selected = selected - 1 end; dirty = true
                elseif key == "down" then if selected < view.item_count(section) then selected = selected + 1 end; dirty = true
                elseif key == "esc" or key == "escape" then running = false end
            elseif data.type == "mouse" and data.action == "press" and data.button == "left" then
                local hit = frame.hit(hits, math.floor(tonumber(data.x) or 1), math.floor(tonumber(data.y) or 1))
                if hit then
                    local chosen = view.section_of(hit.kind)
                    if chosen > 0 then section = chosen; selected = 1
                    elseif hit.kind == "item" then selected = hit.index end
                    dirty = true
                end
            end
        end
    end
    process.unlisten(states)
    output:close()
    tty.stop()
end

return {main = main}
