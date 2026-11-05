-- MIT. The Library navigation and Hub package flow: tab loading, package
-- details, requirements, the review and confirmation of a plan, and the
-- editor behind search, keyword and parameter fields.
local json = require("json")
local confirmation = require("confirmation")
local model = require("model")
local governed = require("governed")
local hub = require("hub")
local session = require("session")
local reads = require("reads")
local delivery_actions = require("delivery_actions")
local M = {}
type Flow = {
    tab_phase: (model.Tab) -> hub.Phase, load_tab: () -> (), show_tab: (model.Tab) -> (), leave_package: () -> (), details: () -> (),
    requirements: () -> (), plan: () -> (), update_bee: () -> (), update_package: (string, string) -> (), remove_package: (string) -> (),
    operation_history: () -> (), check_status: () -> (), open_hub_confirmation: () -> boolean, confirm: () -> (),
    choose: (string) -> (), cancel_confirmation: () -> (), version_relative: (integer) -> (), finish_editor: () -> (),
    begin_editor: (string) -> (), edit_requirement: () -> (),
}

function M.new(ctx: session.Session, base: session.Base, actions: delivery_actions.Actions, feed: reads.Reads): Flow
    local state, hubs, gov, ui, review = ctx.state, ctx.hubs, ctx.gov, ctx.ui, ctx.review
    local changed, invalidate, perform = base.changed, base.invalidate, base.perform
    local begin, begin_apply = feed.begin, feed.begin_apply
    local refresh_governed = actions.refresh_governed
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
        if ctx.busy then ui.status = "Request in progress; review when it finishes"; changed(); return end
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
        if ctx.apply_pending then ui.status = "Applying is still pending; check the status if the result is uncertain"; changed(); return end
        local intent, problem = hub.confirm_intent(hubs)
        if not intent then ui.status = problem or "These changes cannot be applied"; changed(); return end
        local target = hub_target()
        if not target then ui.status = "Confirmation target is unavailable"; changed(); return end
        local accepted, err = confirmation.accept(review, target, ctx.gesture)
        if not accepted then ui.status = err or "Confirmation failed"; changed(); return end
        ctx.apply_pending = true
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
        if next_index > ui.offset + ctx.visible_rows then ui.offset = math.floor(math.max(0, next_index - ctx.visible_rows)) end
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

    return {tab_phase = tab_phase, load_tab = load_tab, show_tab = show_tab, leave_package = leave_package, details = details,
        requirements = requirements, plan = plan, update_bee = update_bee, update_package = update_package, remove_package = remove_package,
        operation_history = operation_history, check_status = check_status, open_hub_confirmation = open_hub_confirmation, confirm = confirm,
        choose = choose, cancel_confirmation = cancel_confirmation, version_relative = version_relative, finish_editor = finish_editor,
        begin_editor = begin_editor, edit_requirement = edit_requirement}
end
return M
