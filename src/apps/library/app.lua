-- MIT. The Library: one place for every application and driver a person can
-- install. Versions this bee's agents made and other bees shared arrive through
-- the destination facade; Hub packages through the Hub facade. The person
-- reviews and installs here; the approval decision belongs to the node's
-- approval owner, and package credentials and registry writes stay behind the
-- two facades.
local tty = require("tty")
local process = require("process")
local channel = require("channel")
local uuid = require("uuid")
local funcs = require("funcs")
local time = require("time")
local appearance = require("appearance")
local frame = require("frame")
local model = require("model")
local governed = require("governed")
local hub = require("hub")
local view = require("view")
local contents = require("contents")

type Reply = {ok: boolean, code: string?, message: string?, value: unknown, replayed: boolean}
type Pending = {future: funcs.Future, response: channel.Channel, operation: string, generation: integer, apply: boolean}
type ReadPending = {future: funcs.Future, response: channel.Channel, operation: string, generation: integer, retired: boolean}
type Editor = {field: string, buffer: string, name: string?}

local POLL = "2s"

local function new_key(): string
    local value, err = uuid.v4()
    if err or not value then error("allocate delivery idempotency key") end
    return value
end

-- The workspace the desktop that opened this app works in.
local function workspace_of(options: unknown): string
    local workspace = type(options) == "table" and options.workspace or nil
    local id = type(workspace) == "table" and workspace.id or nil
    if type(id) ~= "string" or id == "" then error("The Library needs the desktop's workspace") end
    return id
end

local function reply(value: unknown): Reply
    if type(value) == "table" and type(value.ok) == "boolean" and type(value.replayed) == "boolean" then
        local raw = value
        local receipt = type(raw.value) == "table" and raw.value or nil
        local state = receipt and type(receipt.state) == "string" and receipt.state or ""
        local failed = state == "failed" or state == "recovery_required"
        return {ok = raw.ok == true and not failed, replayed = raw.replayed == true,
            code = failed and (type(raw.code) == "string" and raw.code ~= "OK" and raw.code or state:upper()) or (type(raw.code) == "string" and raw.code or nil),
            message = type(raw.message) == "string" and raw.message or nil, value = raw.value}
    end
    return {ok = false, replayed = false, code = "UNCERTAIN", message = "Hub reply was unavailable", value = nil}
end

local function completed(pending: Pending): Reply
    local result, err = pending.future:result()
    if err or not result then return {ok = false, replayed = false, code = "UNCERTAIN", message = tostring(err or "Hub call ended without a reply"), value = nil} end
    return reply(result:data())
end

local function editable(value: string): string
    return value:sub(1, 8192)
end

local function previous(value: string): string
    local start = #value
    while start > 1 do
        local byte = value:byte(start)
        if byte < 0x80 or byte >= 0xC0 then break end
        start = start - 1
    end
    return value:sub(1, math.floor(math.max(0, start - 1)))
end

local function main(options: unknown)
    local input = assert(tty.events())
    local menu = frame.menu()
    local lifecycle = assert(process.events())
    local changes = assert(process.listen(appearance.TOPIC, {message = true}))
    local ticker = assert(time.ticker(POLL))
    local ticks = ticker:channel()
    assert(tty.start())
    local output = assert(tty.surface())
    local width, height = tty.screen_size()
    local preferences = appearance.chosen(options)
    local state: model.State = model.new(workspace_of(options))
    local gov = state.governed
    local hubs = state.hub
    local ui: view.Ui = {offset = 0, status = "", reading = false, editor = nil, content = contents.new()}
    local visible_rows = 1
    local hits: {frame.Hit} = {}
    local pending: {Pending} = {}
    local reading: ReadPending? = nil
    local reads: {hub.Intent} = {}
    local generation = 0
    local apply_pending = false
    local running, dirty = true, true

    -- Governed calls run one at a time in a worker, so a delayed owner never
    -- blocks the presentation loop. The worker carries the model operations;
    -- this loop remains responsible for frames, resize and cancellation.
    local updates = channel.new(1)
    local busy = false

    local function changed()
        dirty = true
    end
    local function wake()
        dirty = true
        if running then updates:send(true) end
    end
    local function invalidate()
        generation = generation + 1
        reads = {}
    end
    local function perform(operation: () -> ()): boolean
        if busy then
            ui.status = "Request in progress"
            -- This branch runs on the presentation loop. The worker may
            -- already have filled the one-slot wakeup channel, so sending
            -- here could block the only receiver. Painting needs no wakeup.
            dirty = true
            return false
        end
        busy = true
        ui.status = "Working…"
        dirty = true
        coroutine.spawn(function()
            local ok, failure = pcall(operation)
            busy = false
            if not running then return end
            if not ok then ui.status = "That did not finish; try Refresh"; gov.fault = tostring(failure)
            elseif ui.status == "Working…" then ui.status = "" end
            wake()
        end)
        return true
    end
    local function invoke(request: unknown): governed.Reply?
        local raw, err = funcs.new():call(governed.CALL, request)
        if err then return nil end
        return governed.reply(raw)
    end

    -- Governed reads and the install chain.
    local function refresh_activations()
        governed.apply_activations(gov, invoke(governed.activations_request(gov)))
    end
    local function refresh_governed()
        local failures: {string} = {}
        local function note()
            if gov.notice ~= "" then failures[#failures + 1] = gov.notice end
        end
        governed.apply_available(gov, invoke(governed.available_request(gov))); note()
        governed.apply_list(gov, invoke(governed.list_request(gov))); note()
        governed.apply_activations(gov, invoke(governed.activations_request(gov))); note()
        gov.notice = failures[1] or ""
        if gov.notice ~= "" then state.notice = gov.notice else state.notice = "" end
    end
    local function stage_now(item: governed.Available): boolean
        local staged = governed.staged_plan(gov, item)
        if staged then governed.select(gov, governed.key(staged)); return true end
        local pending_stage = gov.pending_stage
        local selected_key = governed.available_key(item)
        if pending_stage and pending_stage.available_key ~= selected_key then
            state.notice = "An earlier install did not finish; choose that version and try again"
            return false
        end
        if not pending_stage then
            pending_stage = {available_key = selected_key, idempotency_key = new_key()}
            gov.pending_stage = pending_stage
        end
        local answer = invoke(governed.stage_request(gov, item, pending_stage.idempotency_key))
        local applied = governed.apply_stage(gov, answer, item)
        if answer and (applied or not answer.ok) then gov.pending_stage = nil end
        if not applied then state.notice = gov.notice end
        return applied
    end
    local function read_selected_now(): boolean
        local item = governed.selected(gov)
        if not item then state.notice = "Choose a version first"; return false end
        if not governed.apply_plan(gov, invoke(governed.get_request(gov, item))) then state.notice = gov.notice; return false end
        governed.apply_changes(gov, invoke(governed.changes_request(gov, item)), item)
        return true
    end
    local function refuse(item: governed.Plan?): boolean
        local person, technical = governed.refusal(gov, item)
        if not person then return false end
        state.notice = person
        gov.fault = technical or person
        return true
    end
    local function review_transition(accepted: boolean): boolean
        local item = governed.selected(gov)
        if accepted and refuse(item) then return false end
        if not governed.accepts_review(item) or not item then
            state.notice = "This version has already been reviewed"; return false
        end
        local applied = governed.apply_plan(gov, invoke(governed.review_request(gov, item, accepted, new_key())))
        if not applied then state.notice = gov.notice end
        return applied
    end
    local function select_transition(): boolean
        local item = governed.selected(gov)
        if refuse(item) then return false end
        if not governed.can_select(item) or not item then
            state.notice = "Review this version before choosing it"; return false
        end
        local applied = governed.apply_plan(gov, invoke(governed.select_request(gov, item, new_key())))
        if not applied then state.notice = gov.notice end
        return applied
    end
    local function prepare_transition(): boolean
        local item = governed.selected(gov)
        if refuse(item) then return false end
        if not governed.can_prepare(gov, item) or not item then
            state.notice = "Choose a reviewed version before asking for approval"; return false
        end
        local pending_prepare = gov.pending_prepare
        if pending_prepare and pending_prepare.plan_key ~= governed.key(item) then
            state.notice = "An earlier install did not finish; choose that version and try again"; return false
        end
        if not pending_prepare then
            pending_prepare = {plan_key = governed.key(item), intent_id = new_key(), receipt_key = new_key()}
            governed.set_pending_prepare(gov, item, pending_prepare.intent_id, pending_prepare.receipt_key)
        end
        wake()
        local answer = invoke(governed.prepare_request(gov, item, pending_prepare.intent_id, pending_prepare.receipt_key))
        local applied = governed.apply_activation(gov, answer)
        if answer and (applied or not answer.ok) then gov.pending_prepare = nil end
        state.notice = gov.notice
        return applied
    end
    -- Install runs the whole local path: receive the version, read its checks,
    -- review it, choose it and ask for approval, which waits in Needs you.
    local function install_now(row: model.Row)
        local item: governed.Available? = nil
        for _, candidate in ipairs(gov.available) do
            if governed.available_key(candidate) == row.available_key then item = candidate end
        end
        if not item then state.notice = "That version is no longer shared; try Refresh"; return end
        governed.select_available(gov, governed.available_key(item))
        if not stage_now(item) then return end
        refresh_governed()
        local plan = governed.staged_plan(gov, item)
        if plan then governed.select(gov, governed.key(plan)) end
        if not read_selected_now() then return end
        local selected = governed.selected(gov)
        if governed.accepts_review(selected) and not review_transition(true) then return end
        selected = governed.selected(gov)
        if selected and governed.can_select(selected) and not selected.selected and not select_transition() then return end
        selected = governed.selected(gov)
        if selected and governed.can_prepare(gov, selected) then
            if prepare_transition() then
                refresh_activations()
                state.notice = ""
            end
        else
            state.notice = state.notice ~= "" and state.notice or "This version can't be installed here right now"
        end
    end
    local function step_now()
        local intent_id = gov.intent and gov.intent.intent_id or gov.restored_intent_id
        if not intent_id then state.notice = "Use Recover to find the install first"; return end
        if not gov.intent and not governed.apply_activation(gov, invoke(governed.status_request(gov, intent_id))) then
            state.notice = gov.notice; return
        end
        -- Each next request follows an acknowledged owner transition. Unknown
        -- answers retain their exact receipt key and stop this person action.
        while running and governed.can_advance(gov) do
            local before = assert(gov.intent)
            local pending_step = gov.pending_step
            if pending_step and pending_step.intent_id ~= intent_id then
                state.notice = "An earlier step did not finish; check its status first"; return
            end
            if not pending_step then
                pending_step = {intent_id = intent_id, receipt_key = new_key()}
                governed.set_pending_step(gov, intent_id, pending_step.receipt_key)
            end
            wake()
            local answer = invoke(governed.step_request(gov, pending_step.intent_id, pending_step.receipt_key))
            local applied = governed.apply_activation(gov, answer)
            if answer and (applied or not answer.ok) then gov.pending_step = nil end
            state.notice = gov.notice
            if not applied then return end
            local observed = assert(gov.intent)
            gov.restored_intent_id = observed.intent_id
            if observed.phase == before.phase and observed.revision == before.revision then
                state.notice = "Nothing moved; check the status before continuing"; return
            end
        end
    end
    local function status_now()
        local intent_id = gov.intent and gov.intent.intent_id or gov.restored_intent_id
        if not intent_id then state.notice = "Nothing is known yet; use Recover to look it up"; return end
        local applied = governed.apply_activation(gov, invoke(governed.status_request(gov, intent_id)))
        if applied then gov.restored_intent_id = gov.intent and gov.intent.intent_id or nil end
        state.notice = gov.notice
    end
    local function recover_now()
        local item = governed.selected(gov)
        if not item then state.notice = "Choose the version whose install to look up"; return end
        local key = gov.pending_recover_key or new_key()
        governed.set_pending_recover(gov, key)
        local answer = invoke(governed.recover_request(gov, item, key))
        local applied = governed.apply_activation(gov, answer)
        if answer and (applied or not answer.ok) then gov.pending_recover_key = nil end
        if applied then gov.restored_intent_id = gov.intent and gov.intent.intent_id or nil end
        state.notice = gov.notice
    end
    -- open_version selects the plan a governed row stands for and reads it.
    local function open_version_now(row: model.Row)
        local plan: governed.Plan? = nil
        if row.available_key then
            for _, candidate in ipairs(gov.available) do
                if governed.available_key(candidate) == row.available_key then plan = governed.staged_plan(gov, candidate) end
            end
        elseif row.app then
            for _, candidate in ipairs(gov.plans) do
                if candidate.source_workspace == row.app then plan = candidate end
            end
        end
        if plan then
            governed.select(gov, governed.key(plan))
            read_selected_now()
        else
            governed.select(gov, nil)
            governed.forget_review(gov)
        end
    end

    -- Hub reads run one at a time under a generation: navigation retires what
    -- was asked before it, and a stale answer never changes the model.
    local function read_operation(intent: hub.Intent): string
        return intent.operation == "status" and intent.expected_digest == nil and "history" or intent.operation
    end
    local function fold_read(operation: string, value: Reply)
        if operation == "state" or operation == "files" or operation == "read_file" then contents.apply(ui.content, operation, value)
        elseif operation == "catalog" then hub.apply_catalog(hubs, value)
        elseif operation == "installed" then
            ui.status = ""
            hub.apply_installed(hubs, value)
            if hubs.action == "update" and hubs.installed_read == "ready" then hubs.notice = "Installed settings loaded" end
            if state.tab == "installed" and hubs.installed_read == "ready" and hubs.phase == "installed" then
                hub.begin_updates(hubs)
                table.insert(reads, 1, hub.updates_intent(hubs))
            end
        elseif operation == "updates" then hub.apply_updates(hubs, value)
        elseif operation == "details" then hub.apply_details(hubs, value)
        elseif operation == "inspect" then hub.apply_inspect(hubs, value)
        elseif operation == "plan" then hub.apply_plan(hubs, value)
        elseif operation == "status" then hub.apply_result(hubs, value)
        elseif operation == "history" then hub.apply_history(hubs, value) end
        if hubs.notice ~= "" and hubs.phase ~= "details" then state.notice = hubs.notice end
    end
    local function start_next()
        if reading then return end
        while #reads > 0 do
            local next_intent = table.remove(reads, 1)
            local stamped = generation
            local future, err = funcs.new():async(hub.HUB, next_intent)
            if not future or err then
                fold_read(read_operation(next_intent), {ok = false, replayed = false, code = "UNCERTAIN", message = tostring(err or "Hub dispatch unavailable"), value = nil})
            else
                local response = future:response()
                if not response then
                    future:cancel()
                    fold_read(read_operation(next_intent), {ok = false, replayed = false, code = "UNAVAILABLE", message = "Hub response channel unavailable", value = nil})
                else
                    reading = {future = future, response = response, operation = read_operation(next_intent), generation = stamped, retired = false}
                    return
                end
            end
        end
    end
    -- begin asks the Hub. A read replaces what was asked before it; an apply
    -- runs beside the reads and is never retried by this client.
    local function begin(intents: {hub.Intent}): boolean
        invalidate()
        reads = intents
        if reading then
            -- Keep the stale read alive until its response is consumed. A
            -- future cancellation is delivered as this app's lifecycle
            -- cancellation, which would terminate the UI before a queued
            -- retry can start. The generation fence below still prevents
            -- the stale response from changing model state.
            reading.retired = true
        else start_next() end
        return true
    end
    local function begin_apply(intent: hub.Intent): boolean
        local future, err = funcs.new():async(hub.HUB, intent)
        if not future or err then
            hub.apply_result(hubs, {ok = false, replayed = false, code = "UNCERTAIN", message = tostring(err or "Hub dispatch unavailable"), value = nil})
            apply_pending = false
            changed()
            return false
        end
        local response = future:response()
        if not response then
            future:cancel()
            hub.apply_result(hubs, {ok = false, replayed = false, code = "UNCERTAIN", message = "Hub response channel unavailable", value = nil})
            apply_pending = false
            changed()
            return false
        end
        pending[#pending + 1] = {future = future, response = response, operation = intent.operation, generation = 0, apply = true}
        return true
    end

    -- tab_phase is the Hub phase a tab's list stands on.
    local function tab_phase(tab: model.Tab): string
        if tab == "installed" then return "installed" end
        if tab == "shared" then return "catalog" end
        return "operations"
    end
    local function load_tab()
        ui.offset, ui.reading = 0, false
        ui.content.open = false
        hub.show(hubs, tab_phase(state.tab) :: hub.Phase)
        if state.tab == "installed" then begin({hub.installed_intent(hubs)})
        elseif state.tab == "shared" then begin({hub.installed_intent(hubs), hub.catalog_intent(hubs)})
        else begin({hub.operation_history_intent(hubs)}) end
        perform(refresh_governed)
        changed()
    end
    local function show_tab(tab: model.Tab)
        model.show_tab(state, tab)
        load_tab()
    end
    local function leave_package()
        ui.content.open = false
        ui.reading = false
        invalidate()
        local showing_result = hubs.phase == "result"
        hub.show(hubs, tab_phase(state.tab) :: hub.Phase)
        if showing_result then load_tab() else changed() end
    end

    local function details()
        ui.content.open = false
        local intent = hub.details_intent(hubs)
        if not intent then ui.status = "Choose a package first"; changed(); return end
        hub.show(hubs, "details")
        ui.reading = true
        hub.show_requirements(hubs, false)
        begin({intent})
        changed()
    end
    local function requirements()
        ui.content.open = false
        hub.show_requirements(hubs, true)
        ui.reading, ui.offset = false, 0
        local intent = hub.inspect_intent(hubs)
        if intent then begin({intent})
        elseif hubs.action == "update" then ui.status = "Read installed settings before inspecting this update"
        else ui.status = "Choose a version first" end
        changed()
    end
    local function plan()
        local intent, problem = hub.plan_intent(hubs)
        if not intent then ui.status = problem or "Cannot review these changes"; changed(); return end
        hub.begin_plan(hubs)
        ui.offset = 0
        begin({intent})
        changed()
    end
    local function update_bee()
        local update = hubs.bee_update
        if hubs.update_status ~= "ready" or not update then ui.status = "Read Hub update status before updating Bee"; changed(); return end
        local selected_version = hubs.phase == "details" and hubs.selected == "bee/bee" and hubs.selected_version or nil
        local target = selected_version or update.available_version
        if target == "" or (not selected_version and not update.update_available) then
            ui.status = "No newer bee/bee version is available"; changed(); return
        end
        if update.needs_new_binary and target == update.available_version then
            ui.status = update.reason ~= "" and update.reason or "needs a newer Bee binary"; changed(); return
        end
        if hubs.phase ~= "details" or hubs.selected ~= "bee/bee" then hub.select(hubs, "bee/bee") end
        hub.set_action(hubs, "update")
        hub.select_version(hubs, target)
        hub.show_requirements(hubs, false)
        invalidate()
        plan()
    end
    -- update_package reviews the newer version of an installed Hub package.
    local function update_package(component: string, target: string)
        if component == "bee/bee" then
            hub.select(hubs, component)
            update_bee()
            return
        end
        hub.select(hubs, component)
        hub.set_action(hubs, "update")
        hub.select_version(hubs, target)
        invalidate()
        plan()
    end
    local function remove_package(component: string)
        hub.select(hubs, component)
        hub.set_action(hubs, "uninstall")
        invalidate()
        plan()
    end
    local function operation_history()
        invalidate()
        hub.show(hubs, "operations")
        ui.offset = 0
        begin({hub.operation_history_intent(hubs)})
        changed()
    end
    local function check_status()
        local intent = hub.status_intent(hubs)
        if not intent then ui.status = "Nothing to check"; changed(); return end
        begin({intent})
        changed()
    end
    -- Reaching confirm only changes presentation state. Dispatching apply is
    -- a separate, explicit event and is never retried by this client.
    local function confirm()
        if apply_pending then ui.status = "Applying is still pending; check the status if the result is uncertain"; changed(); return end
        local intent, problem = hub.confirm_intent(hubs)
        if not intent then ui.status = problem or "These changes cannot be applied"; changed(); return end
        apply_pending = true
        ui.status = "Applying the changes…"
        begin_apply(intent)
        changed()
    end
    local function choose(name: string)
        hub.select(hubs, name)
        ui.offset = 0
        ui.reading = false
        invalidate()
        details()
    end
    local function operation_relative(delta: integer)
        if #hubs.operations == 0 then return end
        local current = 0
        for index, item in ipairs(hubs.operations) do
            if hubs.selected_operation and item.digest == hubs.selected_operation.digest then current = index; break end
        end
        local next_index = math.floor(math.max(1, math.min(#hubs.operations, current + delta)))
        hub.select_operation(hubs, hubs.operations[next_index].digest)
        hub.show(hubs, "operations")
        invalidate()
        changed()
    end
    local function cancel_confirmation()
        if hubs.recovery then
            state.tab = "history"
            operation_history()
        else hub.show(hubs, "plan"); changed() end
    end
    local function version_relative(delta: integer)
        local detail = hubs.detail
        if not detail or #detail.versions == 0 then return end
        local current = 0
        for index, item in ipairs(detail.versions) do if item.version == hubs.selected_version then current = index; break end end
        local next_index = math.floor(math.max(1, math.min(#detail.versions, current + delta)))
        if next_index <= ui.offset then ui.offset = next_index - 1 end
        if next_index > ui.offset + visible_rows then ui.offset = math.floor(math.max(0, next_index - visible_rows)) end
        hub.select_version(hubs, detail.versions[next_index].version)
        invalidate()
        changed()
    end
    local function finish_editor()
        local active = ui.editor
        if not active then return end
        if active.field == "query" then
            hub.set_query(hubs, active.buffer)
            invalidate()
            ui.editor = nil
            load_tab()
            return
        elseif active.field == "keyword" then
            hub.set_keyword(hubs, active.buffer)
            invalidate()
            ui.editor = nil
            load_tab()
            return
        elseif active.field == "parameter_name" then
            if active.buffer == "" then ui.status = "Parameter name is required"; changed(); return end
            ui.editor = {field = "parameter_value", buffer = "", name = active.buffer}
            ui.status = "Parameter JSON value: "
            changed()
            return
        else
            local problem = hub.set_parameter(hubs, active.name or "", active.buffer)
            if problem then ui.status = problem; changed(); return end
            ui.status = "Parameter saved"; invalidate(); if hubs.requirements_open then requirements() end
            changed()
        end
        ui.editor = nil
    end
    local function begin_editor(field: string)
        if field == "query" then ui.editor = {field = field, buffer = hubs.query}; ui.status = "Search: " .. hubs.query
        elseif field == "keyword" then ui.editor = {field = field, buffer = hubs.keyword}; ui.status = "Keyword (empty is all): " .. hubs.keyword
        else ui.editor = {field = "parameter_name", buffer = ""}; ui.status = "Parameter name (namespace:name): " end
        changed()
    end
    local function edit_requirement()
        local row = hubs.requirements[hubs.selected_requirement]
        if not row then ui.status = "Select a requirement first"; changed(); return end
        ui.editor = {field = "parameter_value", buffer = row.json, name = row.id}
        ui.status = row.id .. " JSON: " .. row.json
        changed()
    end

    -- The row a click or key acts on, activated by its origin.
    local function open_row(row: model.Row)
        if row.origin == "hub" then
            if row.component then choose(row.component) end
        else
            perform(function() open_version_now(row) end)
            model.show_version(state, true)
            ui.offset = 0
            changed()
        end
    end
    local function install_row(row: model.Row)
        if row.origin == "hub" then open_row(row)
        else perform(function() install_now(row) end) end
    end
    local function update_row(row: model.Row)
        if row.status ~= model.STATUS_UPDATE or not row.update then return end
        if row.origin == "hub" then
            if row.component then update_package(row.component, row.update) end
        else perform(function() install_now(row) end) end
    end
    local function move_selection(delta: integer)
        model.move(state, delta)
        local row = model.selected_row(state)
        local rows = model.rows(state)
        local index = 1
        for position, candidate in ipairs(rows) do if row and candidate.key == row.key then index = position; break end end
        if index <= ui.offset then ui.offset = index - 1 end
        if index > ui.offset + visible_rows then ui.offset = math.floor(math.max(0, index - visible_rows)) end
        if state.tab == "history" then
            local picked = row
            if picked and picked.operation then
                hub.select_operation(hubs, picked.operation)
                hub.show(hubs, "operations")
            else hubs.selected_operation = nil end
        end
        changed()
    end

    local function list_hit(kind: string, key: string)
        ui.status = ""
        local row = model.selected_row(state)
        if kind == "row" then
            local was = row and row.key == key
            model.select(state, key)
            if state.tab == "history" then move_selection(0) end
            row = model.selected_row(state)
            if was and row then
                if state.tab == "shared" then install_row(row) elseif state.tab == "installed" then open_row(row) end
            end
            changed()
        elseif kind == "install" and row then install_row(row)
        elseif kind == "open" and row then open_row(row)
        elseif kind == "update" and row then update_row(row)
        elseif kind == "remove" and row and row.component and row.origin == "hub" then remove_package(row.component)
        elseif kind == "search" then begin_editor("query")
        elseif kind == "keyword" then begin_editor("keyword")
        elseif kind == "developer_packages" then hub.toggle_developer_packages(hubs); changed()
        elseif kind == "technical" then model.toggle_technical(state); changed()
        elseif kind == "refresh" then load_tab()
        elseif kind == "operations_previous" then hub.set_operation_page(hubs, hubs.operation_page - 1); operation_history()
        elseif kind == "operations_next" then hub.set_operation_page(hubs, hubs.operation_page + 1); operation_history()
        elseif kind == "recover" then
            if apply_pending then ui.status = "An apply is still pending"
            else
                local problem = hub.recover(hubs)
                if problem then ui.status = problem else ui.offset = 0; invalidate() end
            end
            changed()
        else
            local tab = view.tab_of(kind)
            if tab then show_tab(tab) end
        end
    end
    local function version_hit(kind: string)
        ui.status = ""
        local row = model.selected_row(state)
        if kind == "install" and row then perform(function() install_now(row) end)
        elseif kind == "update" and row then update_row(row)
        elseif kind == "refresh" then perform(function() refresh_governed(); if row then open_version_now(row) end end)
        elseif kind == "technical" then model.toggle_technical(state); ui.offset = 0; changed()
        elseif kind == "back" then model.show_version(state, false); ui.offset = 0; changed()
        elseif kind == "accept" then perform(function() review_transition(true) end)
        elseif kind == "reject" then perform(function() review_transition(false) end)
        elseif kind == "select" then perform(select_transition)
        elseif kind == "prepare" then perform(prepare_transition)
        elseif kind == "step" then perform(step_now)
        elseif kind == "status" then perform(status_now)
        elseif kind == "recover" then perform(recover_now)
        else
            local tab = view.tab_of(kind)
            if tab then show_tab(tab) end
        end
    end
    local function package_hit(kind: string, key: string)
        ui.status = ""
        if kind == "contents" then
            if hubs.selected and hubs.selected_version then
                hub.show_requirements(hubs, false); ui.reading = false; ui.offset = 0
                begin({contents.start(ui.content, hubs.selected, hubs.selected_version)}); changed()
            end
        elseif kind == "content_row" or kind == "content_back" or kind == "content_next" or kind == "content_previous" then
            local intent: contents.Intent? = nil
            if kind == "content_back" and ui.content.mode == "entries" then
                ui.content.open = false; ui.reading = true; invalidate()
            elseif kind == "content_back" then intent = contents.back(ui.content)
            elseif kind == "content_next" then intent = contents.next(ui.content)
            elseif kind == "content_previous" then intent = contents.previous(ui.content)
            else intent = contents.activate(ui.content, key ~= "" and key or nil) end
            if intent then begin({intent}) end
            ui.offset = 0; changed()
        elseif kind == "save_editor" then finish_editor()
        elseif kind == "cancel_editor" then ui.editor = nil; ui.status = "Cancelled"; changed()
        elseif kind == "missing" then
            local measured = hubs.plan
            if hubs.phase == "plan" and measured then
                for _, id in ipairs(measured.missing) do
                    if key == "" or key == id then
                        ui.editor = {field = "parameter_value", buffer = "", name = id}
                        ui.status = "Enter a JSON value for " .. id
                        changed()
                        break
                    end
                end
            end
        elseif kind == "back" then leave_package()
        elseif kind == "recover" then
            if apply_pending then ui.status = "An apply is still pending" end
            changed()
        elseif kind == "requirements" then requirements()
        elseif kind == "reset_requirement" then
            local row = hubs.requirements[hubs.selected_requirement]
            if row and row.origin == "Selected" then
                hub.remove_parameter(hubs, row.id)
                invalidate()
                requirements()
                ui.status = "Override cleared"
            end
        elseif kind == "requirement" then
            for index, row in ipairs(hubs.requirements) do if row.id == key then hub.select_requirement(hubs, index); break end end
            edit_requirement()
        elseif kind == "readme" then ui.content.open = false; invalidate(); hub.show_requirements(hubs, false); ui.reading = true; ui.offset = 0; changed()
        elseif kind == "versions" then ui.content.open = false; invalidate(); hub.show_requirements(hubs, false); ui.reading = false; ui.offset = 0; changed()
        elseif kind == "details" then details()
        elseif kind == "plan" then plan()
        elseif kind == "version" then ui.content.open = false; hub.select_version(hubs, key); invalidate(); changed()
        elseif kind == "install" or kind == "update" or kind == "uninstall" then
            if kind == "update" and hubs.selected == "bee/bee" then update_bee(); return end
            ui.content.open = false; hub.set_action(hubs, kind); hub.show_requirements(hubs, false); ui.reading = false; ui.offset = 0; invalidate()
            -- Updating an existing root must use its current typed values. Read
            -- the authoritative inventory on demand; the normal read generation
            -- fence prevents a late snapshot from replacing newer user edits.
            if kind == "update" then hub.begin_update_hydration(hubs); begin({hub.installed_intent(hubs)}) end
            changed()
        elseif kind == "refresh_plan" then plan()
        elseif kind == "parameter" then begin_editor("parameter_name")
        elseif kind == "policy_none" then hub.set_policy(hubs, "none"); invalidate(); changed()
        elseif kind == "policy_up" then hub.set_policy(hubs, "up"); invalidate(); changed()
        elseif kind == "policy_block" then hub.set_policy(hubs, "block"); invalidate(); changed()
        elseif kind == "policy_leave" then hub.set_policy(hubs, "leave"); invalidate(); changed()
        elseif kind == "policy_down" then hub.set_policy(hubs, "down"); invalidate(); changed()
        elseif kind == "review" then local problem = hub.confirm(hubs); if problem then ui.status = problem end; changed()
        elseif kind == "confirm" then confirm()
        elseif kind == "cancel" then cancel_confirmation()
        elseif kind == "status" then check_status()
        else
            local tab = view.tab_of(kind)
            if tab then
                leave_package()
                show_tab(tab)
            end
        end
    end
    local function handle_hit(kind: string, key: string)
        local screen = view.screen(state)
        if ui.editor then package_hit(kind, key)
        elseif screen == "package" then package_hit(kind, key)
        elseif screen == "version" then version_hit(kind)
        else list_hit(kind, key) end
    end
    local function direction(data: {[string]: unknown}): integer
        return (data.button == "wheel_up" or data.button == "up") and -1 or 1
    end

    show_tab("installed")
    while running do
        if dirty then
            local display_ui: view.Ui = {offset = ui.offset, status = ui.editor and ui.status or (ui.status ~= "" and ui.status or state.notice),
                reading = ui.reading, editor = ui.editor, content = ui.content}
            local drawn = view.draw(width, height, preferences, state, display_ui)
            frame.render(drawn, menu, preferences)
            hits, ui.offset = drawn.hits, drawn.offset
            hub.set_operation_detail_offset(hubs, drawn.operation_detail_offset)
            visible_rows = math.floor(math.max(1, drawn.capacity))
            assert(output:present(drawn.rows, {cursor = {x = 1, y = 1, visible = false}}))
            dirty = false
        end
        local cases = {input:case_receive(), lifecycle:case_receive(), changes:case_receive(), updates:case_receive(), ticks:case_receive()}
        if reading then cases[#cases + 1] = reading.response:case_receive() end
        for _, item in ipairs(pending) do cases[#cases + 1] = item.response:case_receive() end
        local event = channel.select(cases)
        if not event.ok then break end
        if event.channel == lifecycle then
            if event.value.kind == process.event.CANCEL then running = false end
        elseif event.channel == updates then
            dirty = true
        elseif event.channel == ticks then
            -- Approval and installation finish elsewhere; while a version is on
            -- its way the list follows it.
            if not busy and view.screen(state) ~= "package" then
                for _, row in ipairs(model.rows(state, "installed")) do
                    if row.status == model.STATUS_WAITING or row.status == model.STATUS_INSTALLING then
                        perform(refresh_activations)
                        break
                    end
                end
            end
        elseif event.channel == changes then
            preferences = appearance.chosen(event.value:payload():data())
            changed()
        else
            local completed_read = reading
            if completed_read and event.channel == completed_read.response then
                reading = nil
                local value = completed({future = completed_read.future, response = completed_read.response, operation = completed_read.operation,
                    generation = completed_read.generation, apply = false})
                if not completed_read.retired and completed_read.generation == generation then fold_read(completed_read.operation, value) end
                start_next()
                changed()
            else
                local found: Pending? = nil
                for index, item in ipairs(pending) do
                    if event.channel == item.response then found = item; table.remove(pending, index); break end
                end
                if found then
                    local value = completed(found)
                    if found.apply then
                        apply_pending = false
                        ui.status = ""
                        hub.apply_result(hubs, value)
                    end
                    changed()
                else
                    local data, handled = frame.route(menu, event.value, ui.editor ~= nil)
                    if handled then changed() end
                    if data then
                        local screen = view.screen(state)
                        if data.type == "close" then running = false
                        elseif data.type == "resize" then width, height = data.width, data.height; changed()
                        elseif data.type == "key" and data.action ~= "release" then
                            local key, letter = data.key_type, tostring(data.key or "")
                            if key == "space" then letter = " " end
                            local editor = ui.editor
                            if editor then
                                if key == "esc" or key == "escape" then ui.editor = nil; ui.status = "Cancelled"; changed()
                                elseif key == "enter" then finish_editor()
                                elseif key == "backspace" then editor.buffer = previous(editor.buffer); ui.status = (editor.field == "parameter_value" and "Parameter JSON value: " or "Edit: ") .. editor.buffer; changed()
                                elseif (key == "runes" or #letter == 1) and #letter > 0 and not data.ctrl and not data.alt and not letter:find("%c") then editor.buffer = editable(editor.buffer .. letter); ui.status = (editor.field == "parameter_value" and "Parameter JSON value: " or "Edit: ") .. editor.buffer; changed() end
                            elseif screen == "package" then
                                ui.status = ""
                                local phase = hubs.phase
                                if phase == "details" and ui.content.open and (key == "up" or key == "down" or key == "pgup" or key == "pgdown") then
                                    local delta = (key == "up" or key == "pgup") and -1 or 1
                                    if #ui.content.rows > 0 then contents.move(ui.content, delta)
                                    else ui.offset = math.floor(math.max(0, ui.offset + delta * ((key == "pgup" or key == "pgdown") and 5 or 1))) end
                                    changed()
                                elseif phase == "details" and ui.content.open and key == "enter" then package_hit("content_row", "")
                                elseif phase == "details" and ui.content.open and (key == "backspace" or key == "esc" or key == "escape") then package_hit("content_back", "")
                                elseif phase == "details" and ui.content.open and letter == "n" then package_hit("content_next", "")
                                elseif letter == "c" and phase == "details" then package_hit("contents", "")
                                elseif key == "up" or letter == "k" then
                                    if (phase == "details" and ui.reading) or phase == "plan" or phase == "confirm" then ui.offset = math.floor(math.max(0, ui.offset - 1)); changed()
                                    elseif phase == "details" and hubs.requirements_open then hub.select_requirement(hubs, hubs.selected_requirement - 1); changed()
                                    elseif phase == "details" then version_relative(-1) end
                                elseif key == "down" or (letter == "j" and phase ~= "details") then
                                    if (phase == "details" and ui.reading) or phase == "plan" or phase == "confirm" then ui.offset = ui.offset + 1; changed()
                                    elseif phase == "details" and hubs.requirements_open then hub.select_requirement(hubs, hubs.selected_requirement + 1); changed()
                                    elseif phase == "details" then version_relative(1) end
                                elseif key == "left" and phase == "details" and hubs.detail then hub.set_detail_page(hubs, hubs.detail.page - 1); invalidate(); details()
                                elseif key == "right" and phase == "details" and hubs.detail then hub.set_detail_page(hubs, hubs.detail.page + 1); invalidate(); details()
                                elseif key == "enter" then
                                    if phase == "details" and hubs.requirements_open then edit_requirement()
                                    elseif phase == "plan" then package_hit("review", "")
                                    elseif phase == "confirm" then confirm() end
                                elseif key == "delete" and phase == "details" and hubs.requirements_open then package_hit("reset_requirement", "")
                                elseif letter == "e" and phase == "plan" then package_hit("missing", "")
                                elseif letter == "e" and phase == "details" then requirements()
                                elseif letter == "h" and phase == "details" then package_hit("readme", "")
                                elseif letter == "v" and phase == "details" then package_hit("versions", "")
                                elseif letter == "/" then begin_editor("query")
                                elseif letter == "j" and phase == "details" then begin_editor("parameter_name")
                                elseif letter == "i" and phase == "details" then package_hit("install", "")
                                elseif letter == "u" and phase == "details" then package_hit("update", "")
                                elseif letter == "x" and phase == "details" then package_hit("uninstall", "")
                                elseif letter == "p" and phase == "details" then plan()
                                elseif letter == "t" then model.toggle_technical(state); changed()
                                elseif letter == "r" then if phase == "result" then check_status() elseif phase == "plan" then plan() else changed() end
                                elseif key == "esc" or key == "escape" then
                                    if phase == "confirm" then cancel_confirmation() else leave_package() end
                                end
                            elseif screen == "version" then
                                ui.status = ""
                                local row = model.selected_row(state)
                                if key == "up" or letter == "k" then ui.offset = math.floor(math.max(0, ui.offset - 1)); changed()
                                elseif key == "down" or letter == "j" then ui.offset = ui.offset + 1; changed()
                                elseif key == "pgup" then ui.offset = math.floor(math.max(0, ui.offset - 8)); changed()
                                elseif key == "pgdown" then ui.offset = ui.offset + 8; changed()
                                elseif key == "enter" then
                                    local primary = view.actions(state, row)[1]
                                    if primary and primary.enabled then version_hit(primary.kind) end
                                elseif key == "tab" or letter == "\t" then
                                    local order = {installed = "shared", shared = "history", history = "installed"}
                                    show_tab(order[state.tab] :: model.Tab)
                                elseif letter == "t" then version_hit("technical")
                                elseif letter == "r" then version_hit("refresh")
                                elseif letter == "a" then version_hit("accept")
                                elseif letter == "n" then version_hit("reject")
                                elseif letter == "s" then version_hit("select")
                                elseif letter == "p" then version_hit("prepare")
                                elseif letter == "x" then version_hit("step")
                                elseif letter == "i" then version_hit("status")
                                elseif letter == "g" then version_hit("recover")
                                elseif key == "esc" or key == "escape" then version_hit("back") end
                            else
                                ui.status = ""
                                local row = model.selected_row(state)
                                if key == "tab" or letter == "\t" then
                                    local order = {installed = "shared", shared = "history", history = "installed"}
                                    show_tab(order[state.tab] :: model.Tab)
                                elseif key == "up" or letter == "k" and state.tab ~= "shared" then move_selection(-1)
                                elseif key == "down" or letter == "j" then move_selection(1)
                                elseif key == "pgup" then move_selection(-8)
                                elseif key == "pgdown" then move_selection(8)
                                elseif letter == "k" then begin_editor("keyword")
                                elseif key == "left" and state.tab == "shared" then hub.set_page(hubs, hubs.page - 1); invalidate(); load_tab()
                                elseif key == "right" and state.tab == "shared" then hub.set_page(hubs, hubs.page + 1); invalidate(); load_tab()
                                elseif key == "left" and state.tab == "history" then list_hit("operations_previous", "")
                                elseif key == "right" and state.tab == "history" then list_hit("operations_next", "")
                                elseif key == "enter" and row then
                                    if state.tab == "shared" then install_row(row)
                                    elseif state.tab == "installed" then open_row(row)
                                    else changed() end
                                elseif letter == "d" and row then open_row(row)
                                elseif letter == "u" then if row then update_row(row) end
                                elseif letter == "x" and row and row.component and row.origin == "hub" and state.tab == "installed" then remove_package(row.component)
                                elseif letter == "g" and state.tab == "history" then list_hit("recover", "")
                                elseif letter == "/" then begin_editor("query")
                                elseif letter == "t" then model.toggle_technical(state); changed()
                                elseif letter == "r" or letter == "f" then load_tab()
                                elseif key == "esc" or key == "escape" then running = false end
                            end
                        elseif data.type == "mouse" and data.action == "press" and data.button == "left" then
                            local hit = frame.hit(hits, math.floor(tonumber(data.x) or 1), math.floor(tonumber(data.y) or 1))
                            if hit then handle_hit(hit.kind, hit.key) end
                        elseif data.type == "mouse" and data.action == "wheel" then
                            local delta = (data.button == "wheel_up" or data.button == "up") and -1 or 1
                            if screen == "package" then
                                local phase = hubs.phase
                                if phase == "details" and ui.content.open then
                                    if #ui.content.rows > 0 then contents.move(ui.content, delta) else ui.offset = math.floor(math.max(0, ui.offset + delta * 3)) end
                                    changed()
                                elseif (phase == "details" and ui.reading) or phase == "plan" or phase == "confirm" then ui.offset = math.floor(math.max(0, ui.offset + delta * 3)); changed()
                                elseif phase == "details" and hubs.requirements_open then hub.select_requirement(hubs, hubs.selected_requirement + delta); changed()
                                elseif phase == "details" then version_relative(delta) end
                            elseif screen == "version" then ui.offset = math.floor(math.max(0, ui.offset + delta * 3)); changed()
                            else move_selection(delta) end
                        end
                    end
                end
            end
        end
    end
    if reading then reading.future:cancel() end
    for _, item in ipairs(pending) do item.future:cancel() end
    process.unlisten(changes)
    ticker:stop()
    updates:close()
    output:close()
    tty.stop()
end

return {main = main}
