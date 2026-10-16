-- MIT. The Library: one place for every application and driver a person can
-- install. Versions this bee's agents made and other bees shared arrive through
-- the destination facade; Hub packages through the Hub facade. The person
-- reviews and installs here; the approval decision belongs to the node's
-- approval owner, and package credentials and registry writes stay behind the
-- two facades.
local tty = require("tty")
local json = require("json")
local process = require("process")
local channel = require("channel")
local funcs = require("funcs")
local cdc = require("cdc")
local appearance = require("appearance")
local frame = require("frame")
local client = require("client")
local confirmation = require("confirmation")
local model = require("model")
local governed = require("governed")
local hub = require("hub")
local view = require("view")
local contents = require("contents")

local delivery_actions = require("delivery_actions")
local new_key = delivery_actions.new_key
type Object = {[string]: unknown}
type Reply = {ok: boolean, code: string?, message: string?, full_message: string?, value: unknown, replayed: boolean}
type Pending = {future: funcs.Future, response: channel.Channel, operation: string, generation: integer, apply: boolean}
type ReadPending = {future: funcs.Future, response: channel.Channel, operation: string, generation: integer, retired: boolean}


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
            message = type(raw.message) == "string" and raw.message or nil,
            full_message = type(raw.full_message) == "string" and raw.full_message or nil, value = raw.value}
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
    local committed_stream = assert(cdc.stream("bee:changes", {tables = {
        "bee_governance_activation_execution", "bee_governance_follow_progress",
        "bee_governance_activation_intents",
    }}))
    local committed = assert(committed_stream:channel())
    assert(tty.start())
    local output = assert(tty.surface())
    local width, height = tty.screen_size()
    local preferences = appearance.chosen(options)
    local state: model.State = model.new(workspace_of(options))
    local launch = client.launch(options)
    local review = confirmation.new({workspace_id = state.workspace_id, origin = {app_id = "bee.apps.library.app:app", instance_id = launch and launch.instance_id or "library", attempt_id = launch and launch.execution_id}})
    local gesture: "enter" | "space" | "click" | "shortcut" = "shortcut"
    local effect_gesture: "enter" | "space" | "click" | "shortcut" = "shortcut"
    state.can_open = launch ~= nil
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
    local refresh_pending = false

    local function changed()
        dirty = true
    end
    -- The notice the screen in front of the person shows: the Hub's on its
    -- package screens, else this app's, else the Hub's last word.
    local function current_notice(): string
        if view.screen(state) == "package" then return hubs.notice end
        if state.notice ~= "" then return state.notice end
        return hubs.notice
    end
    local function failure(reason: string)
        ui.status = reason
        state.notice, hubs.notice, gov.fault = reason, reason, reason
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
        effect_gesture = gesture
        ui.status = "Working…"
        dirty = true
        coroutine.spawn(function()
            local ok, problem = pcall(operation)
            busy = false
            if not running then return end
            if not ok then
                failure(tostring(problem))
            elseif ui.status == "Working…" then ui.status = "" end
            wake()
        end)
        return true
    end
    -- background runs a read without announcing work, so the footer stays still
    -- while the list follows an install.
    local function background(operation: () -> ())
        if busy then return end
        busy = true
        coroutine.spawn(function()
            pcall(operation)
            busy = false
            if running then wake() end
        end)
    end
    local actions = delivery_actions.new(state, review, wake, {running = function(): boolean return running end, gesture = function() return effect_gesture end})
    local invoke = actions.invoke
    local refresh_activations = actions.refresh_activations
    local refresh_governed = actions.refresh_governed
    local remove_now = actions.remove_now
    local share_now = actions.share_now
    local review_transition = actions.review_transition
    local select_transition = actions.select_transition
    local prepare_transition = actions.prepare_transition
    local install_now = actions.install_now
    local review_hub_now = actions.review_hub_now
    local confirm_hub_now = actions.confirm_hub_now
    local step_now = actions.step_now
    local status_now = actions.status_now
    local recover_now = actions.recover_now
    local open_version_now = actions.open_version_now
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
        elseif operation == "plan" then
            ui.status = ""
            local request, problem = hub.governed_request(hubs, value, state.workspace_id, new_key())
            if request then perform(function() review_hub_now(request) end)
            elseif problem then hubs.notice, gov.fault = problem, problem
            else
                hub.apply_plan(hubs, value)
                if hubs.requirements_open and hubs.phase == "details" then
                    ui.content.open, ui.reading, ui.offset = false, false, 0
                    if not hubs.detail then
                        local detail = hub.details_intent(hubs)
                        if detail then table.insert(reads, 1, detail) end
                    end
                end
                gov.fault = hubs.notice
            end
        elseif operation == "status" then hub.apply_result(hubs, value)
        elseif operation == "history" then hub.apply_history(hubs, value) end
        if not value.ok then
            failure((value.code or "UNAVAILABLE") .. ": " .. (value.full_message or value.message or "Hub read failed"))
        elseif operation == "state" or operation == "files" or operation == "read_file" then
            if ui.content.fault ~= "" then failure(ui.content.fault) end
        elseif operation ~= "status" and hubs.notice ~= "" and hubs.notice ~= "Installed settings loaded" then
            failure(hubs.notice)
        end
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
            failure(hubs.result and hubs.result.message or "Hub apply unavailable")
            apply_pending = false
            changed()
            return false
        end
        local response = future:response()
        if not response then
            future:cancel()
            hub.apply_result(hubs, {ok = false, replayed = false, code = "UNCERTAIN", message = "Hub response channel unavailable", value = nil})
            failure(hubs.result and hubs.result.message or "Hub apply unavailable")
            apply_pending = false
            changed()
            return false
        end
        pending[#pending + 1] = {future = future, response = response, operation = intent.operation, generation = 0, apply = true}
        return true
    end

    -- tab_phase is the Hub phase a tab's list stands on.
    local function tab_phase(tab: model.Tab): hub.Phase
        if tab == "installed" then return "installed" end
        if tab == "shared" then return "catalog" end
        return "operations"
    end
    local function load_tab()
        ui.offset, ui.reading = 0, false
        ui.content.open = false
        hub.show(hubs, tab_phase(state.tab))
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
        hub.show(hubs, tab_phase(state.tab))
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
        hub.show(hubs, "details")
        hub.show_requirements(hubs, true)
        ui.reading, ui.offset = false, 0
        local intent = hub.inspect_intent(hubs)
        if hubs.requirements_digest then changed(); return end
        if intent then begin({intent})
        elseif hubs.action == "update" then ui.status = "Read installed settings before inspecting this update"
        else ui.status = "Choose a version first" end
        changed()
    end
    local function plan()
        if busy then ui.status = "Request in progress; review when it finishes"; changed(); return end
        local intent, problem = hub.plan_intent(hubs)
        if not intent then
            ui.status = problem or "Cannot review these changes"
            hubs.notice, gov.fault = ui.status, ui.status
            changed(); return
        end
        hub.begin_plan(hubs)
        governed.select(gov, nil)
        ui.status = "Reading changes…"
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
    local function hub_target(): {[string]: unknown}?
        local intent = hub.confirm_intent(hubs)
        if not intent then return nil end
        return {digest = intent.expected_digest, action = hubs.action, component = hubs.selected,
            recovery_id = hubs.recovery and hubs.recovery.digest or nil}
    end
    local function open_hub_confirmation(): boolean
        local target = hub_target()
        if not target then ui.status = "Confirmation target is unavailable"; changed(); return false end
        local opened, err = confirmation.open(review, hubs.recovery and "hub.recover" or "hub.apply", target, "inline", "Confirm package changes", "Apply exactly the displayed changes")
        if not opened then ui.status = err or "Confirmation is unavailable" end
        changed()
        return opened
    end
    local function confirm()
        if apply_pending then ui.status = "Applying is still pending; check the status if the result is uncertain"; changed(); return end
        local intent, problem = hub.confirm_intent(hubs)
        if not intent then ui.status = problem or "These changes cannot be applied"; changed(); return end
        local target = hub_target()
        if not target then ui.status = "Confirmation target is unavailable"; changed(); return end
        local accepted, err = confirmation.accept(review, target, gesture)
        if not accepted then ui.status = err or "Confirmation failed"; changed(); return end
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
    local function cancel_confirmation()
        confirmation.cancel(review)
        if hubs.recovery then
            model.show_tab(state, "history")
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
        elseif active.field == "configuration" then
            local problem = hub.set_field(hubs, active.name or "", active.buffer)
            if problem then ui.status, gov.fault = problem, problem; changed(); return end
            ui.status = "Field saved"
            invalidate()
            changed()
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
        else
            local row = hubs.requirements[hubs.selected_requirement]
            if hubs.requirements_open and row and row.field then
                local root = row.field.root
                local buffer = ""
                for _, parameter in ipairs(hubs.parameters) do if parameter.name == root then buffer = parameter.json end end
                if buffer == "" then
                    for _, declaration in ipairs(hubs.configuration or {}) do
                        if declaration.id == root then buffer = json.encode(declaration.default) or "" end
                    end
                end
                ui.editor = {field = "parameter_value", buffer = buffer, name = root}
                ui.status = "Advanced JSON: " .. root
            else ui.editor = {field = "parameter_name", buffer = ""}; ui.status = "Parameter name (namespace:name): " end
        end
        changed()
    end
    local function edit_requirement()
        local row = hubs.requirements[hubs.selected_requirement]
        if not row then ui.status = "Select a requirement first"; changed(); return end
        local field = row.field
        if field and (#field.choices > 0 or field.kind == "boolean") then
            local problem = hub.cycle_field(hubs, row.id, 1)
            ui.status = problem or "Field saved"
            if problem then gov.fault = problem end
        elseif field and field.kind == "object" and #field.choices == 0 then
            hub.select_requirement(hubs, hubs.selected_requirement + 1)
            ui.status = "Choose a field below; J opens Advanced JSON"
        elseif field and field.kind == "array" and type(field.schema.items) == "table"
            and (field.schema.items.type == "object" or field.schema.items.type == "array") then
            ui.status = hub.add_field_item(hubs, row.id) or "Item added; configure its fields below"
        else
            ui.editor = {field = "configuration", buffer = hub.field_buffer(row), name = row.id}
            ui.status = "Edit " .. row.id
        end
        changed()
    end

    -- The row a click or key acts on, activated by its origin.
    local function open_row(row: model.Row)
        if row.kind == "platform" then
            model.show_platform(state, true); ui.offset = 0; changed()
        elseif row.kind == "section" then
            state.hub_open = not state.hub_open; changed()
        elseif row.origin == "hub" then
            if row.component then choose(row.component) end
        else
            perform(function() open_version_now(row) end)
            model.show_version(state, true)
            ui.offset = 0
            changed()
        end
    end
    local function launch_row(row: model.Row)
        if not launch or not row.application then state.notice = "This application can't be opened from here"; changed(); return end
        local _, problem = client.navigate(launch, row.application, nil)
        state.notice = problem and "This application did not open; try again" or ("Opening " .. row.name)
        if problem then gov.fault = problem end
        changed()
    end
    local function ask_remove(row: model.Row?, kind: model.RemovalKind?)
        if row and model.ask_remove(state, row, kind) then
            local removal = assert(state.removal)
            local opened, err = confirmation.open(review, "library." .. removal.kind,
                {app = removal.app, version = removal.version, baseline = removal.baseline, installed_intent_id = row.intent_id},
                "dialog", removal.kind == "back" and "Go back?" or "Remove application?", table.concat(model.removal_lines(removal), "\n"))
            if not opened then model.cancel_remove(state); state.notice = err or "Confirmation is unavailable" end
            changed(); return
        end
        state.notice = kind == "back" and "There is no earlier version to go back to" or "This can't be removed from here"
        changed()
    end
    local function install_row(row: model.Row)
        if row.origin == "hub" then open_row(row)
        else perform(function() install_now(row) end) end
    end
    local function update_row(row: model.Row)
        if not model.can_update(row) or not row.update then return end
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
        elseif kind == "remove" and row and row.component and model.can_remove_package(row) then remove_package(row.component)
        elseif kind == "remove" and row and row.origin == "governed" then ask_remove(row, "remove")
        elseif kind == "go_back" and row then ask_remove(row, "back")
        elseif kind == "share" and row then perform(function() share_now(row) end)
        elseif kind == "launch" and row then launch_row(row)
        elseif kind == "hub_catalog" then
            state.hub_open = not state.hub_open
            changed()
        elseif kind == "platform" then
            model.show_platform(state, true); ui.offset = 0; changed()
        elseif kind == "search" then begin_editor("query")
        elseif kind == "keyword" then begin_editor("keyword")
        elseif kind == "developer_packages" then hub.toggle_developer_packages(hubs); changed()
        elseif kind == "technical" then model.toggle_technical(state); changed()
        elseif kind == "refresh" then
            for node in pairs(asked) do if gov.names[node] == nil then asked[node] = nil end end
            load_tab()
        elseif kind == "operations_previous" then hub.set_operation_page(hubs, hubs.operation_page - 1); operation_history()
        elseif kind == "operations_next" then hub.set_operation_page(hubs, hubs.operation_page + 1); operation_history()
        elseif kind == "recover" then
            if apply_pending then ui.status = "An apply is still pending"
            else
                if row and row.operation then hub.select_operation(hubs, row.operation) end
                local problem = hub.recover(hubs)
                if problem then ui.status = problem else ui.offset = 0; invalidate(); open_hub_confirmation() end
            end
            changed()
        else
            local tab = view.tab_of(kind)
            if tab then show_tab(tab) end
        end
    end
    local function follow_now(row: model.Row, mode: string)
        if not model.can_follow(row) or not row.source_node or not row.app or not row.component then return end
        local answer = invoke(governed.follow_request(gov, row.source_node, row.app, row.component, mode))
        if answer and answer.ok then
            refresh_activations()
            state.notice = mode == "following" and "Following source" or (mode == "paused" and "Updates paused" or "Version pinned")
        else state.notice = answer and answer.error and answer.error.message or "Following choice did not finish" end
    end
    local function version_hit(kind: string)
        ui.status = ""
        local row = model.selected_row(state)
        if kind == "install" and row then perform(function() install_now(row) end)
        elseif kind == "install_follow" and row then perform(function() install_now(row, true) end)
        elseif kind == "follow" and row then perform(function() follow_now(row, "following") end)
        elseif kind == "pause_follow" and row then perform(function() follow_now(row, "paused") end)
        elseif kind == "pin_follow" and row then perform(function() follow_now(row, "pinned") end)
        elseif kind == "update" and row then update_row(row)
        elseif kind == "refresh" then perform(function() refresh_governed(); if row then open_version_now(row) end end)
        elseif kind == "technical" then model.toggle_technical(state); ui.offset = 0; changed()
        elseif kind == "remove" then ask_remove(row, "remove")
        elseif kind == "go_back" then ask_remove(row, "back")
        elseif kind == "share" and row then perform(function() share_now(row) end)
        elseif kind == "launch" and row then launch_row(row)
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
        if kind == "technical" then model.toggle_technical(state); ui.offset = 0; changed()
        elseif kind == "contents" then
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
            requirements()
            for index, row in ipairs(hubs.requirements) do
                if row.id == key or (key == "" and row.origin == "Missing") then hub.select_requirement(hubs, index); break end
            end
        elseif kind == "back" then leave_package()
        elseif kind == "recover" then
            if apply_pending then ui.status = "An apply is still pending" end
            changed()
        elseif kind == "requirements" then requirements()
        elseif kind == "reset_requirement" then
            local row = hubs.requirements[hubs.selected_requirement]
            if row and row.origin == "Selected" then
                hub.remove_parameter(hubs, row.field and row.field.root or row.id)
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
        elseif kind == "parameter" then requirements()
        elseif kind == "policy_none" then hub.set_policy(hubs, "none"); invalidate(); changed()
        elseif kind == "policy_up" then hub.set_policy(hubs, "up"); invalidate(); changed()
        elseif kind == "policy_block" then hub.set_policy(hubs, "block"); invalidate(); changed()
        elseif kind == "policy_leave" then hub.set_policy(hubs, "leave"); invalidate(); changed()
        elseif kind == "policy_down" then hub.set_policy(hubs, "down"); invalidate(); changed()
        elseif kind == "review" then local problem = hub.confirm(hubs); if problem then failure(problem) else open_hub_confirmation() end; changed()
        elseif kind == "install_governed" then perform(confirm_hub_now)
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
    local function platform_hit(kind: string, key: string)
        ui.status = ""
        local row = model.selected_row(state)
        if kind == "row" then
            local was = row and row.key == key
            model.select(state, key)
            row = model.selected_row(state)
            if was and row then open_row(row) end
            changed()
        elseif kind == "open" and row then open_row(row)
        elseif kind == "back" then model.show_platform(state, false); ui.offset = 0; changed()
        else
            local tab = view.tab_of(kind)
            if tab then show_tab(tab) end
        end
    end
    local function handle_hit(kind: string, key: string)
        local screen = view.screen(state)
        local removal = state.removal
        if removal then
            if kind == "confirm_remove" then
                local current: model.Row? = nil
                for _, row in ipairs(model.rows(state)) do if row.app == removal.app and row.version == removal.version then current = row end end
                local target = {app = removal.app, version = current and current.version or "", baseline = current and current.baseline,
                    installed_intent_id = current and current.intent_id}
                local accepted, err = confirmation.accept(review, target, gesture)
                if accepted then
                    model.cancel_remove(state)
                    perform(function() remove_now(removal) end)
                else state.notice = err or "Confirmation failed"; changed() end
            elseif kind == "cancel_remove" then confirmation.cancel(review); model.cancel_remove(state); state.notice = "Kept"; changed() end
        elseif ui.editor then package_hit(kind, key)
        elseif screen == "package" then package_hit(kind, key)
        elseif screen == "version" then version_hit(kind)
        elseif screen == "platform" then platform_hit(kind, key)
        else list_hit(kind, key) end
    end

    show_tab("installed")
    while running do
        if dirty then
            local display_ui: view.Ui = {offset = ui.offset, status = ui.editor and ui.status or (ui.status ~= "" and ui.status or current_notice()),
                reading = ui.reading, editor = ui.editor, content = ui.content}
            local drawn = view.draw(width, height, preferences, state, display_ui)
            frame.render(drawn, menu, preferences)
            hits, ui.offset = drawn.hits, drawn.offset
            hub.set_operation_detail_offset(hubs, drawn.operation_detail_offset)
            visible_rows = math.floor(math.max(1, drawn.capacity))
            assert(output:present(drawn.rows, {cursor = {x = 1, y = 1, visible = false}}))
            dirty = false
        end
        local cases = {input:case_receive(), lifecycle:case_receive(), changes:case_receive(), updates:case_receive(), committed:case_receive()}
        if reading then cases[#cases + 1] = reading.response:case_receive() end
        for _, item in ipairs(pending) do cases[#cases + 1] = item.response:case_receive() end
        local event = channel.select(cases)
        if not event.ok then break end
        if event.channel == lifecycle then
            if event.value.kind == process.event.CANCEL then running = false end
        elseif event.channel == updates or event.channel == committed then
            dirty = true
            if event.channel == committed then refresh_pending = true end
            if refresh_pending and not busy then
                refresh_pending = false
                background(refresh_activations)
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
                        if not value.ok then failure((value.code or "FAILED") .. ": " .. (value.full_message or value.message or "Hub apply failed")) end
                    end
                    changed()
                else
                    local data, handled = frame.route(menu, event.value, ui.editor ~= nil)
                    if handled then changed() end
                    if data then
                        gesture = confirmation.gesture(data)
                        local screen = view.screen(state)
                        if data.type == "close" then running = false
                        elseif data.type == "resize" then width, height = data.width, data.height; changed()
                        elseif data.type == "key" and data.action ~= "release" then
                            local key, letter = data.key_type, tostring(data.key or "")
                            if key == "space" then letter = " " end
                            local diagnostic = gov.technical and (gov.fault ~= "" and gov.fault or hub.update_reason(hubs, hubs.selected))
                            local editor = ui.editor
                            local removal = state.removal
                            if removal then
                                if key == "enter" then handle_hit("confirm_remove", "")
                                elseif key == "esc" or key == "escape" then handle_hit("cancel_remove", "") end
                            elseif editor then
                                if key == "esc" or key == "escape" then ui.editor = nil; ui.status = "Cancelled"; changed()
                                elseif key == "enter" then finish_editor()
                                elseif key == "backspace" then editor.buffer = previous(editor.buffer); ui.status = (editor.field == "parameter_value" and "Parameter JSON value: " or "Edit: ") .. editor.buffer; changed()
                                elseif (key == "runes" or #letter == 1) and #letter > 0 and not data.ctrl and not data.alt and not letter:find("%c") then editor.buffer = editable(editor.buffer .. letter); ui.status = (editor.field == "parameter_value" and "Parameter JSON value: " or "Edit: ") .. editor.buffer; changed() end
                            elseif diagnostic and (key == "up" or key == "down" or key == "pgup" or key == "pgdown") then
                                local delta = (key == "up" or key == "pgup") and -1 or 1
                                ui.offset = math.floor(math.max(0, ui.offset + delta * ((key == "pgup" or key == "pgdown") and 8 or 1)))
                                changed()
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
                                elseif (key == "left" or key == "right") and phase == "details" and hubs.requirements_open then
                                    local row = hubs.requirements[hubs.selected_requirement]
                                    if row then
                                        ui.status = hub.cycle_field(hubs, row.id, key == "left" and -1 or 1) or "Field saved"
                                        changed()
                                    end
                                elseif key == "left" and phase == "details" and hubs.detail then hub.set_detail_page(hubs, hubs.detail.page - 1); invalidate(); details()
                                elseif key == "right" and phase == "details" and hubs.detail then hub.set_detail_page(hubs, hubs.detail.page + 1); invalidate(); details()
                                elseif key == "enter" then
                                    if phase == "details" and hubs.requirements_open then edit_requirement()
                                    elseif phase == "plan" then
                                        local selected = governed.selected(gov)
                                        if selected and selected.source_workspace == "hub:" .. tostring(hubs.selected) then package_hit("install_governed", "")
                                        else package_hit("review", "") end
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
                                elseif letter == "t" then package_hit("technical", "")
                                elseif letter == "r" then if phase == "result" then check_status() elseif phase == "plan" then plan() elseif phase == "details" then details() else changed() end
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
                                    local order: {installed: model.Tab, shared: model.Tab, history: model.Tab} = {installed = "shared", shared = "history", history = "installed"}
                                    show_tab(order[state.tab])
                                elseif letter == "f" and model.can_follow(row) and row then
                                    version_hit(row.status == model.STATUS_SHARED and "install_follow" or (row.follow_state == "following" and "pause_follow" or "follow"))
                                elseif letter == "v" and model.can_follow(row) then version_hit("pin_follow")
                                elseif letter == "t" then version_hit("technical")
                                elseif letter == "r" then version_hit("refresh")
                                elseif letter == "a" then version_hit("accept")
                                elseif letter == "n" then version_hit("reject")
                                elseif letter == "s" then version_hit("select")
                                elseif letter == "p" then version_hit("prepare")
                                elseif letter == "x" then version_hit(state.governed.technical and "step" or "remove")
                                elseif letter == "l" then version_hit("launch")
                                elseif letter == "b" then version_hit("go_back")
                                elseif letter == "h" then version_hit("share")
                                elseif letter == "i" then version_hit("status")
                                elseif letter == "g" then version_hit("recover")
                                elseif key == "esc" or key == "escape" then version_hit("back") end
                            elseif screen == "platform" then
                                ui.status = ""
                                if key == "up" or letter == "k" then move_selection(-1)
                                elseif key == "down" or letter == "j" then move_selection(1)
                                elseif key == "enter" then platform_hit("open", "")
                                elseif key == "esc" or key == "escape" then platform_hit("back", "") end
                            else
                                ui.status = ""
                                local row = model.selected_row(state)
                                if key == "tab" or letter == "\t" then
                                    local order: {installed: model.Tab, shared: model.Tab, history: model.Tab} = {installed = "shared", shared = "history", history = "installed"}
                                    show_tab(order[state.tab])
                                elseif key == "enter" and row and state.tab == "installed" and row.origin == "governed" and row.application then launch_row(row)
                                elseif letter == "k" and hub.keyword_phase(tab_phase(state.tab)) then begin_editor("keyword")
                                elseif key == "up" or letter == "k" then move_selection(-1)
                                elseif key == "down" or letter == "j" then move_selection(1)
                                elseif key == "pgup" then move_selection(-8)
                                elseif key == "pgdown" then move_selection(8)
                                elseif key == "left" and state.tab == "shared" then hub.set_page(hubs, hubs.page - 1); invalidate(); load_tab()
                                elseif key == "right" and state.tab == "shared" then hub.set_page(hubs, hubs.page + 1); invalidate(); load_tab()
                                elseif key == "left" and state.tab == "history" then list_hit("operations_previous", "")
                                elseif key == "right" and state.tab == "history" then list_hit("operations_next", "")
                                elseif key == "enter" and row then
                                    if state.tab == "shared" then install_row(row)
                                    elseif state.tab == "installed" then open_row(row)
                                    else changed() end
                                elseif (letter == "o" or letter == "d") and row then open_row(row)
                                elseif letter == "u" then if row then update_row(row) end
                                elseif letter == "x" and row and state.tab == "installed" then
                                    if model.can_remove_package(row) and row.component then remove_package(row.component) elseif row.origin == "governed" then ask_remove(row, "remove") end
                                elseif letter == "b" and row and state.tab == "installed" then ask_remove(row, "back")
                                elseif letter == "h" and row and state.tab == "installed" then list_hit("share", "")
                                elseif letter == "g" and state.tab == "history" then list_hit("recover", "")
                                elseif letter == "h" and state.tab == "shared" then list_hit("hub_catalog", "")
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
                            if gov.technical and (gov.fault ~= "" or hub.update_reason(hubs, hubs.selected)) then
                                ui.offset = math.floor(math.max(0, ui.offset + delta * 3)); changed()
                            elseif screen == "package" then
                                local phase = hubs.phase
                                if phase == "details" and ui.content.open then
                                    if #ui.content.rows > 0 then contents.move(ui.content, delta) else ui.offset = math.floor(math.max(0, ui.offset + delta * 3)) end
                                    changed()
                                elseif (phase == "details" and ui.reading) or phase == "plan" or phase == "confirm" then ui.offset = math.floor(math.max(0, ui.offset + delta * 3)); changed()
                                elseif phase == "details" and hubs.requirements_open then hub.select_requirement(hubs, hubs.selected_requirement + delta); changed()
                                elseif phase == "details" then version_relative(delta) end
                            elseif screen == "version" then ui.offset = math.floor(math.max(0, ui.offset + delta * 3)); changed()
                            elseif screen == "platform" then move_selection(delta)
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
    confirmation.cancel(review)
    committed_stream:close()
    updates:close()
    output:close()
    tty.stop()
end

return {main = main}
