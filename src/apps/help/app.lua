-- MIT. Keyboard help: the desktop's keys and mouse actions as an app window.
-- view owns geometry.
local tty = require("tty")
local channel = require("channel")
local process = require("process")
local appearance = require("appearance")
local frame = require("frame")
local view = require("view")

local function main(options: unknown)
    local input = assert(tty.events())
    local menu = frame.menu()
    local lifecycle = assert(process.events())
    local changes = assert(process.listen(appearance.TOPIC, {message = true}))
    assert(tty.start())
    local output = assert(tty.surface())
    local screen_width, screen_height = tty.screen_size()
    local width, height = math.floor(screen_width), math.floor(screen_height)
    local preferences = appearance.chosen(options)
    local pane: view.Pane = "desktop"
    local offset = 0
    local hits: {frame.Hit} = {}
    local running, dirty = true, true

    local function scroll(amount: integer)
        local last = math.floor(math.max(0, #view.lines(pane) - view.capacity(width, height)))
        offset = math.floor(math.max(0, math.min(last, offset + amount)))
        dirty = true
    end
    local function switch(step: integer)
        local index = 1
        for position, item in ipairs(view.PANES) do if item == pane then index = position end end
        pane = view.PANES[(index - 1 + step + #view.PANES) % #view.PANES + 1] :: view.Pane
        offset = 0
        dirty = true
    end

    while running do
        if dirty then
            local drawn = view.draw(width, height, preferences, pane, offset)
            frame.render(drawn, menu, preferences)
            hits = drawn.hits
            assert(output:present(drawn.rows, {cursor = {x = 1, y = 1, visible = false}}))
            dirty = false
        end
        local event = channel.select({input:case_receive(), lifecycle:case_receive(), changes:case_receive()})
        if not event.ok then break end
        if event.channel == lifecycle then
            if event.value.kind == process.event.CANCEL then running = false end
        elseif event.channel == changes then
            preferences = appearance.chosen(event.value:payload():data())
            dirty = true
        else
            local data, handled = frame.route(menu, event.value, false)
            if handled then dirty = true end
            if data then
                if data.type == "close" then running = false
                elseif data.type == "resize" then
                    width, height = math.floor(data.width), math.floor(data.height)
                    scroll(0)
                elseif data.type == "key" and data.action ~= "release" then
                    local key = data.key_type
                    if key == "up" then scroll(-1)
                    elseif key == "down" then scroll(1)
                    elseif key == "pgup" then scroll(-view.capacity(width, height))
                    elseif key == "pgdown" then scroll(view.capacity(width, height))
                    elseif key == "tab" then switch(data.shift == true and -1 or 1)
                    elseif key == "left" then switch(-1)
                    elseif key == "right" then switch(1) end
                elseif data.type == "mouse" then
                    if data.action == "wheel" then
                        scroll((data.button == "wheel_up" or data.button == "up") and -1 or 1)
                    elseif data.action == "press" and data.button == "left" then
                        local hit = frame.hit(hits, math.floor(tonumber(data.x) or 1), math.floor(tonumber(data.y) or 1))
                        if hit then
                            for _, item in ipairs(view.PANES) do
                                if hit.kind == item then pane = item :: view.Pane; offset = 0; dirty = true end
                            end
                        end
                    end
                end
            end
        end
    end
    output:close()
    tty.stop()
end
return {main = main}
