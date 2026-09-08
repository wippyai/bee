-- MIT. A view of durable test events. Closing it never cancels the run process.
local tty = require("tty")
local process = require("process")
local channel = require("channel")
local time = require("time")
local uuid = require("uuid")
local json = require("json")
local contract = require("contract")
local client = require("client")
local journal = require("journal")
local protocol = require("protocol")
local appearance = require("appearance")
local view = require("view")
local function main(value: unknown)
    local launch = client.launch(value)
    if not launch then error("Invalid application launch") end
    local thread = launch.arguments[1] or "desktop-checks"
    local initial_run = launch.arguments[2]
    if #launch.arguments > 2 or not protocol.id(thread) or (initial_run and not protocol.id(initial_run)) then error("Expected thread and optional run ID") end
    if #launch.arguments == 0 and launch.resume_state ~= "" then
        local restored: unknown = json.decode(launch.resume_state)
        if type(restored) ~= "table" then error("Invalid test-status checkpoint") end
        local saved = protocol.id(restored.thread)
        if not saved then error("Invalid restored thread") end
        thread = saved
    end
    local log, open_error = journal.open(thread)
    if not log then error(open_error or "Journal unavailable") end
    local runner, runner_error = contract.open("bee.test_status:local_runner")
    if not runner then error(tostring(runner_error)) end
    local input = assert(tty.events())
    local lifecycle = assert(process.events())
    local states = assert(process.listen("bee.appearance.state", {message = true}))
    local ticker = assert(time.ticker("300ms"))
    local ticks = ticker:channel()
    assert(tty.start())
    local output = assert(tty.surface())
    local width, height = tty.screen_size()
    local preferences = appearance.defaults()
    local cursor, offset = 0, 0
    local lines: {string} = {}
    local status = "No recorded run · choose Run checks"
    local last_recorded = ""
    local follow = true
    local function clean(text: string): string return text:gsub("%c", " ") end
    local function draw()
        local frame = view.render(width, height, preferences, thread, cursor, status, lines, offset, follow)
        offset = frame.offset
        assert(output:present(frame.rows, {cursor = {x = 1, y = 1, visible = false}}))
    end
    local function start(run: string)
        local raw, err = runner:start({thread = thread, run = run})
        if err then status = tostring(err)
        elseif type(raw) ~= "table" or type(raw.ok) ~= "boolean" or type(raw.error) ~= "string" then status = "Invalid run response"
        elseif raw.ok then status = raw.created == true and "Queued · work continues if this view closes" or "Existing run · replaying recorded events"
        else status = raw.error end
        follow = true
    end
    local function replay()
        cursor, offset, lines = 0, 0, {}
        follow = true
        status = "Replaying committed events"
    end
    local function catch_up(): boolean
        local reply, err = log:read_after(cursor)
        if not reply then
            local next_status = err or "Journal unavailable"
            if next_status == status then return false end
            status = next_status
            return true
        end
        if #reply.events == 0 then return false end
        for _, event in ipairs(reply.events) do
            cursor = event.seq
            local body: unknown = json.decode(event.body)
            local detail = ""
            if type(body) == "table" and type(body.name) == "string" then detail = clean(body.name) end
            local label = event.kind
            if event.kind == "test.case.passed" then label = "PASS"
            elseif event.kind == "test.case.failed" then label = "FAIL"
            elseif event.kind == "test.run.finished" and type(body) == "table" and type(body.passed) == "number" and type(body.failed) == "number" then
                detail = tostring(body.passed) .. " passed / " .. tostring(body.failed) .. " failed"
                label = "COMPLETE"
            end
            lines[#lines + 1] = tostring(event.seq) .. "  " .. event.run:sub(1, 8) .. "  " .. label .. "  " .. detail
            if #lines > 200 then table.remove(lines, 1) end
            last_recorded = label .. (detail ~= "" and (" · " .. detail) or "")
            if event.kind == "test.run.started" then client.title(launch, "Checks · started")
            elseif event.kind == "test.run.finished" then client.title(launch, "Checks · complete") end
        end
        status = "Last recorded: " .. last_recorded
        return true
    end
    draw()
    client.ready(launch)
    local checkpoint, checkpoint_error = json.encode({thread = thread})
    if not checkpoint then error(tostring(checkpoint_error)) end
    client.checkpoint(launch, checkpoint)
    process.send(launch.broker_pid, "bee.appearance.request", {version = 1, request_id = uuid.v7(), op = "state"})
    if initial_run then start(initial_run); draw() end
    while true do
        local selected = channel.select({input:case_receive(), lifecycle:case_receive(), states:case_receive(), ticks:case_receive()})
        if not selected.ok then break end
        if selected.channel == lifecycle then
            if selected.value.kind == process.event.CANCEL then break end
        elseif selected.channel == ticks then
            if catch_up() then draw() end
        elseif selected.channel == states then
            if selected.value:from() == launch.broker_pid then
                local data: unknown = selected.value:payload():data()
                if type(data) == "table" then
                    local decoded = appearance.decode(data)
                    if decoded then preferences = decoded; draw() end
                end
            end
        elseif selected.channel == input then
            local event = selected.value
            if event.type == "close" then break end
            if event.type == "resize" then width, height = event.width, event.height; draw()
            elseif event.type == "key" and event.action ~= "release" then
                if event.key == "r" then start(uuid.v7())
                elseif event.key == "g" then replay()
                elseif event.key_type == "up" then follow = false; offset = offset - 1
                elseif event.key_type == "down" then offset = offset + 1
                elseif event.key_type == "pgup" then follow = false; offset = offset - math.max(1, height - 7)
                elseif event.key_type == "pgdown" then offset = offset + math.max(1, height - 7)
                elseif event.key_type == "home" then follow = false; offset = 0
                elseif event.key_type == "end" then follow = true end
                draw()
            elseif event.type == "mouse" then
                if event.action == "press" and event.button == "left" and event.y == 3 then
                    if event.x >= 2 and event.x <= 15 then start(uuid.v7())
                    elseif event.x >= 17 and event.x <= 26 then replay() end
                elseif event.action == "wheel" then
                    if event.button == "wheel_up" or event.button == "up" then follow = false; offset = offset - 3
                    else offset = offset + 3 end
                end
                draw()
            end
        end
    end
    ticker:stop()
    process.unlisten(states)
    tty.stop()
end
return {main = main}
