local history_values = require("history_values")
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
local frame = require("frame")
local clock = require("clock")
local stop_request = require("stop_request")
local function main(value: unknown)
    local launch = client.launch(value)
    if not launch then error("Invalid application launch") end
    local broker = launch.broker_pid
    local announced = false
    local input = assert(tty.events())
    local menu = frame.menu()
    local lifecycle = assert(process.events())
    local states = assert(process.listen("bee.appearance.state", {message = true}))
    local replies = assert(process.listen("bee.app.result", {message = true}))
    assert(tty.start())
    local output = assert(tty.surface())
    local ticker = assert(time.ticker("1s"))
    local ticks = ticker:channel()
    local width, height = tty.screen_size()
    local preferences = appearance.defaults()
    local history = history_values.new_history()
    local snapshot = probe.sample()
    local last_time = time.now():unix_nano()
    history_values.append(history, snapshot, nil, 0)
    local selected = ""
    local offset, capacity = 0, 0
    local hits: {frame.Hit} = {}
    local paused, confirming, by_steps, services = false, false, false, false
    local rows: {view.Row} = {}
    local status = ""
    local pending: stop_request.Pending? = nil
    local running, dirty = true, true
    local function order()
        rows = view.items(snapshot, services)
        table.sort(rows, function(a, b)
            if by_steps and a.steps ~= b.steps then return (a.steps or -1) > (b.steps or -1) end
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
        history_values.append(history, next_snapshot, snapshot, clock.elapsed_seconds(now, last_time))
        snapshot, last_time = next_snapshot, now
        order(); reveal(); dirty = true
    end
    local function toggle_pause()
        paused = not paused
        -- A resumed series starts a fresh rate interval, rather than pretending
        -- a paused minute was a one-second sample.
        if not paused then
            snapshot = probe.sample(); last_time = time.now():unix_nano()
            history_values.append(history, snapshot, nil, 0); order(); reveal()
        end
        dirty = true
    end
    local function end_app()
        if not services and broker and selected ~= "" and pending == nil then confirming = true; dirty = true end
    end
    order()
    if broker then process.send(broker, "bee.appearance.request", {version = 1, request_id = uuid.v7(), op = "state"}) end
    while running do
        if dirty then
            local drawn = view.draw(width, height, snapshot, history, preferences, selected, offset, paused, status, confirming, services, rows, by_steps)
            frame.render(drawn, menu, preferences)
            hits, capacity, offset = drawn.hits, drawn.capacity, drawn.offset
            assert(output:present(drawn.rows, {cursor = {x = 1, y = 1, visible = false}}))
            if not announced then client.ready(launch); announced = true end
            dirty = false
        end
        local event = channel.select({input:case_receive(), lifecycle:case_receive(), ticks:case_receive(), states:case_receive(), replies:case_receive()})
        if not event.ok then break end
        if event.channel == lifecycle then
            if event.value.kind == process.event.CANCEL then break end
        elseif event.channel == ticks then
            if pending then
                local next_pending, timeout = stop_request.tick(pending)
                pending = next_pending
                if timeout then status = timeout; dirty = true end
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
                if type(data) == "table" and data.version == 1 and stop_request.matches(pending, data.request_id) and type(data.error) == "string" then
                    status = data.error ~= "" and data.error or "Application ended"
                    pending = nil; sample()
                end
            end
        else
            local data, handled = frame.route(menu, event.value, false)
            if handled then dirty = true end
            if data then
                if data.type == "close" then running = false
                elseif data.type == "resize" then width, height = data.width, data.height; dirty = true
                elseif data.type == "key" and data.action ~= "release" then
                    local key = data.key_type
                    if confirming then
                        if key == "enter" and broker then
                            local request_id = uuid.v7()
                            pending = stop_request.begin(request_id)
                            local sent, send_error = process.send(broker, "bee.app.control", {version = 1, request_id = request_id, op = "stop", execution_pid = selected})
                            confirming = false
                            if sent and not send_error then status = "Stopping application…"
                            else pending = nil; status = "Stop request failed: " .. tostring(send_error) end
                            dirty = true
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
                        local hit = frame.hit(hits, x, y)
                        local kind = hit and hit.kind or ""
                        if kind == "pause" then toggle_pause()
                        elseif kind == "processes" or kind == "services" then
                            services = kind == "services"
                            selected = ""; offset = 0; status = ""; confirming = false; order(); dirty = true
                        elseif kind == "sort" and not confirming then by_steps = not by_steps; order(); reveal(); dirty = true
                        elseif kind == "stop" and not confirming then end_app()
                        elseif hit and kind == "row" then
                            selected = hit.key; confirming = false; status = ""; dirty = true
                        end
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
