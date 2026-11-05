-- MIT. The Library: one place for every application and driver a person can
-- install. Versions this bee's agents made and other bees shared arrive through
-- the destination facade; Hub packages through the Hub facade. The person
-- reviews and installs here; the approval decision belongs to the node's
-- approval owner, and package credentials and registry writes stay behind the
-- two facades.
local tty = require("tty")
local process = require("process")
local channel = require("channel")
local governance_changes = require("governance_changes")
local appearance = require("appearance")
local frame = require("frame")
local overlay = require("overlay")
local client = require("client")
local confirmation = require("confirmation")
local model = require("model")
local governed = require("governed")
local hub = require("hub")
local view = require("view")
local contents = require("contents")
local delivery_actions = require("delivery_actions")
local session = require("session")
local reads = require("reads")
local package_flow = require("package_flow")
local hits_actions = require("hits_actions")

-- The workspace the desktop that opened this app works in.
local function workspace_of(options: unknown): string
    local workspace = type(options) == "table" and options.workspace or nil
    local id = type(workspace) == "table" and workspace.id or nil
    if type(id) ~= "string" or id == "" then error("The Library needs the desktop's workspace") end
    return id
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
    local menu = overlay.menu()
    local lifecycle = assert(process.events())
    local changes = assert(process.listen(appearance.TOPIC, {message = true}))
    local committed_stream = governance_changes.activations()
    local committed = assert(committed_stream:channel())
    assert(tty.start())
    local output = assert(tty.surface())
    local width, height = tty.screen_size()
    local preferences = appearance.chosen(options)
    local state: model.State = model.new(workspace_of(options))
    local launch = client.launch(options)
    local review = confirmation.new({workspace_id = state.workspace_id, origin = {app_id = "bee.apps.library.app:app", instance_id = launch and launch.instance_id or "library", attempt_id = launch and launch.execution_id}})
    state.can_open = launch ~= nil
    local gov = state.governed
    local hubs = state.hub
    local ui: view.Ui = {offset = 0, status = "", reading = false, editor = nil, content = contents.new()}
    local hits: {frame.Hit} = {}
    local refresh_pending = false
    local updates: channel.Channel<boolean> = channel.new(1)
    -- Governed calls run one at a time in a worker, so a delayed owner never
    -- blocks the presentation loop. The worker carries the model operations;
    -- this loop remains responsible for frames, resize and cancellation.
    local ctx: session.Session = {state = state, hubs = hubs, gov = gov, ui = ui, review = review, launch = launch, updates = updates,
        pending = {}, reads = {}, reading = nil, generation = 0, running = true, dirty = true, busy = false, apply_pending = false,
        gesture = "shortcut", effect_gesture = "shortcut", visible_rows = 1}
    local base = session.new(ctx)
    local changed, failure, invalidate, background = base.changed, base.failure, base.invalidate, base.background
    -- The notice the screen in front of the person shows: the Hub's on its
    -- package screens, else this app's, else the Hub's last word.
    local function current_notice(): string
        if view.screen(state) == "package" then return hubs.notice end
        if state.notice ~= "" then return state.notice end
        return hubs.notice
    end
    local actions = delivery_actions.new(state, review, base.wake, {running = function(): boolean return ctx.running end, gesture = function() return ctx.effect_gesture end})
    local refresh_activations = actions.refresh_activations
    local feed = reads.new(ctx, base, actions)
    local flow = package_flow.new(ctx, base, actions, feed)
    local pointer = hits_actions.new(ctx, base, actions, feed, flow)
    local fold_read, start_next = feed.fold_read, feed.start_next
    local show_tab, load_tab, leave_package, tab_phase = flow.show_tab, flow.load_tab, flow.leave_package, flow.tab_phase
    local details, requirements, plan, remove_package = flow.details, flow.requirements, flow.plan, flow.remove_package
    local check_status, confirm, cancel_confirmation = flow.check_status, flow.confirm, flow.cancel_confirmation
    local version_relative, finish_editor, begin_editor, edit_requirement = flow.version_relative, flow.finish_editor, flow.begin_editor, flow.edit_requirement
    local open_row, launch_row, ask_remove, install_row, update_row = pointer.open_row, pointer.launch_row, pointer.ask_remove, pointer.install_row, pointer.update_row
    local move_selection, list_hit, version_hit, package_hit, platform_hit, handle_hit = pointer.move_selection, pointer.list_hit, pointer.version_hit, pointer.package_hit, pointer.platform_hit, pointer.handle_hit

    show_tab("installed")
    while ctx.running do
        if ctx.dirty then
            local display_ui: view.Ui = {offset = ui.offset, status = ui.editor and ui.status or (ui.status ~= "" and ui.status or current_notice()),
                reading = ui.reading, editor = ui.editor, content = ui.content}
            local drawn = view.draw(width, height, preferences, state, display_ui)
            overlay.render(drawn, menu, preferences)
            hits, ui.offset = drawn.hits, drawn.offset
            hub.set_operation_detail_offset(hubs, drawn.operation_detail_offset)
            ctx.visible_rows = math.floor(math.max(1, drawn.capacity))
            assert(output:present(drawn.rows, {cursor = {x = 1, y = 1, visible = false}}))
            ctx.dirty = false
        end
        local cases = {input:case_receive(), lifecycle:case_receive(), changes:case_receive(), updates:case_receive(), committed:case_receive()}
        if ctx.reading then cases[#cases + 1] = ctx.reading.response:case_receive() end
        for _, item in ipairs(ctx.pending) do cases[#cases + 1] = item.response:case_receive() end
        local event = channel.select(cases)
        if not event.ok then break end
        if event.channel == lifecycle then
            if event.value.kind == process.event.CANCEL then ctx.running = false end
        elseif event.channel == ctx.updates or event.channel == committed then
            ctx.dirty = true
            if event.channel == committed then refresh_pending = true end
            if refresh_pending and not ctx.busy then
                refresh_pending = false
                background(refresh_activations)
            end
        elseif event.channel == changes then
            preferences = appearance.chosen(event.value:payload():data())
            changed()
        else
            local completed_read = ctx.reading
            if completed_read and event.channel == completed_read.response then
                ctx.reading = nil
                local value = session.completed({future = completed_read.future, response = completed_read.response, operation = completed_read.operation,
                    generation = completed_read.generation, apply = false})
                if not completed_read.retired and completed_read.generation == ctx.generation then fold_read(completed_read.operation, value) end
                start_next()
                changed()
            else
                local found: session.Pending? = nil
                for index, item in ipairs(ctx.pending) do
                    if event.channel == item.response then found = item; table.remove(ctx.pending, index); break end
                end
                if found then
                    local value = session.completed(found)
                    if found.apply then
                        ctx.apply_pending = false
                        ui.status = ""
                        hub.apply_result(hubs, value)
                        if not value.ok then failure((value.code or "FAILED") .. ": " .. (value.full_message or value.message or "Hub apply failed")) end
                    end
                    changed()
                else
                    local data, handled = overlay.route(menu, event.value, ui.editor ~= nil)
                    if handled then changed() end
                    if data then
                        ctx.gesture = confirmation.gesture(data)
                        local screen = view.screen(state)
                        if data.type == "close" then ctx.running = false
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
                                elseif key == "esc" or key == "escape" then ctx.running = false end
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
    if ctx.reading then ctx.reading.future:cancel() end
    for _, item in ipairs(ctx.pending) do item.future:cancel() end
    process.unlisten(changes)
    confirmation.cancel(review)
    committed_stream:close()
    ctx.updates:close()
    output:close()
    tty.stop()
end

return {main = main}
