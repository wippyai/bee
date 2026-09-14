local tty = require("tty")
local logger = require("logger")
local log = logger:named("bee.presenter")
local title_editor = require("title_editor")
local dialog = require("dialog")
local interaction = require("interaction")
local ctx = require("ctx")
local contract = require("contract")
local process = require("process")
local status_surface = require("status_surface")
local channel = require("channel")
local time = require("time")
local uuid = require("uuid")
local model = require("model")
local decode = require("decode")
local layout = require("layout")
local render = require("render")
local bindings = require("bindings")
local menu = require("menu")
local appearance = require("appearance")
local delivery = require("delivery")
local selection = require("selection")
local connection = require("connection")
local names = require("names")
local display_transfer = require("display_transfer")

local function main(owner: string, initial_application: string?, secondary_application: string?)
    if ctx.get("bee.workspace_owner") ~= owner or owner == "" then error("Untrusted presenter bootstrap") end
    local workspace_id = contract.workspace_id(ctx.get("bee.workspace_id"))
    if not workspace_id then error("Invalid workspace identity bootstrap") end
    local input = assert(tty.events())
    local lifecycle = assert(process.events())
    local replies = assert(process.listen("bee.app.reply", {message = true}))
    local scenes = assert(process.listen("bee.desktop.scene", {message = true}))
    local acknowledgements = assert(process.listen("bee.desktop.ack", {message = true}))
    local dialog_states = assert(process.listen("bee.interaction.state", {message = true}))
    local dialog_results = assert(process.listen("bee.interaction.result", {message = true}))
    local dialogs: {[string]: dialog.State} = {}
    local answered: {[string]: boolean} = {}
    local retire = assert(process.listen("bee.workspace.retire", {message = true}))
    local clipboard_results = assert(process.listen("bee.clipboard.result", {message = true}))
    local transfer_updates = assert(process.listen("bee.display.transfers", {message = true}))
    local transfer_results = assert(process.listen("bee.display.transfer_result", {message = true}))
    local attachment_updates = assert(process.listen("bee.desktop.attachments", {message = true}))
    assert(tty.start())
    local output = assert(tty.surface({alternate_screen = true, hide_cursor = true, synchronized_output = true}))
    assert(tty.mouse(true))
    local width, height = tty.screen_size()
    local scene: model.Scene = model.new(width, height)
    local status_values: status_surface.Snapshot = {revision = 0, items = {}}
    local transfers: display_transfer.Snapshot = {version = 1, revision = 0, items = {}}
    local display_id = contract.workspace_id(ctx.get("bee.display_id")) or ""
    assert(process.monitor(owner))
    local tabs_order: {string} = {}
    local catalog: {menu.Descriptor} = {}
    local routing_scene: model.Scene = scene
    local routing_revision = scene.revision
    local pending_request: string? = nil
    local closing: {[string]: boolean} = {}
    local tab_hits: {render.TabHit} = {}
    local capture: layout.Capture? = nil
    local preview: model.Rect? = nil
    local awaiting_place = false
    local editor: title_editor.State? = nil
    local preferences = appearance.defaults()
    local start: menu.State? = nil
    local connection_open = false
    local connection_info: connection.Info = connection.new(owner, workspace_id, ctx.get("bee.display_id"), ctx.get("bee.hive_supervisor"))
    local captured_releases: {[string]: boolean} = {}
    local captured_mouse = false
    local active_selection: selection.State? = nil
    local pending_clipboard: string? = nil
    local remote_copy_reply: string? = nil
    local pending_clipboard_at: integer? = nil
    local pending_transfers: {[string]: {id: string, instance_id: string, target_display_id: string}} = {}
    local CLIPBOARD_TIMEOUT_NS: integer = 10 * 1000 * 1000 * 1000
    local status: string = "Starting workspace"
    local window_failure: {id: string, text: string}? = nil
    local function set_window_error(id: string, title: string, message: string)
        status = "[" .. title .. "] " .. message
        window_failure = {id = id, text = status}
    end
    local function retire_window(id: string)
        delivery.close(id)
        if window_failure and window_failure.id == id then
            if status == window_failure.text then status = "" end
            window_failure = nil
        end
    end
    local fatal: string? = nil
    local dirty = true
    local running = true
    local hydrated, rejoining = false, false
    local ticker = assert(time.ticker("33ms"))
    local ticks = ticker:channel()

    -- Predict only input ownership, never committed drawing or producer sizes.
    -- A correlated acknowledgement settles the latest intent, including no-ops.
    local function adopt_routing(value: model.Scene?)
        local committed = value or scene
        if committed.revision < routing_revision then return end
        routing_revision = committed.revision
        routing_scene = committed
        for id in pairs(closing) do
            local present = false
            for _, win in ipairs(committed.windows) do if win.id == id then present = true; break end end
            if present then routing_scene = model.remove(routing_scene, id) else closing[id] = nil end
        end
    end
    local function input_focus(): string return routing_scene.focus end
    local function dialog_target(): string
        if dialogs["bee.workspace:shutdown"] then return "bee.workspace:shutdown" end
        return input_focus()
    end
    local function request_quit()
        process.send(owner, "bee.workspace.control", {version = 1, op = "quit"})
    end
    local function command(op: string, id: string)
        local request_id = uuid.v7()
        if op == "focus" then
            routing_scene = model.focus(routing_scene, id); pending_request = request_id
        elseif op == "minimize" then
            routing_scene = model.minimize(routing_scene, id); pending_request = request_id
        end
        local sent, err = process.send(owner, "bee.desktop.command", {version = 1, op = op, id = id, request_id = request_id})
        if not sent then pending_request = nil; adopt_routing(); status = tostring(err) end
    end
    local function application(op: string, definition_id: string, id: string)
        if op == "close" and id == "" then return end
        if op == "close" then
            closing[id] = true
            routing_scene = model.remove(routing_scene, id)
        end
        local sent, err = process.send(owner, "bee.app.request", {version = 1, request_id = uuid.v7(), op = op, workspace_id = workspace_id, definition_id = definition_id, id = id})
        if not sent then closing[id] = nil; adopt_routing(); status = tostring(err) end
    end
    local function rectangle(win: model.Window): model.Rect
        return layout.rectangle(scene, win, capture, preview)
    end
    local function personalize(id: string, title: string, accent: string)
        local sent, err = process.send(owner, "bee.desktop.command", {version = 1, op = "personalize", id = id,
            user_title = title, accent = accent, request_id = uuid.v7()})
        if not sent then status = tostring(err) end
    end
    local function selection_body(state: selection.State): model.Rect?
        local binding = selection.binding(state)
        local attachment = delivery.attachment(binding.view_id)
        if not attachment then return nil end
        for _, win in ipairs(model.visible(scene)) do
            if win.id == binding.view_id and win.mode ~= "collapsed" then
                local body = layout.interior(win, rectangle(win))
                local current: selection.Binding = {view_id = win.id, attachment = attachment.mount,
                    mount_generation = attachment.generation, width = body.width, height = body.height}
                if selection.valid(state, current) then return body end
            end
        end
        return nil
    end
    local function cancel_selection()
        active_selection = selection.cancel(active_selection)
        remote_copy_reply = nil
        pending_clipboard = nil
        pending_clipboard_at = nil
    end
    local function toggle_connection()
        local selected = active_selection ~= nil
        cancel_selection()
        if selected then status = "" end
        connection_open = not connection_open
        start = nil
        capture, preview = nil, nil
        awaiting_place = false
    end
    local function begin_selection(target: string)
        local chosen: model.Window? = nil
        for _, win in ipairs(model.visible(scene)) do
            if win.id == target and win.mode ~= "collapsed" then chosen = win; break end
        end
        if not chosen then status = "Text selection unavailable: window is not visible"; return end
        local body = layout.interior(chosen, rectangle(chosen))
        local attachment = delivery.attachment(target)
        if not attachment then status = "Text selection unavailable: view is not attached"; return end
        local content, err = delivery.content(target, body.width, body.height)
        if not content then status = "Text selection unavailable: " .. tostring(err or "view has no content"); return end
        local rows: {string} = {}
        for y = 1, body.height do rows[y] = tty.text.cut(content.rows[y] or "", 0, body.width) end
        local captured, capture_error = selection.capture({view_id = target, attachment = attachment.mount,
            mount_generation = attachment.generation, width = body.width, height = body.height}, rows)
        if not captured then status = "Text selection unavailable: " .. tostring(capture_error); return end
        active_selection = captured
        pending_clipboard = nil
        pending_clipboard_at = nil
        status = "Select text: drag to select; Ctrl+C requests clipboard; Esc cancels"
    end
    local function request_clipboard()
        if pending_clipboard then
            status = "Clipboard request pending"
            return
        end
        local state = active_selection
        if not state or not selection_body(state) then
            cancel_selection()
            status = "Clipboard request unavailable: selection expired"
            return
        end
        local text, selection_error = selection.text(state)
        if not text then
            status = selection_error and "Clipboard request unavailable: " .. selection_error or "Clipboard request unavailable: select text first"
            return
        end
        if #text > 8192 then
            status = "Clipboard request unavailable: selected text exceeds 8192 bytes"
            return
        end
        local request_id = uuid.v7()
        local sent, send_error = process.send(owner, "bee.workspace.control", {version = 1, op = "clipboard",
            request_id = request_id, text = text})
        if not sent then
            status = "Clipboard request unavailable: " .. tostring(send_error or "delivery failed")
            return
        end
        pending_clipboard = request_id
        pending_clipboard_at = time.now():unix_nano()
        status = "Clipboard requested"
    end
    local function clipboard_result(value: unknown): {request_id: string, status: string, error: string}?
        if type(value) ~= "table" then return nil end
        local raw_id: unknown = value.request_id
        local raw_status: unknown = value.status
        if value.version ~= 1 then return nil end
        if type(raw_id) ~= "string" or raw_id == "" or #raw_id > 80 then return nil end
        if type(raw_status) ~= "string" then return nil end
        local request_id: string = raw_id
        local result_status: string = raw_status
        for key in pairs(value) do
            if key ~= "version" and key ~= "request_id" and key ~= "status" and key ~= "error" then return nil end
        end
        if result_status ~= "submitted" and result_status ~= "unavailable" and result_status ~= "rejected" then return nil end
        local error_text = ""
        if value.error ~= nil then
            if type(value.error) ~= "string" or #value.error > 4096 then return nil end
            error_text = value.error
        end
        return {request_id = request_id, status = result_status, error = error_text}
    end
    local function transfer_item(id: string, instance_id: string): display_transfer.Item?
        for _, item in ipairs(transfers.items) do
            if item.tab_id == id and item.instance_id == instance_id then return item end
        end
        return nil
    end
    local function send_transfer(id: string, target_display_id: string)
        local instance_id: string? = nil
        for _, win in ipairs(scene.windows) do
            if win.id == id then instance_id = win.instance_id; break end
        end
        if not instance_id then status = "Transfer unavailable: window is no longer open"; return end
        local item = transfer_item(id, instance_id)
        if not item then status = "Transfer unavailable: assignment changed"; return end
        local pending_count = 0
        for _, pending in pairs(pending_transfers) do
            pending_count = pending_count + 1
            if pending.id == id and pending.instance_id == instance_id then
                status = "Transfer pending for this window"
                return
            end
        end
        if pending_count >= 16 then
            status = "Transfer unavailable: too many requests pending"
            return
        end
        local available = false
        for _, target in ipairs(item.targets) do
            if target == target_display_id and target ~= display_id then available = true; break end
        end
        if not available then status = "Transfer unavailable: destination changed"; return end
        local request_id = uuid.v7()
        local action = {version = 1, op = "transfer", request_id = request_id, id = id,
            instance_id = instance_id, target_display_id = target_display_id,
            expected_revision = item.assignment_revision}
        if not display_transfer.action(action) then
            status = "Transfer unavailable: invalid request"
            return
        end
        local sent, err = process.send(owner, "bee.workspace.control", action)
        if not sent then
            status = "Transfer unavailable: " .. tostring(err or "delivery failed")
            return
        end
        pending_transfers[request_id] = {id = id, instance_id = instance_id, target_display_id = target_display_id}
        status = "Sending to display " .. names.label(target_display_id)
    end
    local function invoke(action: string, selected_target: string?)
        local target = selected_target or (start and start.target) or input_focus()
        start = nil
        if action == "select_text" then begin_selection(target)
        elseif action == "rename" then
            for _, win in ipairs(scene.windows) do
                if win.id == target then editor = title_editor.open(win.id, model.display_title(win), win.accent or ""); break end
            end
        elseif action:sub(1, 7) == "accent:" then
            for _, win in ipairs(scene.windows) do
                if win.id == target then personalize(win.id, win.user_title or "", action:sub(8)); break end
            end
        elseif action == "quit" then request_quit()
        elseif action:sub(1, 5) == "open:" then application("open", action:sub(6), "")
        elseif action == "initial" and initial_application then application("open", initial_application, "")
        elseif action == "close" then application("close", "", target)
        elseif action == "restore" then
            for _, win in ipairs(scene.windows) do
                if win.id == target then command(win.mode == "fullscreen" and "fullscreen" or "restore", target); break end
            end
            command("focus", target)
        elseif action == "fullscreen" or action == "minimize" then command(action, target)
        elseif action == "collapse" or action == "snap_left" or action == "snap_right" then
            for _, win in ipairs(scene.windows) do
                if win.id == target then
                    if win.mode == "fullscreen" then command("fullscreen", win.id) end
                    if win.mode == "collapsed" then command("restore", win.id) end
                    if action == "collapse" then command("collapse", win.id)
                    else process.send(owner, "bee.desktop.command", {version = 1, op = "snap", id = win.id, side = action == "snap_left" and "left" or "right"}) end
                end
            end
        elseif action == "restore_all" then
            for _, win in ipairs(scene.windows) do
                command("restore", win.id)
                if win.mode == "minimized" and win.restore_mode == "collapsed" then command("restore", win.id) end
            end
            if #tabs_order > 0 then command("focus", tabs_order[#tabs_order]) end
        elseif action == "rejoin" then
            cancel_selection()
            rejoining = true
            process.send(owner, "bee.workspace.control", {version = 1, op = "rejoin"})
        elseif action:sub(1, 9) == "transfer:" then
            send_transfer(target, action:sub(10))
        end
    end
    local function paint()
        if editor then
            local present = false
            for _, win in ipairs(scene.windows) do if win.id == editor.id then present = true; break end end
            if not present then editor = nil end
        end
        local contents: {[string]: render.Content} = {}
        for _, win in ipairs(model.visible(scene)) do
            if delivery.has(win.id) and win.mode ~= "collapsed" then
                local body = layout.interior(win, rectangle(win))
                -- Drag previews do not resize producers. Only committed bounds do.
                if not capture and not delivery.observing(win.id) and (delivery.requested_width(win.id) ~= body.width or delivery.requested_height(win.id) ~= body.height) then
                    local resized, resize_error = delivery.resize(win.id, body.width, body.height)
                    if not resized and resize_error then
                        local title = model.display_title(win)
                        set_window_error(win.id, title, tostring(resize_error))
                    end
                end
                local content, err = delivery.content(win.id, body.width, body.height)
                if content then
                    local cur: render.Cursor? = nil
                    if content.cursor and not delivery.is_failed(win.id) and not delivery.observing(win.id) then
                        cur = {
                            x = content.cursor.x,
                            y = content.cursor.y,
                            visible = content.cursor.visible == true,
                        }
                    end
                    contents[win.id] = {rows = content.rows, cursor = cur}
                elseif err and not delivery.is_failed(win.id) and err ~= "Attaching" and err ~= "Resizing" then
                    local title = model.display_title(win)
                    set_window_error(win.id, title, tostring(err))
                end
            end
        end
        local badges: {[string]: status_surface.Badge} = {}
        for _, item in ipairs(status_values.items) do
            for _, win in ipairs(scene.windows) do
                if win.id == item.tab_id and win.instance_id == item.instance_id then badges[win.id] = item.badge; break end
            end
        end
        if active_selection and not selection_body(active_selection) then cancel_selection(); status = "Text selection unavailable: view changed" end
        local frame = render.draw(scene, tabs_order, contents, capture, preview, status, "Workspace " .. names.label(workspace_id),
            preferences, start, initial_application ~= nil, catalog, editor, dialogs["bee.workspace:shutdown"] or dialogs[scene.focus], badges, active_selection, connection_info, connection_open, hydrated,
            transfers, display_id)
        tab_hits = frame.tabs
        output:present(frame.rows, {cursor = frame.cursor})
        dirty = false
    end
    assert(process.send(owner, "bee.workspace.control", {version = 1, op = "ready"}))
    while running do
        local selected = channel.select({input:case_receive(), lifecycle:case_receive(),
            replies:case_receive(), scenes:case_receive(), acknowledgements:case_receive(), retire:case_receive(), clipboard_results:case_receive(),
            transfer_updates:case_receive(), transfer_results:case_receive(), attachment_updates:case_receive(),
            dialog_states:case_receive(), dialog_results:case_receive(), ticks:case_receive()})
        if not selected.ok then break end
        if selected.channel == lifecycle then
            local event = selected.value
            if event.kind == process.event.CANCEL then break end
            if event.kind == process.event.EXIT and tostring(event.from) == owner then
                status = "Desktop service exited"; fatal = status; running = false
            end
        elseif selected.channel == dialog_states and selected.value:from() == owner then
            local payload: unknown = selected.value:payload():data()
            local specs = interaction.snapshot(payload)
            local global = interaction.shutdown(payload)
            if specs and type(payload) == "table" and (payload.shutdown == nil or global) then
                if global then specs[#specs + 1] = global end
                local next_dialogs: {[string]: dialog.State} = {}
                local next_answered: {[string]: boolean} = {}
                for _, spec in ipairs(specs) do
                    -- Question and lifecycle messages use separate channels.
                    -- A visible question must own input even if "closing" is late.
                    closing[spec.id] = nil
                    local previous = dialogs[spec.id]
                    if previous and previous.spec.request_id == spec.request_id then next_dialogs[spec.id] = previous
                    else next_dialogs[spec.id] = dialog.open(spec) end
                    if answered[spec.request_id] then next_answered[spec.request_id] = true end
                end
                dialogs, answered = next_dialogs, next_answered
                if not pending_request then adopt_routing() end
                dirty = true
            end
        elseif selected.channel == dialog_results and selected.value:from() == owner then
            local result = interaction.result(selected.value:payload():data())
            if result then
                local current = dialogs[result.id]
                if current and current.spec.request_id == result.request_id and current.spec.instance_id == result.instance_id
                    and result.error_code ~= "" then
                    if result.error_code ~= "already_dispatched" then answered[result.request_id] = nil end
                    status, dirty = result.error, true
                end
            end
        elseif selected.channel == retire then
            if selected.value:from() == owner then cancel_selection(); rejoining = true; running = false end
        elseif selected.channel == clipboard_results then
            local message = selected.value
            if message:from() == owner then
                local reply = clipboard_result(message:payload():data())
                if reply and reply.request_id == remote_copy_reply and reply.status == "rejected" then
                    remote_copy_reply = nil
                    status = "Clipboard request rejected: " .. reply.error
                    dirty = true
                elseif reply and active_selection and selection_body(active_selection) and reply.request_id == pending_clipboard then
                    pending_clipboard = nil
                    pending_clipboard_at = nil
                    if reply.status == "submitted" then
                        cancel_selection()
                        status = "Clipboard request submitted"
                    elseif reply.status == "unavailable" then status = "Clipboard request unavailable" .. (reply.error ~= "" and ": " .. reply.error or "")
                    else status = "Clipboard request rejected" .. (reply.error ~= "" and ": " .. reply.error or "") end
                    dirty = true
                end
            end
        elseif selected.channel == attachment_updates then
            local message = selected.value
            if tostring(message:from()) == owner and connection.observe(connection_info, message:payload():data()) then dirty = true end
        elseif selected.channel == transfer_updates then
            local message = selected.value
            if message:from() == owner then
                local incoming = display_transfer.snapshot(message:payload():data())
                if incoming and incoming.revision > transfers.revision then
                    transfers = incoming
                    -- A contextual menu may have been built from the previous
                    -- assignment revision. Reopen it against the new snapshot.
                    if start and start.kind == "window" then start = nil end
                    dirty = true
                end
            end
        elseif selected.channel == transfer_results then
            local message = selected.value
            if message:from() == owner then
                local result = display_transfer.result(message:payload():data())
                local pending: {id: string, instance_id: string, target_display_id: string}? = nil
                if result then pending = pending_transfers[result.request_id] end
                if result and pending and pending.id == result.id and pending.instance_id == result.instance_id
                    and pending.target_display_id == result.target_display_id then
                    pending_transfers[result.request_id] = nil
                    if result.error_code == "" then
                        status = "Sent to display " .. names.label(result.target_display_id)
                    else
                        local message_text = result.error ~= "" and result.error or result.error_code
                        status = "Transfer failed: " .. message_text
                    end
                    dirty = true
                end
            end
        elseif selected.channel == replies then
            local msg = selected.value
            if msg:from() == owner then
                local reply = decode.reply(msg:payload():data())
                if reply and decode.belongs(reply, workspace_id) then
                    if reply.error == "" and (reply.op == "open" or reply.op == "attached" or reply.op == "focus" or reply.op == "close" or reply.op == "closed") then status = "" end
                    if reply.op == "closing" then closing[reply.id] = nil; if not pending_request then adopt_routing() end end
                    if reply.error ~= "" then
                        status = reply.error
                        if reply.op == "close" then closing[reply.id] = nil; if not pending_request then adopt_routing() end end
                    end
                    if (reply.op == "open" or reply.op == "attached") and reply.error == "" and reply.mount ~= "" then
                        local attached, err = delivery.attach(reply.id, reply.mount, reply.observer)
                        if not attached and err then
                            local title = "Window"
                            for _, win in ipairs(scene.windows) do if win.id == reply.id then title = model.display_title(win); break end end
                            set_window_error(reply.id, title, tostring(err))
                        end
                        if active_selection and not selection_body(active_selection) then cancel_selection() end
                    elseif (reply.op == "close" and reply.error == "") or reply.op == "closed" then
                        retire_window(reply.id)
                        if active_selection and selection.binding(active_selection).view_id == reply.id then cancel_selection() end
                        for i = #tabs_order, 1, -1 do if tabs_order[i] == reply.id then table.remove(tabs_order, i) end end
                        routing_scene = model.remove(routing_scene, reply.id)
                        if capture and capture.id == reply.id then capture, preview = nil, nil; awaiting_place = false; captured_mouse = true end
                    end
                    dirty = true
                end
            end
        elseif selected.channel == acknowledgements then
            local message = selected.value
            if message:from() == owner then
                local ack = decode.ack(message:payload():data())
                if ack then
                    if ack.request_id == pending_request then pending_request = nil end
                    if not pending_request then adopt_routing(ack.scene) end
                end
            end
        elseif selected.channel == scenes then
            local msg = selected.value
            if msg:from() == owner then
                local raw: unknown = msg:payload():data()
                if type(raw) == "table" then
                    local incoming = status_surface.presentation(raw.status_surface)
                    if incoming and incoming.revision > status_values.revision then status_values = incoming end
                end
                local state = decode.desktop(raw)
                local next_scene = state and state.scene
                if next_scene and next_scene.revision >= scene.revision then
                    -- Inventory-driven removal need not carry a close reply.
                    -- Retire only previously committed windows; an attachment
                    -- may arrive before the scene that first introduces it.
                    local present: {[string]: boolean} = {}
                    for _, win in ipairs(next_scene.windows) do present[win.id] = true end
                    for _, win in ipairs(scene.windows) do
                        if not present[win.id] then retire_window(win.id) end
                    end
                    scene = next_scene
                    if awaiting_place and capture and preview then
                        local settled = true
                        for _, win in ipairs(scene.windows) do
                            if win.id == capture.id and (win.mode == "floating" or win.mode == "collapsed") then
                                local bounds = model.bounds(scene, win)
                                settled = bounds.x == preview.x and bounds.y == preview.y
                                    and bounds.width == preview.width and bounds.height == preview.height
                                break
                            end
                        end
                        if settled then capture, preview = nil, nil; awaiting_place = false end
                    end
                    if start and start.kind == "window" then
                        local found = false
                        for _, win in ipairs(scene.windows) do if win.id == start.target then found = true end end
                        if not found then start = nil end
                    end
                    if state then tabs_order = state.tabs; preferences = state.preferences; catalog = state.catalog end
                    if not hydrated and status == "Starting workspace" then status = "" end
                    hydrated = true
                    if not pending_request then adopt_routing() end
                end
                dirty = true
            end
        elseif selected.channel == ticks then
            if pending_clipboard and pending_clipboard_at and time.now():unix_nano() - pending_clipboard_at >= CLIPBOARD_TIMEOUT_NS then
                pending_clipboard, pending_clipboard_at = nil, nil
                status = "Clipboard request unavailable: timed out"
                dirty = true
            end
            local visible_ids: {string} = {}
            for _, win in ipairs(model.visible(scene)) do
                if win.mode ~= "collapsed" then table.insert(visible_ids, win.id) end
            end
            if delivery.poll(visible_ids) then dirty = true end
            while true do
                local f = delivery.poll_failure()
                if not f then break end
                local title = "Window"
                for _, win in ipairs(scene.windows) do
                    if win.id == f.id then
                        title = model.display_title(win)
                        break
                    end
                end
                set_window_error(f.id, title, f.error)
                dirty = true
            end
        elseif selected.channel == input and not rejoining then
            local event = selected.value
            local handled = false
            local kind = tostring(event.key_type or "")
            -- Reserved compositor key: queued by the owning supervisor after
            -- prior input admission. Only its pending request can accept a reply.
            if event.type == "key" and kind == "bee.copy" then
                local id = contract.text(event.key, 80)
                if id and id ~= "" and event.action == "press" then
                    local state = active_selection
                    local chosen = state ~= nil
                    local text, failure = "", ""
                    if state and chosen then
                        local extracted, err = selection.text(state)
                        if not selection_body(state) then failure = "Selection expired"
                        elseif not extracted then failure = tostring(err or "Select text first")
                        elseif #extracted > 8192 then failure = "Selected text exceeds 8192 bytes"
                        else text = extracted end
                        cancel_selection()
                        remote_copy_reply = id
                        status = failure ~= "" and failure or "Clipboard requested"
                    end
                    local sent = process.send(owner, "bee.selection.copied", {version = 1, request_id = id, selected = chosen, text = text, error = failure})
                    if not sent then status = "Clipboard response delivery failed" end
                    dirty = true
                end
                handled = true
            elseif event.type == "key" and event.action == "release" and captured_releases[kind] then
                captured_releases[kind] = nil; handled = true
            elseif event.type == "mouse" and event.action == "release" and captured_mouse then
                captured_mouse = false; handled = true
            elseif dialogs[dialog_target()] and event.type ~= "resize" and event.type ~= "close"
                and not (not dialogs["bee.workspace:shutdown"] and event.type == "mouse" and event.y == 1 and type(event.x) == "number" and event.x > 7 and event.button == "left")
                and not (event.type == "key" and (kind == "f12" or (event.ctrl == true and event.key == "q") or (not dialogs["bee.workspace:shutdown"] and event.alt == true and kind == "tab"))) then
                local current = dialogs[dialog_target()]
                if current and not answered[current.spec.request_id] then
                    local response = dialog.respond(current, event, width, height)
                    dialogs[dialog_target()] = response.state
                    if response.action == "accept" or response.action == "cancel" then
                        local sent, err = process.send(owner, "bee.interaction.response", {version = 1,
                            request_id = current.spec.request_id, id = current.spec.id, instance_id = current.spec.instance_id,
                            action = response.action, value = response.value})
                        if sent then answered[current.spec.request_id] = true else status = tostring(err) end
                    end
                end
                if event.type == "key" and event.action ~= "release" then captured_releases[kind] = true end
                if event.type == "mouse" and event.action == "press" then captured_mouse = true end
                handled = true; dirty = true
            elseif editor and event.type ~= "resize" and event.type ~= "close" then
                if event.type == "key" and event.ctrl == true and event.key == "q" then request_quit()
                elseif event.type == "key" and kind == "f12" and event.action ~= "release" then
                    editor = nil; rejoining = true
                    process.send(owner, "bee.workspace.control", {version = 1, op = "rejoin"})
                else
                    local response = title_editor.respond(editor, event, title_editor.panel(width, height))
                    editor = response.state
                    if response.action == "save" then
                        personalize(editor.id, editor.left .. editor.right, editor.accent); editor = nil
                    elseif response.action == "cancel" then editor = nil end
                end
                if event.type == "key" and event.action ~= "release" then captured_releases[kind] = true end
                if event.type == "mouse" and event.action == "press" then captured_mouse = true end
                handled = true; dirty = true
            elseif active_selection and event.type ~= "resize" and event.type ~= "close" then
                local body = selection_body(active_selection)
                if event.type == "key" and kind == "f9" and event.action ~= "release"
                    and event.alt ~= true and event.ctrl ~= true and event.shift ~= true
                    and connection.available(width, height) then
                    toggle_connection()
                    captured_releases[kind] = true
                elseif not body then
                    cancel_selection()
                    status = "Text selection unavailable: view changed"
                elseif event.type == "key" and event.action ~= "release" and (kind == "esc" or kind == "escape") then
                    cancel_selection()
                    status = ""
                    captured_releases[kind] = true
                elseif event.type == "key" and event.action ~= "release" and event.ctrl == true
                    and tostring(event.key or ""):lower() == "c" then
                    request_clipboard()
                    captured_releases[kind] = true
                elseif event.type == "key" and event.action ~= "release" and event.ctrl == true
                    and tostring(event.key or ""):lower() == "q" then
                    cancel_selection()
                    request_quit()
                    captured_releases[kind] = true
                elseif event.type == "key" and event.action ~= "release" and kind == "f12" then
                    cancel_selection()
                    rejoining = true
                    process.send(owner, "bee.workspace.control", {version = 1, op = "rejoin"})
                    captured_releases[kind] = true
                elseif event.type == "mouse" then
                    local x, y = math.floor(tonumber(event.x) or 1), math.floor(tonumber(event.y) or 1)
                    if event.action == "press" and event.button == "left" then
                        active_selection = selection.press(active_selection, x - body.x + 1, y - body.y + 1)
                        pending_clipboard, pending_clipboard_at = nil, nil
                    elseif event.action == "motion" then
                        active_selection = selection.motion(active_selection, x - body.x + 1, y - body.y + 1)
                    elseif event.action == "release" and event.button == "left" then
                        active_selection = selection.release(active_selection, x - body.x + 1, y - body.y + 1)
                    end
                end
                -- Selection owns all app-directed input, including paste, wheel
                -- and clicks outside its body; the model clamps drag endpoints.
                handled = true
                dirty = true
            elseif event.type == "key" and kind == "f9" and event.action ~= "release"
                and event.alt ~= true and event.ctrl ~= true and event.shift ~= true
                and connection.available(width, height) then
                toggle_connection()
                captured_releases[kind] = true
                handled = true; dirty = true
            elseif connection_open and event.type ~= "resize" and event.type ~= "close"
                and not (event.type == "key" and (kind == "f12" or (event.ctrl == true and event.key == "q"))) then
                if event.type == "key" and event.action ~= "release" and event.key == "d"
                    and event.alt ~= true and event.ctrl ~= true then
                    connection.toggle_details(connection_info)
                elseif event.type == "key" and (kind == "esc" or kind == "escape") and event.action ~= "release" then
                    connection_open = false
                elseif event.type == "mouse" and event.action == "press" then
                    if event.button == "left" and connection.details_hit(width, height, connection_info, event.x, event.y) then
                        connection.toggle_details(connection_info)
                    elseif not connection.contains(width, height, connection_info, event.x, event.y) then
                        connection_open = false
                    end
                end
                if event.type == "key" and event.action ~= "release" then captured_releases[kind] = true end
                if event.type == "mouse" and event.action == "press" then captured_mouse = true end
                handled = true; dirty = true
            elseif capture and not awaiting_place and event.type == "key" and (kind == "esc" or kind == "escape") and event.action ~= "release" then
                capture, preview = nil, nil; awaiting_place = false
                captured_releases[kind] = true; captured_mouse = true
                handled = true; dirty = true
            elseif (event.type == "key" and kind == "f1" and event.action ~= "release")
                or (event.type == "mouse" and event.action == "press" and event.button == "left"
                    and event.y == 1 and event.x <= 7 and height >= 3) then
                if start then start = nil else start = {selected = 1, offset = 0} end
                if capture then captured_mouse = true end
                capture, preview = nil, nil; awaiting_place = false
                if event.type == "key" then captured_releases[kind] = true else captured_mouse = true end
                handled = true; dirty = true
            elseif start and event.type ~= "resize" and event.type ~= "close" then
                local items = menu.entries(start, scene, initial_application ~= nil, catalog, transfers, display_id)
                local panel = menu.panel(width, height, #items, start)
                local response = menu.respond(start, panel, items, event)
                local menu_target = start and start.target
                local changed = response.state.selected ~= start.selected or response.state.offset ~= start.offset
                    or response.state.path ~= start.path
                start = response.state
                if response.close then start = nil end
                if event.type == "key" and event.action ~= "release" then captured_releases[kind] = true end
                if event.type == "mouse" and event.action == "press" then captured_mouse = true end
                if response.action ~= "" then invoke(response.action, menu_target) end
                handled = true
                if changed or response.close or response.action ~= "" then dirty = true end
            end
            if not handled then
                if event.type == "close" then cancel_selection(); break
                elseif event.type == "resize" then
                    width, height = event.width, event.height
                    cancel_selection()
                    if connection_open and not connection.available(width, height) then connection_open = false end
                    if capture then captured_mouse = true end
                    capture, preview = nil, nil; awaiting_place = false
                    dirty = true
                elseif event.type == "key" then
                    if event.action ~= "release" then captured_releases[kind] = nil end
                    local action = bindings.action(tostring(event.key or ""), tostring(event.key_type or ""),
                        event.ctrl == true, event.alt == true, initial_application ~= nil, secondary_application ~= nil, event.shift == true)
                    if event.action ~= "release" then
                        if action == "quit" then request_quit()
                        elseif action == "initial" and initial_application then application("open", initial_application, "")
                        elseif action == "secondary" and secondary_application then application("open", secondary_application, "")
                        elseif action == "close" then application("close", "", input_focus())
                        elseif action == "fullscreen" or action == "minimize" then command(action, input_focus())
                        elseif action == "rejoin" then
                            cancel_selection()
                            rejoining = true
                            process.send(owner, "bee.workspace.control", {version = 1, op = "rejoin"})
                        elseif action == "next" or action == "previous" then
                            local next_id = action == "previous" and tabs_order[#tabs_order] or tabs_order[1]
                            for index, id in ipairs(tabs_order) do
                                if id == input_focus() then
                                    local step = action == "previous" and -1 or 1
                                    next_id = tabs_order[(index - 1 + step + #tabs_order) % #tabs_order + 1]
                                    break
                                end
                            end
                            if next_id then command("focus", next_id) end
                        end
                    end
                    if action == "" then
                        local target = input_focus()
                        if target ~= "" and delivery.has(target) then
                            local sent, err = delivery.send(target, {type = "key", key = tostring(event.key or ""),
                                key_type = tostring(event.key_type or ""), action = event.action == "release" and "release" or "press",
                                ctrl = event.ctrl == true, alt = event.alt == true, shift = event.shift == true})
                            if not sent and err then
                                local title = "Window"
                                for _, win in ipairs(scene.windows) do if win.id == target then title = model.display_title(win); break end end
                                set_window_error(target, title, tostring(err))
                                dirty = true
                            end
                        end
                    end
                elseif event.type == "mouse" then
                    local x, y = math.floor(tonumber(event.x) or 1), math.floor(tonumber(event.y) or 1)
                    if capture and not awaiting_place then
                        if event.action == "release" then
                            preview = layout.drag(scene, capture, x, y) or preview
                            if preview then
                                local sent, send_error = process.send(owner, "bee.desktop.command", {version = 1, op = "place", id = capture.id,
                                    x = preview.x, y = preview.y, width = preview.width, height = preview.height})
                                -- Keep the last preview until the committed scene
                                -- reaches it; clearing here flashes the old bounds.
                                if sent then awaiting_place = true
                                else
                                    capture, preview, awaiting_place = nil, nil, false
                                    status = tostring(send_error or "Could not place window")
                                end
                            else capture, preview = nil, nil end
                        else
                            preview = layout.drag(scene, capture, x, y)
                        end
                        dirty = true
                    elseif height >= 3 and y == 1 then
                        if event.action == "press" and (event.button == "left" or event.button == "right") then
                            local hit_tab = false
                            for _, hit in ipairs(tab_hits) do
                                if x >= hit.x and x < hit.x + hit.width then
                                    hit_tab = true
                                    if hit.action == "connection" then
                                        connection_open = true; start = nil; dirty = true
                                    elseif event.button == "right" then
                                        start = {selected = 1, offset = 0, kind = "window", target = hit.id, x = x, y = y + 1}
                                        dirty = true
                                    elseif hit.action == "close" then application("close", "", hit.id)
                                    else command(hit.action or "focus", hit.id) end
                                    captured_mouse = true
                                    break
                                end
                            end
                            if not hit_tab and event.button == "right" then
                                start = {selected = 1, offset = 0, kind = "desktop", x = x, y = y + 1}
                                captured_mouse = true; dirty = true
                            end
                        end
                    else
                        local visible = model.visible(scene)
                        local pointed = false
                        for index = #visible, 1, -1 do
                            local win = visible[index]
                            local rect = rectangle(win)
                            if layout.contains(rect, x, y) then
                                pointed = true
                                local body = layout.interior(win, rect)
                                if event.action == "press" then command("focus", win.id) end
                                if event.action == "press" and event.button == "right"
                                    and (event.shift ~= true or win.mode == "collapsed" or not layout.contains(body, x, y)) then
                                    start = {selected = 1, offset = 0, kind = "window", target = win.id, x = x, y = y}
                                    captured_mouse = true; dirty = true
                                    break
                                end
                                local control = layout.control_at(win, rect, x, y)
                                if control and event.action == "press" and event.button == "left" then
                                    captured_mouse = true
                                    invoke(control)
                                    dirty = true
                                    break
                                end
                                if event.action == "press" and event.button == "left" and (body.x ~= rect.x or win.mode == "collapsed") then
                                    local edge = win.mode == "collapsed" and "move" or layout.edge(rect, x, y)
                                    if edge ~= "" then awaiting_place = false; capture = {id = win.id, x = x, y = y, bounds = rect, edge = edge} end
                                end
                                if not capture and win.mode ~= "collapsed" and layout.contains(body, x, y) then
                                    if delivery.has(win.id) then
                                        local sent, err = delivery.send(win.id, {type = "mouse", x = x - body.x + 1, y = y - body.y + 1,
                                            action = event.action == "release" and "release" or (event.action == "wheel" and "wheel" or (event.action == "motion" and "motion" or "press")), button = tostring(event.button or ""), ctrl = event.ctrl == true, alt = event.alt == true, shift = event.shift == true})
                                        if not sent and err then
                                            set_window_error(win.id, model.display_title(win), tostring(err))
                                            dirty = true
                                        end
                                    end
                                end
                                break
                            end
                        end
                        if not pointed and event.action == "press" then
                            if event.button == "left" then command("focus", "")
                            elseif event.button == "right" then
                                start = {selected = 1, offset = 0, kind = "desktop", x = x, y = y}
                                captured_mouse = true; dirty = true
                            end
                        end
                    end
                elseif event.type == "paste" then
                    local target = input_focus()
                    if target ~= "" and delivery.has(target) then
                        local sent, err = delivery.send(target, {type = "paste", text = tostring(event.text or "")})
                        if not sent and err then
                            local title = "Window"
                            for _, win in ipairs(scene.windows) do if win.id == target then title = model.display_title(win); break end end
                            set_window_error(target, title, tostring(err))
                            dirty = true
                        end
                    end
                end
            end
        end
        if dirty and hydrated then paint() end
    end
    ticker:stop()
    process.unlisten(dialog_states)
    process.unlisten(dialog_results)
    process.unlisten(clipboard_results)
    process.unlisten(transfer_updates)
    process.unlisten(transfer_results)
    process.unlisten(attachment_updates)
    if not rejoining then process.send(owner, "bee.workspace.control", {version = 1, op = "quit"}) end
    delivery.shutdown()
    output:close()
    tty.stop()
    if fatal then error(fatal) end
end
local function supervised_main(owner: string, initial_application: string?, secondary_application: string?)
    local ok, failure = pcall(main, owner, initial_application, secondary_application)
    if not ok then
        log:error("Presenter failed", {owner = owner, error = tostring(failure)})
        error(failure)
    end
end
return {main = supervised_main}
