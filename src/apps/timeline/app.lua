-- MIT. The timeline application: threads the caller may read, one
-- thread's records in owner order through a subscription whose cursor the
-- owner moves on this viewer's acknowledgment, the recap as stored, and a
-- bounded wait that claims nothing for the reason to page again. Viewing
-- acknowledges no delivery and settles nothing; approvals are decided in
-- Approvals. Local state is the selection, follow and the detail toggle.
local tty = require("tty")
local client = require("client")
local channel = require("channel")
local process = require("process")
local time = require("time")
local uuid = require("uuid")
local funcs = require("funcs")
local appearance = require("appearance")
local caller = require("caller")
local model = require("model")
local view = require("view")
local RETRY = "5s"
local MAX_DRAIN_PAGES = 8
type Object = {[string]: unknown}
type Channel = channel.Channel
local function key(): string
    local value, err = uuid.v4()
    if err or not value then error("allocate idempotency key") end
    return value
end
local function main(value: unknown)
    local launch = client.launch(value)
    if not launch then error("Invalid application launch") end
    local broker = launch.broker_pid
    local requested = launch.arguments[1]
    if #launch.arguments > 1 then error("Expected an optional thread id") end
    local input = assert(tty.events())
    local lifecycle = assert(process.events())
    local states = assert(process.listen("bee.appearance.state", {message = true}))
    assert(tty.start())
    local output = assert(tty.surface())
    local width, height = tty.screen_size()
    local preferences = appearance.defaults()
    local owner = caller.new(function(target: string, request: unknown): (unknown, string?)
        return funcs.new():call(target, request)
    end)
    local state: model.State = model.new("bee.timeline." .. launch.instance_id)
    if launch.resume_state ~= "" and not model.restore(state, launch.resume_state) then error("Invalid timeline checkpoint") end
    if requested then
        if type(requested) ~= "string" or requested == "" or #requested > 200 or requested:find("%c") then error("Invalid thread id") end
        model.open(state, requested, nil)
    end
    local offset = 0
    local hits: {view.Hit} = {}
    local status = ""
    local announced = false
    local last_checkpoint = ""
    local running, dirty = true, true
    local waiting: funcs.Future? = nil
    local wait_channel: Channel<unknown>? = nil
    local ticker = assert(time.ticker(RETRY))
    local ticks = ticker:channel()
    local function ask(intent: model.Intent): caller.Reply
        local reply = owner:invoke(intent.target, intent.request)
        if not reply then model.lost(state); return caller.unknown() end
        return reply
    end
    local function list()
        state.picker.next_after = nil
        local intent = model.list_intent(state)
        model.apply_list(state, ask(intent))
        dirty = true
    end
    local function more()
        if not state.picker.next_after then return end
        model.apply_list(state, ask(model.list_intent(state)))
        dirty = true
    end
    local function cancel_wait()
        if waiting then waiting:cancel() end
        waiting = nil
        wait_channel = nil
    end
    -- Page until the owner reports nothing more, acknowledging each page
    -- after it is folded in; bounded per turn so the frame stays live.
    local function drain()
        local pages = 0
        local more_pages = true
        while more_pages and pages < MAX_DRAIN_PAGES and state.phase == "attached" do
            local intent = model.page_intent(state)
            if not intent then break end
            more_pages = model.apply_page(state, ask(intent))
            local acknowledgment = model.ack_intent(state, key())
            if acknowledgment then model.apply_ack(state, ask(acknowledgment)) end
            pages = pages + 1
        end
        dirty = true
    end
    local function arm_wait()
        cancel_wait()
        local intent = model.watch_intent(state)
        if not intent then return end
        local future, err = funcs.new():async(intent.target, intent.request)
        if not future or err then model.apply_watch(state, caller.unknown()); return end
        waiting = future
        wait_channel = future:response()
    end
    local function attach()
        if not state.thread_id then return end
        model.retry(state)
        if state.phase ~= "attaching" then return end
        model.apply_get(state, ask(assert(model.get_intent(state))))
        local intent = model.attach_intent(state, key())
        if not intent then return end
        model.apply_attach(state, ask(intent))
        if state.phase == "attaching" then
            local again = model.attach_intent(state, key())
            if again then model.apply_attach(state, ask(again)) end
        end
        model.apply_recap(state, ask(assert(model.recap_intent(state))))
        drain()
        arm_wait()
    end
    local function open_picked()
        local picked = model.picked(state)
        if not picked then status = "Choose a thread first"; dirty = true; return end
        model.open(state, picked.thread_id, nil)
        attach()
    end
    local function back()
        cancel_wait()
        local leaving = model.unsubscribe_intent(state, key())
        if leaving then owner:invoke(leaving.target, leaving.request) end
        model.close_thread(state)
        list()
    end
    if broker then process.send(broker, "bee.appearance.request", {version = 1, request_id = uuid.v7(), op = "state"}) end
    if state.thread_id then attach() else list() end
    while running do
        if dirty then
            local frame = view.draw(width, height, preferences, state, offset, status)
            hits = frame.hits
            offset = frame.offset
            assert(output:present(frame.rows, {cursor = {x = 1, y = 1, visible = false}}))
            if not announced then client.ready(launch); announced = true end
            local checkpoint = model.checkpoint(state)
            if checkpoint ~= last_checkpoint then
                local sent = client.checkpoint(launch, checkpoint)
                if sent then last_checkpoint = checkpoint end
            end
            dirty = false
        end
        local cases = {input:case_receive(), lifecycle:case_receive(), states:case_receive(), ticks:case_receive()}
        if wait_channel then cases[#cases + 1] = wait_channel:case_receive() end
        local event = channel.select(cases)
        if not event.ok then break end
        if event.channel == lifecycle then
            if event.value.kind == process.event.CANCEL then running = false end
        elseif wait_channel and event.channel == wait_channel then
            local future = waiting
            waiting = nil
            wait_channel = nil
            if future then
                local result, err = future:result()
                if err or not result then model.apply_watch(state, caller.unknown())
                else model.apply_watch(state, caller.decode(result:data()) or caller.unknown()) end
            end
            if state.phase == "attached" then drain(); arm_wait() end
            dirty = true
        elseif event.channel == ticks then
            if state.thread_id and state.phase ~= "attached" then attach()
            elseif state.thread_id and state.session and state.session.state == "detached" then model.reconnect(state); drain(); arm_wait() end
        elseif event.channel == states then
            local message = event.value
            if broker and message:from() == broker then
                local payload: unknown = message:payload():data()
                local next_preferences = appearance.decode(payload)
                if next_preferences and type(payload) == "table" and payload.version == 1 then preferences = next_preferences; dirty = true end
            end
        else
            local data = event.value
            if data.type == "close" then running = false
            elseif data.type == "resize" then width, height = data.width, data.height; dirty = true
            elseif data.type == "key" and data.action ~= "release" then
                local pressed = data.key_type
                local letter = tostring(data.key or "")
                status = ""
                if pressed == "up" or letter == "k" then model.move(state, -1); dirty = true
                elseif pressed == "down" or letter == "j" then model.move(state, 1); dirty = true
                elseif pressed == "pgup" then model.move(state, -8); dirty = true
                elseif pressed == "pgdown" then model.move(state, 8); dirty = true
                elseif pressed == "enter" then
                    if state.phase == "picking" then open_picked() else model.toggle_technical(state); dirty = true end
                elseif letter == "f" and state.phase ~= "picking" then model.toggle_follow(state); dirty = true
                elseif letter == "m" and state.phase == "picking" then more()
                elseif letter == "b" and state.phase ~= "picking" then back()
                elseif letter == "r" then
                    if state.phase == "picking" then list() else attach(); if state.phase == "attached" then drain(); arm_wait() end end
                elseif letter == "t" then model.toggle_technical(state); dirty = true
                elseif pressed == "esc" or pressed == "escape" then running = false end
            elseif data.type == "mouse" and data.action == "press" and data.button == "left" then
                local hit = view.hit(hits, math.floor(tonumber(data.x) or 1), math.floor(tonumber(data.y) or 1))
                if hit then
                    status = ""
                    if hit.kind == "thread" then model.pick(state, hit.key); dirty = true
                    elseif hit.kind == "row" then model.select(state, math.floor(tonumber(hit.key) or 0)); dirty = true
                    elseif hit.kind == "open" then open_picked()
                    elseif hit.kind == "more" then more()
                    elseif hit.kind == "follow" then model.toggle_follow(state); dirty = true
                    elseif hit.kind == "threads" then back()
                    elseif hit.kind == "refresh" then
                        if state.phase == "picking" then list() else attach(); if state.phase == "attached" then drain(); arm_wait() end end
                    elseif hit.kind == "technical" then model.toggle_technical(state); dirty = true end
                end
            elseif data.type == "mouse" and data.action == "wheel" then
                model.move(state, (data.button == "wheel_up" or data.button == "up") and -1 or 1); dirty = true
            end
        end
    end
    cancel_wait()
    ticker:stop()
    process.unlisten(states)
    output:close()
    tty.stop()
end
return {main = main}
