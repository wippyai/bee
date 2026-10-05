-- MIT. Workspace-local overlay review and activation status. The person
-- reviews and selects here; the approval decision belongs to the node's
-- approval owner.
local tty = require("tty")
local process = require("process")
local channel = require("channel")
local uuid = require("uuid")
local funcs = require("funcs")
local appearance = require("appearance")
local frame = require("frame")
local model = require("model")
local view = require("view")

local function new_key(): string
    local value, err = uuid.v4()
    if err or not value then error("allocate delivery idempotency key") end
    return value
end

-- The workspace the desktop that opened this app works in.
local function workspace_of(options: unknown): string
    local workspace = type(options) == "table" and options.workspace or nil
    local id = type(workspace) == "table" and workspace.id or nil
    if type(id) ~= "string" or id == "" then error("Overlays needs the desktop's workspace") end
    return id
end

local function main(options: unknown)
    local input = assert(tty.events())
    local menu = frame.menu()
    local lifecycle = assert(process.events())
    local changes = assert(process.listen(appearance.TOPIC, {message = true}))
    assert(tty.start())
    local output = assert(tty.surface())
    local width, height = tty.screen_size()
    local preferences = appearance.chosen(options)
    local state: model.State = model.new(workspace_of(options))
    local offset = 0
    local hits: {frame.Hit} = {}
    local dirty, running = true, true
    -- Destination calls are serialized in one worker so a delayed owner never
    -- blocks the presentation loop. The worker carries the model operations;
    -- this loop remains responsible for frames, resize and cancellation.
    local updates = channel.new(1)
    local busy = false
    local function changed()
        dirty = true
        if running then updates:send(true) end
    end
    local function perform(operation: () -> ()): boolean
        if busy then
            state.notice = "Request in progress"
            -- This branch runs on the presentation loop. The worker may
            -- already have filled the one-slot wakeup channel, so sending
            -- here could block the only receiver. Painting needs no wakeup.
            dirty = true
            return false
        end
        busy = true
        state.notice = "Working…"
        dirty = true
        coroutine.spawn(function()
            local ok, failure = pcall(operation)
            busy = false
            if not running then return end
            if not ok then state.notice = "Request failed: " .. tostring(failure)
            elseif state.notice == "Working…" then state.notice = "" end
            changed()
        end)
        return true
    end
    local function invoke(request: unknown): model.Reply?
        local raw, err = funcs.new():call(model.CALL, request)
        if err then return nil end
        return model.reply(raw)
    end
    local function refresh_now()
        local available_ok = model.apply_available(state, invoke(model.available_request(state)))
        local available_notice = available_ok and "" or state.notice
        local plans_ok = model.apply_list(state, invoke(model.list_request(state)))
        local plans_notice = plans_ok and "" or state.notice
        if not available_ok and not plans_ok then state.notice = available_notice .. "; " .. plans_notice
        elseif not available_ok then state.notice = available_notice
        elseif not plans_ok then state.notice = plans_notice
        else state.notice = "" end
    end
    local function stage_available_now()
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
        if applied then refresh_now(); state.notice = "Staged for local review; no installation performed" end
        dirty = true
    end
    local function get_selected_now()
        local item = model.selected(state)
        if not item then state.notice = "Choose a staged version first"; dirty = true; return end
        if model.apply_plan(state, invoke(model.get_request(state, item))) then
            model.apply_changes(state, invoke(model.changes_request(state, item)), item)
            state.pane = "review"
            offset = 0
        end
        dirty = true
    end
    local function review_transition(accepted: boolean): boolean
        local item = model.selected(state)
        local refused = accepted and model.refusal(state, item) or nil
        if refused then state.notice = refused; dirty = true; return false end
        if not model.accepts_review(item) or not item then
            state.notice = "Only a staged version can receive a local review"; dirty = true; return false
        end
        local applied = model.apply_plan(state, invoke(model.review_request(state, item, accepted, new_key())))
        dirty = true
        return applied
    end
    local function select_transition(): boolean
        local item = model.selected(state)
        local refused = model.refusal(state, item)
        if refused then state.notice = refused; dirty = true; return false end
        if not model.can_select(item) or not item then
            state.notice = "Record an accepted local review before selecting this version"; dirty = true; return false
        end
        local applied = model.apply_plan(state, invoke(model.select_request(state, item, new_key())))
        dirty = true
        return applied
    end
    local function prepare_transition(): boolean
        local item = model.selected(state)
        local refused = model.refusal(state, item)
        if refused then state.notice = refused; dirty = true; return false end
        if not model.can_prepare(state, item) or not item then
            state.notice = "Select an accepted version before preparing activation"; dirty = true; return false
        end
        local pending = state.pending_prepare
        if pending and pending.plan_key ~= model.key(item) then
            state.notice = "A previous prepare has no reply; select that version and retry its same request"; dirty = true; return false
        end
        if not pending then
            pending = {plan_key = model.key(item), intent_id = new_key(), receipt_key = new_key()}
            model.set_pending_prepare(state, item, pending.intent_id, pending.receipt_key)
        end
        changed()
        local reply = invoke(model.prepare_request(state, item, pending.intent_id, pending.receipt_key))
        local applied = model.apply_activation(state, reply)
        if reply and (applied or not reply.ok) then state.pending_prepare = nil end
        dirty = true
        return applied
    end
    local function prepare_activation_now()
        local item = model.selected(state)
        local refused = model.refusal(state, item)
        if refused then state.notice = refused; dirty = true; return end
        if not item then state.notice = "Choose a staged version first"; dirty = true; return end
        if model.accepts_review(item) then
            if not review_transition(true) then return end
            item = model.selected(state)
        end
        if item and model.can_select(item) and not item.selected then
            if not select_transition() then return end
            item = model.selected(state)
        end
        if item and model.can_prepare(state, item) then
            prepare_transition()
        elseif not item or not model.can_prepare(state, item) then
            state.notice = "Accept and select this version before preparing activation"
        end
        dirty = true
    end
    local function step_now()
        local intent_id = state.intent and state.intent.intent_id or state.restored_intent_id
        if not intent_id then state.notice = "Use Recover to find the desired activation first"; dirty = true; return end
        if not state.intent and not model.apply_activation(state, invoke(model.status_request(state, intent_id))) then
            dirty = true; return
        end
        -- Each next request follows an acknowledged owner transition. Unknown
        -- answers retain their exact receipt key and stop this person action.
        while running and model.can_advance(state) do
            local before = assert(state.intent)
            local pending = state.pending_step
            if pending and pending.intent_id ~= intent_id then
                state.notice = "A previous step has no reply; check its activation status first"; dirty = true; return
            end
            if not pending then
                pending = {intent_id = intent_id, receipt_key = new_key()}
                model.set_pending_step(state, intent_id, pending.receipt_key)
            end
            changed()
            local reply = invoke(model.step_request(state, pending.intent_id, pending.receipt_key))
            local applied = model.apply_activation(state, reply)
            if reply and (applied or not reply.ok) then state.pending_step = nil end
            if not applied then dirty = true; return end
            local observed = assert(state.intent)
            state.restored_intent_id = observed.intent_id
            if observed.phase == before.phase and observed.revision == before.revision then
                state.notice = "Owner acknowledged the step without a new activation revision; inspect status before continuing"
                dirty = true; return
            end
        end
        dirty = true
    end
    local function activation_status_now()
        local intent_id = state.intent and state.intent.intent_id or state.restored_intent_id
        if not intent_id then state.notice = "No activation is known yet; use Recover to look up the desired one"; dirty = true; return end
        local applied = model.apply_activation(state, invoke(model.status_request(state, intent_id)))
        if applied then state.restored_intent_id = state.intent and state.intent.intent_id or nil end
        dirty = true
    end
    local function recover_now()
        local item = model.selected(state)
        if not item then state.notice = "Choose the staged version whose activation to recover"; dirty = true; return end
        local key = state.pending_recover_key or new_key()
        model.set_pending_recover(state, key)
        local reply = invoke(model.recover_request(state, item, key))
        local applied = model.apply_activation(state, reply)
        if reply and (applied or not reply.ok) then state.pending_recover_key = nil end
        if applied then state.restored_intent_id = state.intent and state.intent.intent_id or nil end
        dirty = true
    end
    local function take(kind: string)
        if kind == "stage" then perform(stage_available_now)
        elseif kind == "read" then perform(get_selected_now)
        elseif kind == "prepare_activation" then perform(prepare_activation_now)
        elseif kind == "accept" then perform(function() review_transition(true) end)
        elseif kind == "reject" then perform(function() review_transition(false) end)
        elseif kind == "select" then perform(select_transition)
        elseif kind == "prepare" then perform(prepare_transition)
        elseif kind == "step" then perform(step_now)
        elseif kind == "status" then perform(activation_status_now)
        elseif kind == "recover" then perform(recover_now)
        elseif kind == "refresh" then perform(refresh_now)
        elseif kind == "details" then model.toggle_technical(state); dirty = true end
    end
    local function selection_locked(): boolean
        if not busy then return false end
        state.notice = "Request in progress"
        dirty = true
        return true
    end

    perform(refresh_now)
    while running do
        if dirty then
            local drawn = view.draw(width, height, preferences, state, offset)
            frame.render(drawn, menu, preferences)
            hits = drawn.hits
            offset = drawn.offset
            assert(output:present(drawn.rows, {cursor = {x = 1, y = 1, visible = false}}))
            dirty = false
        end
        local event = channel.select({input:case_receive(), lifecycle:case_receive(), changes:case_receive(), updates:case_receive()})
        if not event.ok then break end
        if event.channel == lifecycle then
            if event.value.kind == process.event.CANCEL then running = false end
        elseif event.channel == updates then
            dirty = true
        elseif event.channel == changes then
            preferences = appearance.chosen(event.value:payload():data())
            dirty = true
        else
            local data, handled = frame.route(menu, event.value, false)
            if handled then dirty = true end
            if data then
                if data.type == "close" then running = false
                elseif data.type == "resize" then width, height = data.width, data.height; dirty = true
                elseif data.type == "key" and data.action ~= "release" then
                    local key = data.key_type
                    local text = tostring(data.key or "")
                    if key == "tab" or text == "\t" then
                        if not selection_locked() then model.toggle_pane(state); offset = 0; dirty = true end
                    elseif key == "up" or text == "k" then
                        if state.pane == "review" then offset = math.floor(math.max(0, offset - 1))
                        elseif not selection_locked() then
                            if state.pane == "available" then model.move_available(state, -1) else model.move(state, -1) end
                        end
                        dirty = true
                    elseif key == "down" or text == "j" then
                        if state.pane == "review" then offset = offset + 1
                        elseif not selection_locked() then
                            if state.pane == "available" then model.move_available(state, 1) else model.move(state, 1) end
                        end
                        dirty = true
                    elseif key == "pgup" then
                        if state.pane == "review" then offset = math.floor(math.max(0, offset - 8))
                        elseif not selection_locked() then
                            if state.pane == "available" then model.move_available(state, -8) else model.move(state, -8) end
                        end
                        dirty = true
                    elseif key == "pgdown" then
                        if state.pane == "review" then offset = offset + 8
                        elseif not selection_locked() then
                            if state.pane == "available" then model.move_available(state, 8) else model.move(state, 8) end
                        end
                        dirty = true
                    elseif key == "enter" then
                        local kind, _, enabled = view.primary(state)
                        if enabled then take(kind) end
                    elseif text == "a" then take(state.pane == "available" and "stage" or "accept")
                    elseif text == "n" then take("reject")
                    elseif text == "s" then take(state.pane == "available" and "stage" or "select")
                    elseif text == "p" then take("prepare")
                    elseif text == "x" then take("step")
                    elseif text == "i" then take("status")
                    elseif text == "g" then take("recover")
                    elseif text == "r" or text == "f" then take("refresh")
                    elseif text == "t" then take("details")
                    elseif key == "esc" or key == "escape" then running = false end
                elseif data.type == "mouse" and data.action == "press" and data.button == "left" then
                    local hit = frame.hit(hits, math.floor(tonumber(data.x) or 1), math.floor(tonumber(data.y) or 1))
                    if hit then
                        local pane = view.pane_of(hit.kind)
                        if pane then
                            if not selection_locked() then
                                model.show_pane(state, pane)
                                offset = 0; dirty = true
                            end
                        elseif hit.kind == "available" then
                            if not selection_locked() then model.select_available(state, hit.key); dirty = true end
                        elseif hit.kind == "plan" then
                            if not selection_locked() then model.select(state, hit.key); dirty = true end
                        else take(hit.kind) end
                    end
                elseif data.type == "mouse" and data.action == "wheel" then
                    if state.pane == "review" then
                        offset = math.floor(math.max(0, offset + ((data.button == "wheel_up" or data.button == "up") and -1 or 1)))
                    elseif not selection_locked() then
                        if state.pane == "available" then model.move_available(state, (data.button == "wheel_up" or data.button == "up") and -1 or 1)
                        else model.move(state, (data.button == "wheel_up" or data.button == "up") and -1 or 1) end
                    end
                    dirty = true
                end
            end
        end
    end
    process.unlisten(changes)
    updates:close()
    output:close()
    tty.stop()
end
return {main = main}
