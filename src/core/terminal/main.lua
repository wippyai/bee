local tty = require("tty")
local title_editor = require("title_editor")
local dialog = require("dialog")
local interaction = require("interaction")
local ctx = require("ctx")
local process = require("process")
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

type Attachment = {view: tty.Viewport, width: integer, height: integer, revision: integer}
local function main(owner: string, initial_application: string?, secondary_application: string?)
    if ctx.get("bee.workspace_owner") ~= owner or owner == "" then error("Untrusted presenter bootstrap") end
    local input = assert(tty.events())
    local lifecycle = assert(process.events())
    local replies = assert(process.listen("bee.app.reply", {message = true}))
    local scenes = assert(process.listen("bee.desktop.scene", {message = true}))
    local acknowledgements = assert(process.listen("bee.desktop.ack", {message = true}))
    local dialog_states = assert(process.listen("bee.interaction.state", {message = true}))
    local dialogs: {[string]: dialog.State} = {}
    local answered: {[string]: boolean} = {}
    local retire = assert(process.listen("bee.workspace.retire", {message = true}))
    assert(tty.start())
    local output = assert(tty.surface({alternate_screen = true, hide_cursor = true, synchronized_output = true}))
    assert(tty.mouse(true))
    local width, height = tty.screen_size()
    local scene: model.Scene = model.new(width, height)
    assert(process.monitor(owner))
    local attachments: {[string]: Attachment} = {}
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
    local captured_releases: {[string]: boolean} = {}
    local captured_mouse = false
    local status = "Starting workspace"
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
        local sent, err = process.send(owner, "bee.app.request", {version = 1, request_id = uuid.v7(), op = op, definition_id = definition_id, id = id})
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
    local function invoke(action: string)
        local target = start and start.target or input_focus()
        start = nil
        if action == "rename" then
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
            rejoining = true
            process.send(owner, "bee.workspace.control", {version = 1, op = "rejoin"})
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
            local attached = attachments[win.id]
            if attached and win.mode ~= "collapsed" then
                local body = layout.interior(win, rectangle(win))
                -- Drag previews do not resize producers. Only committed bounds do.
                if not capture and (attached.width ~= body.width or attached.height ~= body.height) then
                    local resized, resize_error = attached.view:resize(body.width, body.height)
                    if resized then attached.width, attached.height = body.width, body.height
                    else status = tostring(resize_error or "Resize failed") end
                end
                local snapshot, err = attached.view:snapshot()
                if snapshot then
                    attached.revision = snapshot.revision
                    contents[win.id] = {rows = snapshot.rows, cursor = snapshot.cursor}
                else status = tostring(err or "View unavailable") end
            end
        end
        local frame = render.draw(scene, tabs_order, contents, capture, preview, status, "workspace / local",
            preferences, start, initial_application ~= nil, catalog, editor, dialogs["bee.workspace:shutdown"] or dialogs[scene.focus])
        tab_hits = frame.tabs
        output:present(frame.rows, {cursor = frame.cursor})
        dirty = false
    end
    assert(process.send(owner, "bee.workspace.control", {version = 1, op = "ready"}))
    while running do
        local selected = channel.select({input:case_receive(), lifecycle:case_receive(),
            replies:case_receive(), scenes:case_receive(), acknowledgements:case_receive(), retire:case_receive(), dialog_states:case_receive(), ticks:case_receive()})
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
                    local previous = dialogs[spec.id]
                    if previous and previous.spec.request_id == spec.request_id then next_dialogs[spec.id] = previous
                    else next_dialogs[spec.id] = dialog.open(spec) end
                    if answered[spec.request_id] then next_answered[spec.request_id] = true end
                end
                dialogs, answered = next_dialogs, next_answered
                dirty = true
            end
        elseif selected.channel == retire then
            if selected.value:from() == owner then rejoining = true; running = false end
        elseif selected.channel == replies then
            local msg = selected.value
            if msg:from() == owner then
                local reply = decode.reply(msg:payload():data())
                if reply then
                    if reply.error == "" and (reply.op == "open" or reply.op == "attached" or reply.op == "focus" or reply.op == "close") then status = "" end
                    if reply.op == "closing" then closing[reply.id] = nil; if not pending_request then adopt_routing() end end
                    if reply.error ~= "" then
                        status = reply.error
                        if reply.op == "close" then closing[reply.id] = nil; if not pending_request then adopt_routing() end end
                    end
                    if (reply.op == "open" or reply.op == "attached") and reply.error == "" then
                        local view, err = tty.attach(reply.mount)
                        if view then
                            attachments[reply.id] = {view = view, width = 0, height = 0, revision = -1}
                        else
                            status = tostring(err)
                        end
                    elseif (reply.op == "close" and reply.error == "") or reply.op == "closed" then
                        local attached = attachments[reply.id]
                        if attached then attached.view:close(); attachments[reply.id] = nil end
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
                local state = decode.desktop(msg:payload():data())
                local next_scene = state and state.scene
                if next_scene and next_scene.revision >= scene.revision then
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
            for _, win in ipairs(model.visible(scene)) do
                local attached = attachments[win.id]
                if attached and win.mode ~= "collapsed" then
                    local snapshot = attached.view:snapshot()
                    if snapshot and snapshot.revision ~= attached.revision then dirty = true end
                end
            end
        elseif selected.channel == input and not rejoining then
            local event = selected.value
            local handled = false
            local kind = tostring(event.key_type or "")
            if event.type == "key" and event.action == "release" and captured_releases[kind] then
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
                local items = menu.entries(start, scene, initial_application ~= nil, catalog)
                local panel = menu.panel(width, height, #items, start)
                local response = menu.respond(start, panel, items, event)
                local changed = response.state.selected ~= start.selected or response.state.offset ~= start.offset
                    or response.state.path ~= start.path
                start = response.state
                if response.close then start = nil end
                if event.type == "key" and event.action ~= "release" then captured_releases[kind] = true end
                if event.type == "mouse" and event.action == "press" then captured_mouse = true end
                if response.action ~= "" then invoke(response.action) end
                handled = true
                if changed or response.close or response.action ~= "" then dirty = true end
            end
            if not handled then
                if event.type == "close" then break
                elseif event.type == "resize" then
                    width, height = event.width, event.height
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
                        local attached = attachments[input_focus()]
                        if attached then attached.view:send({type = "key", key = tostring(event.key or ""),
                            key_type = tostring(event.key_type or ""), action = event.action == "release" and "release" or "press",
                            ctrl = event.ctrl == true, alt = event.alt == true, shift = event.shift == true}) end
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
                                    if event.button == "right" then
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
                                    and (win.mode == "collapsed" or not layout.contains(body, x, y)) then
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
                                    local attached = attachments[win.id]
                                    if attached then attached.view:send({type = "mouse", x = x - body.x + 1, y = y - body.y + 1,
                                        action = event.action == "release" and "release" or (event.action == "wheel" and "wheel" or (event.action == "motion" and "motion" or "press")), button = tostring(event.button or ""), ctrl = event.ctrl == true, alt = event.alt == true, shift = event.shift == true}) end
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
                    local attached = attachments[input_focus()]
                    if attached then attached.view:send({type = "paste", text = tostring(event.text or "")}) end
                end
            end
        end
        if dirty and hydrated then paint() end
    end
    ticker:stop()
    process.unlisten(dialog_states)
    if not rejoining then process.send(owner, "bee.workspace.control", {version = 1, op = "quit"}) end
    for _, attached in pairs(attachments) do attached.view:close() end
    output:close()
    tty.stop()
    if fatal then error(fatal) end
end
return {main = main}
