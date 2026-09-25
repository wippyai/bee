-- MIT. The Tally application a managed agent authors from SPEC.md.
local tty = require("tty")
local client = require("client")
local process = require("process")
local channel = require("channel")
local json = require("json")
local appearance = require("appearance")
local frame = require("frame")
local funcs = require("funcs")

local HINTS = frame.hints({{key = "Enter", verb = "add one"}, {key = "r", verb = "reset"}, {key = "Esc", verb = "exit"}})

local function main(value: unknown)
    local launch = client.launch(value)
    if not launch then error("Invalid launch") end
    local owned, read_error = funcs.call("bee.threads.service:list", {limit = 1})
    if read_error or not owned or owned.ok ~= true then error("Owned thread read grant is unavailable") end
    local input = assert(tty.events())
    local lifecycle = assert(process.events())
    local receipts = assert(process.listen("bee.application.checkpoint_result", {message = true}))
    local states = assert(process.listen("bee.appearance.state", {message = true}))
    local count = 0
    if launch.resume_state ~= "" then
        local state: unknown = json.decode(launch.resume_state)
        if type(state) ~= "table" or type(state.tally) ~= "number"
            or state.tally ~= math.floor(state.tally) or state.tally < 0 then
            error("Invalid tally checkpoint")
        end
        count = math.floor(state.tally)
    end
    assert(tty.start())
    assert(tty.mouse(true))
    local output = assert(tty.surface())
    local width, height = tty.screen_size()
    local preferences = appearance.defaults()
    local saved: integer? = nil
    local pending_request_id: string? = nil
    local pending_count: integer? = nil
    local status = "Ready"
    local running = true
    local hits: {frame.Hit} = {}

    -- One frame: header, work rows, the action bar and the status footer.
    -- Every row is bounded to the canvas; hits come from what was drawn.
    local function paint()
        local painter = frame.new(width, height, preferences)
        local theme = painter.theme
        frame.header(painter, "TALLY", height < 4 and ("Tally: " .. tostring(count)) or nil)
        if height >= 6 then
            frame.line(painter, 2, "WORK", theme.muted)
            frame.line(painter, 3, "Tally: " .. tostring(count), theme.text)
            frame.line(painter, 4, saved == nil and "Saved: —" or ("Saved: " .. tostring(saved)), theme.muted)
        elseif height >= 4 then
            frame.line(painter, 2, "Tally: " .. tostring(count), theme.text)
        end
        if height >= 3 then
            frame.actions(painter, height - 1, {
                {kind = "increment", key = "Enter", label = width >= 30 and "Add one" or "+1", enabled = true, primary = true},
                {kind = "reset", key = "r", label = "Reset", enabled = true},
                {kind = "exit", key = "Esc", label = "Exit", enabled = true},
            })
        end
        if height >= 2 then frame.footer(painter, "Status: " .. status, HINTS) end
        hits = painter.hits
        assert(output:present(frame.rows(painter)))
    end

    local function checkpoint()
        local request_id = client.checkpoint(launch, json.encode({tally = count}))
        if request_id then
            pending_request_id, pending_count = request_id, count
            status = "Saving tally " .. tostring(count)
        else
            pending_request_id, pending_count = nil, nil
            status = "Save unavailable"
        end
        paint()
    end

    local function increment()
        count = count + 1
        checkpoint()
    end

    local function reset()
        count = 0
        checkpoint()
    end

    local appearance_request_id = launch.instance_id
    assert(process.send(launch.broker_pid, "bee.appearance.request", {version = 1,
        request_id = appearance_request_id, op = "state"}))
    paint()
    client.ready(launch)
    checkpoint()
    while running do
        local event = channel.select({input:case_receive(), lifecycle:case_receive(), receipts:case_receive(), states:case_receive()})
        if not event.ok then break end
        if event.channel == lifecycle then
            if event.value.kind == process.event.CANCEL then running = false end
        elseif event.channel == states then
            local message = event.value
            local data: unknown = message:payload():data()
            if message:from() == launch.broker_pid and type(data) == "table" and data.version == 1 then
                local next_preferences = appearance.decode(data)
                if next_preferences then preferences = next_preferences; paint() end
            end
        elseif event.channel == receipts then
            local message = event.value
            local data: unknown = message:payload():data()
            if message:from() == launch.broker_pid and type(data) == "table" and data.version == 1
                and type(data.request_id) == "string" and data.request_id == pending_request_id then
                local submitted = pending_count
                pending_request_id, pending_count = nil, nil
                if data.error_code == "" and submitted ~= nil then
                    saved = submitted
                    status = "Saved tally " .. tostring(submitted)
                elseif data.error_code == "superseded" then
                    status = "Save superseded"
                else
                    status = "Save failed"
                end
                paint()
            end
        else
            local data = event.value
            if data.type == "close" then running = false
            elseif data.type == "resize" then width, height = data.width, data.height; paint()
            elseif data.type == "key" and data.action == "press" then
                if data.key_type == "enter" then increment()
                elseif data.key == "r" then reset()
                elseif data.key_type == "escape" or data.key_type == "esc" then running = false end
            elseif data.type == "mouse" and data.action == "press" and data.button == "left" then
                local hit = frame.hit(hits, math.floor(tonumber(data.x) or 0), math.floor(tonumber(data.y) or 0))
                if hit and hit.kind == "increment" then increment()
                elseif hit and hit.kind == "reset" then reset()
                elseif hit and hit.kind == "exit" then running = false end
            end
        end
    end
    process.unlisten(states); process.unlisten(receipts)
    output:close(); tty.mouse(false); tty.stop()
end
return {main = main}
