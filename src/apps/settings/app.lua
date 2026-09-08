-- A standalone application: workspace owns preferences; view owns only geometry.
local tty = require("tty")
local client = require("client")
local channel = require("channel")
local process = require("process")
local uuid = require("uuid")
local time = require("time")
local json = require("json")
local appearance = require("appearance")
local view = require("view")
local function main(value: unknown)
    local launch = client.launch(value)
    if not launch then error("Invalid application launch") end
    local broker = launch.broker_pid
    local announced = false
    local input = assert(tty.events())
    local lifecycle = assert(process.events())
    local states = assert(process.listen("bee.appearance.state", {message = true}))
    assert(tty.start())
    local output = assert(tty.surface())
    local width, height = tty.screen_size()
    local preferences: appearance.Preferences = appearance.defaults()
    local confirmed: appearance.Preferences = preferences
    local status = ""
    local pending_ticks = 0
    local ticker = assert(time.ticker("1s"))
    local ticks = ticker:channel()
    local pane: view.Pane = "theme"
    local offset = 0
    local last_checkpoint = ""
    if launch.resume_state ~= "" then
        local restored: unknown = json.decode(launch.resume_state)
        if type(restored) ~= "table" or (restored.pane ~= "theme" and restored.pane ~= "background" and restored.pane ~= "taskbar")
            or type(restored.offset) ~= "number" or restored.offset < 0 or restored.offset > 10000
            or restored.offset ~= math.floor(restored.offset) then error("Invalid Settings checkpoint") end
        pane = restored.pane; offset = math.floor(restored.offset)
    end
    local hits: {view.Hit} = {}
    local pending = ""
    local running, dirty = true, true
    local function count(): integer return pane == "taskbar" and 2 or (pane == "theme" and #appearance.themes() or #appearance.backgrounds()) end
    local function selected(): integer
        if pane == "taskbar" then return preferences.taskbar == "icons" and 2 or 1 end
        if pane == "theme" then
            for index, theme in ipairs(appearance.themes()) do if theme.id == preferences.theme then return index end end
        else
            for index, background in ipairs(appearance.backgrounds()) do if background == preferences.background then return index end end
        end
        return 1
    end
    local function reveal()
        offset = view.offset(selected(), offset, view.grid(width, height), count(), true)
    end
    local function choose(index: integer)
        local value = math.floor(math.max(1, math.min(count(), index)))
        local next_preferences: appearance.Preferences
        if pane == "theme" then next_preferences = {theme = appearance.themes()[value].id, background = preferences.background, taskbar = preferences.taskbar}
        elseif pane == "background" then next_preferences = {theme = preferences.theme, background = appearance.backgrounds()[value], taskbar = preferences.taskbar}
        else next_preferences = {theme = preferences.theme, background = preferences.background, taskbar = value == 2 and "icons" or "labels"} end
        preferences = next_preferences
        pending = uuid.v7(); pending_ticks = 0; status = ""
        if broker then
            local sent, err = process.send(broker, "bee.appearance.request", {version = 1, request_id = pending, op = "set", theme = preferences.theme, background = preferences.background, taskbar = preferences.taskbar})
            if not sent then pending = ""; preferences = confirmed; status = tostring(err) end
        end
        reveal(); dirty = true
    end
    local function browse(amount: integer)
        local grid = view.grid(width, height)
        offset = view.offset(selected(), offset + amount, grid, count(), false)
        dirty = true
    end
    local function switch(next_pane: view.Pane)
        pane = next_pane; offset = 0; reveal(); dirty = true
    end
    if broker then process.send(broker, "bee.appearance.request", {version = 1, request_id = uuid.v7(), op = "state"}) end
    while running do
        if dirty then
            local frame = view.draw(width, height, preferences, pane, offset, status)
            hits = frame.hits
            assert(output:present(frame.rows, {cursor = {x = 1, y = 1, visible = false}}))
            if not announced then client.ready(launch); announced = true end
            local checkpoint = json.encode({pane = pane, offset = offset})
            if checkpoint ~= last_checkpoint then
                local sent = client.checkpoint(launch, checkpoint)
                if sent then last_checkpoint = checkpoint end
            end
            dirty = false
        end
        local event = channel.select({input:case_receive(), lifecycle:case_receive(), states:case_receive(), ticks:case_receive()})
        if not event.ok then break end
        if event.channel == lifecycle then
            if event.value.kind == process.event.CANCEL then running = false end
        elseif event.channel == ticks then
            if pending ~= "" then
                pending_ticks = pending_ticks + 1
                if pending_ticks >= 5 then pending = ""; preferences = confirmed; status = "Appearance update timed out"; dirty = true end
            end
        elseif event.channel == states then
            local message = event.value
            if broker and message:from() == broker then
                local payload: unknown = message:payload():data()
                local next_preferences = appearance.decode(payload)
                if next_preferences and type(payload) == "table" and payload.version == 1 then
                    local error_code = type(payload.error_code) == "string" and payload.error_code or ""
                    if error_code == "" then confirmed = next_preferences end
                    -- An older acknowledgement must not undo a newer key/click.
                    if pending == "" or pending == payload.request_id then
                        preferences = confirmed
                        pending = ""; dirty = true
                        status = type(payload.error) == "string" and payload.error or ""
                    end
                end
            end
        else
            local data = event.value
            if data.type == "close" then running = false
            elseif data.type == "resize" then
                width, height = data.width, data.height
                reveal(); dirty = true
            elseif data.type == "key" and data.action ~= "release" then
                local key = data.key_type
                local grid = view.grid(width, height)
                if key == "left" then choose(selected() - 1)
                elseif key == "right" then choose(selected() + 1)
                elseif key == "up" then choose(selected() - grid.columns)
                elseif key == "down" then choose(selected() + grid.columns)
                elseif key == "home" then choose(1)
                elseif key == "end" then choose(count())
                elseif key == "pgup" then browse(-grid.capacity)
                elseif key == "pgdown" then browse(grid.capacity)
                elseif key == "tab" then switch(pane == "theme" and "background" or (pane == "background" and "taskbar" or "theme"))
                elseif key == "esc" or key == "escape" then running = false end
            elseif data.type == "mouse" then
                local x, y = math.floor(tonumber(data.x) or 1), math.floor(tonumber(data.y) or 1)
                if data.action == "wheel" and y >= 4 and y < height - 2 then
                    local grid = view.grid(width, height)
                    local step = (data.button == "wheel_up" or data.button == "up") and -grid.columns or grid.columns
                    browse(step)
                elseif data.action == "press" and data.button == "left" then
                    local hit = view.hit(hits, x, y)
                    if hit then
                        if hit.kind == "theme" then switch("theme")
                        elseif hit.kind == "background" then switch("background")
                        elseif hit.kind == "taskbar" then switch("taskbar")
                        elseif hit.kind == "select" then choose(hit.index)
                        elseif hit.kind == "step" then choose(selected() + hit.index)
                        elseif hit.kind == "page" then browse(hit.index * view.grid(width, height).capacity) end
                    end
                end
            end
        end
    end
    ticker:stop()
    process.unlisten(states)
    output:close()
    tty.stop()
end
return {main = main}
