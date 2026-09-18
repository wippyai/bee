-- MIT. Workspace-local application delivery review and activation status.
-- Human approval decisions stay in the existing Approvals application.
local tty = require("tty")
local client = require("client")
local process = require("process")
local channel = require("channel")
local uuid = require("uuid")
local funcs = require("funcs")
local appearance = require("appearance")
local caller = require("caller")
local model = require("model")
local view = require("view")

local function new_key(): string
    local value, err = uuid.v4()
    if err or not value then error("allocate delivery idempotency key") end
    return value
end
local function main(value: unknown)
    local launch = client.launch(value)
    if not launch then error("Invalid application launch") end
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
    local state: model.State = model.new(launch.workspace_id)
    if launch.resume_state ~= "" and not model.restore(state, launch.resume_state) then error("Invalid App Delivery checkpoint") end
    local offset = 0
    local dirty, running, announced = true, true, false
    local last_checkpoint = ""
    local function invoke(request: unknown): caller.Reply?
        return owner:invoke(model.CALL, request)
    end
    local function refresh()
        state.notice = ""
        local available_ok = model.apply_available(state, invoke(model.available_request(state)))
        local available_notice = available_ok and "" or state.notice
        local plans_ok = model.apply_list(state, invoke(model.list_request(state)))
        local plans_notice = plans_ok and "" or state.notice
        if not available_ok and not plans_ok then state.notice = available_notice .. "; " .. plans_notice
        elseif not available_ok then state.notice = available_notice
        elseif not plans_ok then state.notice = plans_notice
        elseif #state.available == 0 and #state.plans == 0 then state.notice = "No versions available or staged in this workspace"
        else state.notice = "" end
        dirty = true
    end
    local function stage_available()
        local item = model.selected_available(state)
        if not item then state.notice = "Choose an available version first"; dirty = true; return end
        for _, staged in ipairs(state.plans) do
            if model.key(staged) == model.available_plan_key(item) then
                model.select(state, model.key(staged))
                state.pane = "plans"
                state.notice = "This version is already staged for local review"
                dirty = true
                return
            end
        end
        local pending = state.pending_stage
        local selected_key = model.available_key(item)
        if pending and pending.available_key ~= selected_key then
            state.notice = "A previous stage has no reply; select that version and retry its same request"
            dirty = true
            return
        end
        if not pending then
            pending = {available_key = selected_key, idempotency_key = new_key()}
            state.pending_stage = pending
        end
        local reply = invoke(model.stage_request(state, item, pending.idempotency_key))
        local applied = model.apply_stage(state, reply, item)
        if reply and (applied or not reply.ok) then state.pending_stage = nil end
        if applied then refresh(); state.notice = "Staged for local review; no installation performed" end
        dirty = true
    end
    local function get_selected()
        local item = model.selected(state)
        if not item then state.notice = "Choose a staged version first"; dirty = true; return end
        if model.apply_plan(state, invoke(model.get_request(state, item))) then
            model.apply_changes(state, invoke(model.changes_request(state, item)), item)
            state.pane = "review"
            offset = 0
        end
        dirty = true
    end
    local function review(accepted: boolean)
        local item = model.selected(state)
        local refused = accepted and model.refusal(state, item) or nil
        if refused then state.notice = refused; dirty = true; return end
        if not model.accepts_review(item) or not item then
            state.notice = "Only a staged version can receive a local review"; dirty = true; return
        end
        model.apply_plan(state, invoke(model.review_request(state, item, accepted, new_key())))
        dirty = true
    end
    local function select_version()
        local item = model.selected(state)
        local refused = model.refusal(state, item)
        if refused then state.notice = refused; dirty = true; return end
        if not model.can_select(item) or not item then
            state.notice = "Record an accepted local review before selecting this version"; dirty = true; return
        end
        model.apply_plan(state, invoke(model.select_request(state, item, new_key())))
        dirty = true
    end
    local function prepare()
        local item = model.selected(state)
        local refused = model.refusal(state, item)
        if refused then state.notice = refused; dirty = true; return end
        if not model.can_prepare(state, item) or not item then
            state.notice = "Select an accepted version before preparing activation"; dirty = true; return
        end
        local pending = state.pending_prepare
        if pending and pending.plan_key ~= model.key(item) then
            state.notice = "A previous prepare has no reply; select that version and retry its same request"; dirty = true; return
        end
        if not pending then
            pending = {plan_key = model.key(item), intent_id = new_key(), receipt_key = new_key()}
            model.set_pending_prepare(state, item, pending.intent_id, pending.receipt_key)
        end
        local reply = invoke(model.prepare_request(state, item, pending.intent_id, pending.receipt_key))
        local applied = model.apply_activation(state, reply)
        if reply and (applied or not reply.ok) then state.pending_prepare = nil end
        dirty = true
    end
    local function step()
        local intent_id = state.intent and state.intent.intent_id or state.restored_intent_id
        if not intent_id then state.notice = "Use Recover to find the desired activation first"; dirty = true; return end
        local pending = state.pending_step
        if pending and pending.intent_id ~= intent_id then
            state.notice = "A previous step has no reply; check its activation status first"; dirty = true; return
        end
        if not pending then
            pending = {intent_id = intent_id, receipt_key = new_key()}
            model.set_pending_step(state, intent_id, pending.receipt_key)
        end
        local reply = invoke(model.step_request(state, pending.intent_id, pending.receipt_key))
        local applied = model.apply_activation(state, reply)
        if reply and (applied or not reply.ok) then state.pending_step = nil end
        if applied then state.restored_intent_id = state.intent and state.intent.intent_id or nil end
        dirty = true
    end
    local function activation_status()
        local intent_id = state.intent and state.intent.intent_id or state.restored_intent_id
        if not intent_id then state.notice = "No activation is known yet; use Recover to look up the desired one"; dirty = true; return end
        local applied = model.apply_activation(state, invoke(model.status_request(state, intent_id)))
        if applied then state.restored_intent_id = state.intent and state.intent.intent_id or nil end
        dirty = true
    end
    local function recover()
        local key = state.pending_recover_key or new_key()
        model.set_pending_recover(state, key)
        local reply = invoke(model.recover_request(state, key))
        local applied = model.apply_activation(state, reply)
        if reply and (applied or not reply.ok) then state.pending_recover_key = nil end
        if applied then state.restored_intent_id = state.intent and state.intent.intent_id or nil end
        dirty = true
    end
    local function checkpoint()
        local encoded = model.checkpoint(state)
        if encoded ~= last_checkpoint then
            local sent = client.checkpoint(launch, encoded)
            if sent then last_checkpoint = encoded end
        end
    end

    refresh()
    if state.restored_intent_id then activation_status() end
    if launch.broker_pid then process.send(launch.broker_pid, "bee.appearance.request", {version = 1, request_id = uuid.v7(), op = "state"}) end
    while running do
        if dirty then
            local frame = view.draw(width, height, preferences, state, offset)
            offset = frame.offset
            assert(output:present(frame.rows, {cursor = {x = 1, y = 1, visible = false}}))
            if not announced then client.ready(launch); announced = true end
            checkpoint()
            dirty = false
        end
        local event = channel.select({input:case_receive(), lifecycle:case_receive(), states:case_receive()})
        if not event.ok then break end
        if event.channel == lifecycle then
            if event.value.kind == process.event.CANCEL then running = false end
        elseif event.channel == states then
            local message = event.value
            if launch.broker_pid and message:from() == launch.broker_pid then
                local data: unknown = message:payload():data()
                local next_preferences = appearance.decode(data)
                if next_preferences and type(data) == "table" and data.version == 1 then preferences = next_preferences; dirty = true end
            end
        else
            local data = event.value
            if data.type == "close" then running = false
            elseif data.type == "resize" then width, height = data.width, data.height; dirty = true
            elseif data.type == "key" and data.action ~= "release" then
                local key = data.key_type
                local text = tostring(data.key or "")
                if key == "tab" or text == "\t" then model.toggle_pane(state); offset = 0; dirty = true
                elseif key == "up" or text == "k" then
                    if state.pane == "review" then offset = math.floor(math.max(0, offset - 1))
                    elseif state.pane == "available" then model.move_available(state, -1) else model.move(state, -1) end
                    dirty = true
                elseif key == "down" or text == "j" then
                    if state.pane == "review" then offset = offset + 1
                    elseif state.pane == "available" then model.move_available(state, 1) else model.move(state, 1) end
                    dirty = true
                elseif key == "pgup" then
                    if state.pane == "review" then offset = math.floor(math.max(0, offset - 8))
                    elseif state.pane == "available" then model.move_available(state, -8) else model.move(state, -8) end
                    dirty = true
                elseif key == "pgdown" then
                    if state.pane == "review" then offset = offset + 8
                    elseif state.pane == "available" then model.move_available(state, 8) else model.move(state, 8) end
                    dirty = true
                elseif key == "enter" then if state.pane == "available" then stage_available() else get_selected() end
                elseif text == "a" then if state.pane == "available" then stage_available() else review(true) end
                elseif text == "n" then if state.pane == "plans" then review(false) end
                elseif text == "s" then if state.pane == "available" then stage_available() else select_version() end
                elseif text == "p" then prepare()
                elseif text == "x" then step()
                elseif text == "i" then activation_status()
                elseif text == "g" then recover()
                elseif text == "f" then refresh()
                elseif text == "t" then model.toggle_technical(state); dirty = true
                elseif key == "esc" or key == "escape" then running = false end
            elseif data.type == "mouse" and data.action == "wheel" then
                model.move(state, (data.button == "wheel_up" or data.button == "up") and -1 or 1); dirty = true
            end
        end
    end
    process.unlisten(states)
    output:close()
    tty.stop()
end
return {main = main}
