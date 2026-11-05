-- MIT. The Library pointer and key actions: what a row, a button or a key
-- does on the list, version, package and platform screens, routed from the
-- hit a click lands on.
local client = require("client")
local confirmation = require("confirmation")
local model = require("model")
local governed = require("governed")
local hub = require("hub")
local view = require("view")
local contents = require("contents")
local session = require("session")
local reads = require("reads")
local package_flow = require("package_flow")
local delivery_actions = require("delivery_actions")
local M = {}
type Hits = {
    open_row: (model.Row) -> (), launch_row: (model.Row) -> (), ask_remove: (model.Row?, model.RemovalKind?) -> (),
    install_row: (model.Row) -> (), update_row: (model.Row) -> (), move_selection: (integer) -> (),
    list_hit: (string, string) -> (), platform_hit: (string, string) -> (), version_hit: (string) -> (), package_hit: (string, string) -> (), handle_hit: (string, string) -> (),
}

function M.new(ctx: session.Session, base: session.Base, actions: delivery_actions.Actions, feed: reads.Reads, flow: package_flow.Flow): Hits
    local state, hubs, gov, ui, review = ctx.state, ctx.hubs, ctx.gov, ctx.ui, ctx.review
    local changed, failure, invalidate, perform = base.changed, base.failure, base.invalidate, base.perform
    local begin = feed.begin
    local invoke, refresh_activations, refresh_governed = actions.invoke, actions.refresh_activations, actions.refresh_governed
    local remove_now, share_now, install_now, open_version_now = actions.remove_now, actions.share_now, actions.install_now, actions.open_version_now
    local review_transition, select_transition, prepare_transition = actions.review_transition, actions.select_transition, actions.prepare_transition
    local confirm_hub_now, step_now, status_now, recover_now = actions.confirm_hub_now, actions.step_now, actions.status_now, actions.recover_now
    local choose, details, requirements, plan = flow.choose, flow.details, flow.requirements, flow.plan
    local load_tab, show_tab, leave_package = flow.load_tab, flow.show_tab, flow.leave_package
    local update_bee, update_package, remove_package = flow.update_bee, flow.update_package, flow.remove_package
    local operation_history, check_status, open_hub_confirmation = flow.operation_history, flow.check_status, flow.open_hub_confirmation
    local confirm, cancel_confirmation, finish_editor, begin_editor, edit_requirement = flow.confirm, flow.cancel_confirmation, flow.finish_editor, flow.begin_editor, flow.edit_requirement
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
        if not ctx.launch or not row.application then state.notice = "This application can't be opened from here"; changed(); return end
        local _, problem = client.navigate(ctx.launch, row.application, nil)
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
        if index > ui.offset + ctx.visible_rows then ui.offset = math.floor(math.max(0, index - ctx.visible_rows)) end
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
            actions.forget_unnamed()
            load_tab()
        elseif kind == "operations_previous" then hub.set_operation_page(hubs, hubs.operation_page - 1); operation_history()
        elseif kind == "operations_next" then hub.set_operation_page(hubs, hubs.operation_page + 1); operation_history()
        elseif kind == "recover" then
            if ctx.apply_pending then ui.status = "An apply is still pending"
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
            if ctx.apply_pending then ui.status = "An apply is still pending" end
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
                local accepted, err = confirmation.accept(review, target, ctx.gesture)
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
    return {open_row = open_row, launch_row = launch_row, ask_remove = ask_remove, install_row = install_row, update_row = update_row,
        move_selection = move_selection, list_hit = list_hit, platform_hit = platform_hit, version_hit = version_hit, package_hit = package_hit, handle_hit = handle_hit}
end
return M
