-- Reference dashboard: live runtime statistics drawn with the application
-- frame and the visualization kit. It samples once per second while it is
-- open and owns no data or control authority.
local tty = require("tty")
local process = require("process")
local channel = require("channel")
local time = require("time")
local uuid = require("uuid")
local client = require("client")
local appearance = require("appearance")
local frame = require("frame")
local probe = require("probe")
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
    local ticker = assert(time.ticker("1s"))
    local ticks = ticker:channel()
    local width, height = tty.screen_size()
    local preferences = appearance.defaults()
    local history = probe.new_history()
    local snapshot = probe.sample()
    local last_time = time.now():unix_nano()
    probe.append(history, snapshot, nil, 0)
    local hits: {frame.Hit} = {}
    local paused = false
    local running, dirty, ready = true, true, false

    -- One sample per tick; the rate spans the real elapsed time.
    local function sample(continuous: boolean)
        local now = time.now():unix_nano()
        local next_snapshot = probe.sample()
        probe.append(history, next_snapshot, continuous and snapshot or nil, (now - last_time) / 1000000000)
        snapshot = next_snapshot
        last_time = now
        dirty = true
    end
    local function toggle_pause()
        paused = not paused
        -- A resumed series starts a fresh rate interval.
        if not paused then sample(false) end
        dirty = true
    end

    if broker then
        process.send(broker, "bee.appearance.request", {version = 1, request_id = uuid.v7(), op = "state"})
    end
    while running do
        if dirty then
            local drawn = view.draw(width, height, preferences, snapshot, history, paused)
            hits = drawn.hits
            assert(output:present(drawn.rows, {cursor = {x = 1, y = 1, visible = false}}))
            if not ready then client.ready(launch); ready = true end
            dirty = false
        end
        local event = channel.select({input:case_receive(), lifecycle:case_receive(), ticks:case_receive(), states:case_receive()})
        if not event.ok then break end
        if event.channel == lifecycle then
            if event.value.kind == process.event.CANCEL then running = false end
        elseif event.channel == ticks then
            if not paused then sample(true) end
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
                if data.key == "p" or data.key == " " then toggle_pause()
                elseif data.key == "r" or key == "enter" then sample(not paused)
                elseif key == "esc" or key == "escape" then running = false end
            elseif data.type == "mouse" and data.action == "press" and data.button == "left" then
                local hit = frame.hit(hits, math.floor(tonumber(data.x) or 1), math.floor(tonumber(data.y) or 1))
                if hit and hit.kind == "pause" then toggle_pause()
                elseif hit and hit.kind == "refresh" then sample(not paused) end
            end
        end
    end
    ticker:stop()
    process.unlisten(states)
    output:close()
    tty.stop()
end

return {main = main}
