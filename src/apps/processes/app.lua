-- On-demand runtime observer. Only the broker can end a workspace application.
local tty = require("tty")
local client = require("client")
local process = require("process")
local channel = require("channel")
local time = require("time")
local uuid = require("uuid")
local appearance = require("appearance")
local probe = require("probe")
local view = require("view")
local function main(value: unknown)
    local launch = client.launch(value)
    if not launch then error("Invalid application launch") end
    local broker = launch.broker_pid
    local announced = false
    local input = assert(tty.events())
    local lifecycle = assert(process.events())
    local states = assert(process.listen("bee.appearance.state", {message = true}))
    local replies = assert(process.listen("bee.application.result", {message = true}))
    assert(tty.start())
    local output = assert(tty.surface())
    local ticker = assert(time.ticker("1s"))
    local ticks = ticker:channel()
    local width, height = tty.screen_size()
    local preferences = appearance.defaults()
    local history = probe.new_history()
    local snapshot = probe.sample()
    local last_time = time.now():unix_nano()
    probe.append(history, snapshot, nil, 0)
    local selected = ""
    local offset, first, capacity = 0, 1, 0
    local paused, confirming, by_steps, services = false, false, false, false
    local rows: {view.Row} = {}
    local status, pending = "", ""
    local pending_ticks = 0
    local running, dirty = true, true
    local function order()
        rows = view.items(snapshot, services)
        table.sort(rows, function(a, b)
            if by_steps and a.steps ~= b.steps then return a.steps > b.steps end
            if a.source ~= b.source then return a.source < b.source end
            return a.pid < b.pid
        end)
        local found = false
        for _, item in ipairs(rows) do if item.pid == selected then found = true end end
        if not found then selected = rows[1] and rows[1].pid or ""; confirming = false end
    end
    local function reveal()
        for index, item in ipairs(rows) do
            if item.pid == selected then
                if index <= offset then offset = index - 1 end
                if index > offset + capacity then offset = math.floor(math.max(0, index - capacity)) end
                break
            end
        end
    end
    local function move(step: integer)
        local index = 1
        for i, item in ipairs(rows) do if item.pid == selected then index = i end end
        index = math.floor(math.max(1, math.min(#rows, index + step)))
        if rows[index] then selected = rows[index].pid end
        confirming = false; status = ""; reveal(); dirty = true
    end
    local function sample()
        local now = time.now():unix_nano()
        local next_snapshot = probe.sample()
        probe.append(history, next_snapshot, snapshot, (now - last_time) / 1000000000)
        snapshot, last_time = next_snapshot, now
        order(); reveal(); dirty = true
    end
    local function toggle_pause()
        paused = not paused
        -- A resumed series starts a fresh rate interval, rather than pretending
        -- a paused minute was a one-second sample.
        if not paused then
            snapshot = probe.sample(); last_time = time.now():unix_nano()
            probe.append(history, snapshot, nil, 0); order(); reveal()
        end
        dirty = true
    end
    local function end_app()
        if not services and broker and selected ~= "" and pending == "" then confirming = true; dirty = true end
    end
    order()
    if broker then process.send(broker, "bee.appearance.request", {version = 1, request_id = uuid.v7(), op = "state"}) end
    while running do
        if dirty then
            local frame = view.draw(width, height, snapshot, history, preferences, selected, offset, paused, status, confirming, services, rows, by_steps)
            first, capacity, offset = frame.first, frame.capacity, frame.offset
            assert(output:present(frame.rows, {cursor = {x = 1, y = 1, visible = false}}))
            if not announced then client.ready(launch); announced = true end
            dirty = false
        end
        local event = channel.select({input:case_receive(), lifecycle:case_receive(), ticks:case_receive(), states:case_receive(), replies:case_receive()})
        if not event.ok then break end
        if event.channel == lifecycle then
            if event.value.kind == process.event.CANCEL then break end
        elseif event.channel == ticks then
            if pending ~= "" then
                pending_ticks = pending_ticks + 1
                if pending_ticks >= 5 then pending = ""; status = "Stop result timed out; refresh before retrying"; dirty = true end
            end
            if not paused then sample() end
        elseif event.channel == states then
            local msg = event.value
            if broker and msg:from() == broker then
                local prefs = appearance.decode(msg:payload():data())
                if prefs then preferences = prefs; dirty = true end
            end
        elseif event.channel == replies then
            local msg = event.value
            if broker and msg:from() == broker then
                local data: unknown = msg:payload():data()
                if type(data) == "table" and data.version == 1 and pending ~= "" and data.request_id == pending and type(data.error) == "string" then
                    status = data.error ~= "" and data.error or "Application ended"
                    pending = ""; sample()
                end
            end
        else
            local data = event.value
            if data.type == "close" then running = false
            elseif data.type == "resize" then width, height = data.width, data.height; dirty = true
            elseif data.type == "key" and data.action ~= "release" then
                local key = data.key_type
                if confirming then
                    if key == "enter" and broker then
                        pending = uuid.v7(); pending_ticks = 0
                        process.send(broker, "bee.application.control", {version = 1, request_id = pending, op = "stop", execution_pid = selected})
                        confirming = false; status = "Stopping application…"; dirty = true
                    elseif key == "esc" or key == "escape" then confirming = false; dirty = true end
                elseif key == "tab" then
                    services = not services; selected = ""; offset = 0; status = ""; order(); dirty = true
                elseif key == "up" then move(-1)
                elseif key == "down" then move(1)
                elseif key == "pgup" then move(-math.floor(math.max(1, capacity)))
                elseif key == "pgdown" then move(math.floor(math.max(1, capacity)))
                elseif key == "home" then move(-#rows)
                elseif key == "end" then move(#rows)
                elseif data.key == "s" then by_steps = not by_steps; order(); reveal(); dirty = true
                elseif data.key == " " or data.key == "p" then toggle_pause()
                elseif key == "delete" or key == "del" then end_app()
                elseif key == "esc" or key == "escape" then running = false end
            elseif data.type == "mouse" then
                local x, y = math.floor(tonumber(data.x) or 1), math.floor(tonumber(data.y) or 1)
                if data.action == "wheel" then move((data.button == "wheel_up" or data.button == "up") and -1 or 1)
                elseif data.action == "press" and data.button == "left" then
                    if y == 1 and x >= width - 10 and width >= 38 then toggle_pause()
                    elseif y == 1 and x <= 24 then
                        if width < 26 then services = not services else services = x >= 14 end
                        selected = ""; offset = 0; status = ""; confirming = false; order(); dirty = true
                    elseif y == height and not confirming then
                        if x < width - 11 then by_steps = not by_steps; order(); reveal(); dirty = true else end_app() end
                    elseif y >= first and y < first + capacity then
                        local item = rows[offset + y - first + 1]
                        if item then selected = item.pid; confirming = false; status = ""; dirty = true end
                    end
                end
            end
        end
    end
    ticker:stop()
    process.unlisten(states); process.unlisten(replies)
    output:close(); tty.stop()
end
return {main = main}
