-- MIT. Process Manager: an on-demand observer of this node's runtime and of
-- the hive. It samples processes, services and memory each second while
-- live, and on the Hive pane each node's numbers from its owner; nothing is
-- sampled while it is closed. Stopping an app asks the node, which owns the
-- apps.
local history_values = require("history_values")
local tty = require("tty")
local client = require("client")
local process = require("process")
local channel = require("channel")
local system = require("system")
local time = require("time")
local appearance = require("appearance")
local probe = require("probe")
local view = require("view")
local frame = require("frame")
local clock = require("clock")
local hive = require("hive")
local application = require("application")
local confirmation = require("confirmation")

-- A finished job: a stop's problem, or one round of hive samples.
type Result = {problem: string?, samples: {hive.Sample}?}

-- sample_hive asks every node of the hive that serves desktops for its stats.
local function sample_hive(): Result
    local samples: {hive.Sample} = {}
    for _, node in ipairs(client.nodes()) do
        local value, problem = client.call(node, "stats", {})
        samples[#samples + 1] = hive.decode(node, value, problem)
    end
    return {samples = samples}
end

local function stop_app(node: string, instance_id: string, execution_id: string?): Result
    local _, err = client.call(node, "close", {id = instance_id, execution_id = execution_id})
    return {problem = err and ("Stop failed: " .. err) or nil}
end

local function main(value: unknown)
    local node = assert(system.node.id())
    local launch = assert(application.launch(value))
    local review = confirmation.new({workspace_id = launch.workspace_id, origin = {app_id = launch.definition_id, instance_id = launch.instance_id, attempt_id = launch.execution_id}})
    local input = assert(tty.events())
    local menu = frame.menu()
    local lifecycle = assert(process.events())
    local changes = assert(process.listen(appearance.TOPIC, {message = true}))
    local results = channel.new(4)
    assert(tty.start())
    local output = assert(tty.surface())
    local ticker = assert(time.ticker("1s"))
    local ticks = ticker:channel()
    local width, height = tty.screen_size()
    local preferences = appearance.chosen(value)
    local history = history_values.new_history()
    local snapshot = probe.sample()
    local last_time = time.now():unix_nano()
    history_values.append(history, snapshot, nil, 0)
    local selected = ""
    local offset, capacity = 0, 0
    local hits: {frame.Hit} = {}
    local paused, by_steps, services = false, false, false
    -- mode is the pane shown: processes, services or hive.
    local mode = "processes"
    local hive_state = hive.new(node)
    local hive_selected = ""
    local hive_sampling = false
    local function hive_round()
        if hive_sampling then return end
        hive_sampling = true
        coroutine.spawn(function() results:send(sample_hive()) end)
    end
    local function set_mode(next_mode: string)
        mode = next_mode
        services = mode == "services"
        selected = ""; offset = 0; status = ""; confirmation.cancel(review)
        if mode == "hive" then hive_round() end
    end
    local rows: {view.Row} = {}
    local status = ""
    local stopping = false
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
        if not found then selected = rows[1] and rows[1].pid or ""; confirmation.cancel(review) end
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
    local function move_hive(step: integer)
        local listed = hive.nodes(hive_state)
        local index = 1
        for i, item in ipairs(listed) do if item.node == hive_selected then index = i end end
        index = math.floor(math.max(1, math.min(#listed, index + step)))
        if listed[index] then hive_selected = listed[index].node end
        dirty = true
    end
    local function move(step: integer)
        if mode == "hive" then move_hive(step); return end
        local index = 1
        for i, item in ipairs(rows) do if item.pid == selected then index = i end end
        index = math.floor(math.max(1, math.min(#rows, index + step)))
        if rows[index] then selected = rows[index].pid end
        confirmation.cancel(review); status = ""; reveal(); dirty = true
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
    local function stop_target(): {[string]: unknown}?
        local listed, err = client.call(node, "list", {})
        local state = listed and client.state(listed)
        if not state then status = err or "Application list is unavailable"; return nil end
        for _, instance in ipairs(state.running) do
            if instance.pid == selected then return {node = node, instance_id = instance.id, execution_id = instance.execution_id, definition_id = instance.app} end
        end
        status = "Only apps can be stopped"
        return nil
    end
    local function end_app()
        if not services and selected ~= "" and not stopping then
            local target = stop_target()
            if target then
                local opened, err = confirmation.open(review, "app.stop", target, "inline", "Stop selected app?", "Stop selected app?")
                if not opened then status = err or "Confirmation is unavailable" end
            end
            dirty = true
        end
    end
    order()
    while running do
        if dirty then
            local drawn = mode == "hive"
                and view.draw_hive(width, height, hive.nodes(hive_state), preferences, hive_selected, offset, paused, status)
                or view.draw(width, height, snapshot, history, preferences, selected, offset, paused, status, confirmation.active(review), services, rows, by_steps)
            frame.render(drawn, menu, preferences)
            hits, capacity, offset = drawn.hits, drawn.capacity, drawn.offset
            assert(output:present(drawn.rows, {cursor = {x = 1, y = 1, visible = false}}))
            dirty = false
        end
        local event = channel.select({input:case_receive(), lifecycle:case_receive(), ticks:case_receive(), changes:case_receive(),
            results:case_receive()})
        if not event.ok then break end
        if event.channel == lifecycle then
            if event.value.kind == process.event.CANCEL then break end
        elseif event.channel == ticks then
            if not paused then
                if mode == "hive" then hive_round() else sample() end
            end
        elseif event.channel == changes then
            preferences = appearance.chosen(event.value:payload():data())
            dirty = true
        elseif event.channel == results then
            local result = event.value :: Result
            if result.samples then
                hive_sampling = false
                hive.record(hive_state, result.samples)
                if hive_selected == "" then hive_selected = node end
                dirty = true
            else
                stopping = false
                status = result.problem or "Application ended"
                sample()
            end
        else
            local data, handled = frame.route(menu, event.value, false)
            if handled then dirty = true end
            if data then
                if data.type == "close" then running = false
                elseif data.type == "resize" then width, height = data.width, data.height; dirty = true
                elseif data.type == "key" and data.action ~= "release" then
                    local key = data.key_type
                    if confirmation.active(review) then
                        if key == "enter" then
                            local target = stop_target()
                            if target then
                                local accepted, err = confirmation.accept(review, target, "enter")
                                if accepted then
                                    local instance_id = tostring(target.instance_id)
                                    local execution_id = type(target.execution_id) == "string" and target.execution_id or nil
                                    stopping = true
                                    status = "Stopping application…"
                                    coroutine.spawn(function() results:send(stop_app(node, instance_id, execution_id)) end)
                                else status = err or "Target changed; review it again" end
                            end
                            dirty = true
                        elseif key == "esc" or key == "escape" then confirmation.cancel(review); dirty = true end
                    elseif key == "tab" then
                        set_mode(mode == "processes" and "services" or (mode == "services" and "hive" or "processes"))
                        order(); dirty = true
                    elseif key == "up" then move(-1)
                    elseif key == "down" then move(1)
                    elseif key == "pgup" then move(-math.floor(math.max(1, capacity)))
                    elseif key == "pgdown" then move(math.floor(math.max(1, capacity)))
                    elseif key == "home" then move(-#rows)
                    elseif key == "end" then move(#rows)
                    elseif data.key == "s" and mode ~= "hive" then by_steps = not by_steps; order(); reveal(); dirty = true
                    elseif data.key == " " or data.key == "p" then toggle_pause()
                    elseif (key == "delete" or key == "del") and mode == "processes" then end_app()
                    elseif key == "esc" or key == "escape" then running = false end
                elseif data.type == "mouse" then
                    local x, y = math.floor(tonumber(data.x) or 1), math.floor(tonumber(data.y) or 1)
                    if data.action == "wheel" then move((data.button == "wheel_up" or data.button == "up") and -1 or 1)
                    elseif data.action == "press" and data.button == "left" then
                        local hit = frame.hit(hits, x, y)
                        local kind = hit and hit.kind or ""
                        if kind == "pause" then toggle_pause()
                        elseif kind == "processes" or kind == "services" or kind == "hive" then
                            set_mode(kind); order(); dirty = true
                        elseif kind == "sort" and not confirmation.active(review) then by_steps = not by_steps; order(); reveal(); dirty = true
                        elseif kind == "stop" and not confirmation.active(review) then end_app()
                        elseif hit and kind == "row" then
                            if mode == "hive" then hive_selected = hit.key
                            else selected = hit.key; confirmation.cancel(review); status = "" end
                            dirty = true
                        end
                    end
                end
            end
        end
    end
    confirmation.cancel(review)
    ticker:stop()
    process.unlisten(changes)
    output:close(); tty.stop()
end
return {main = main}
