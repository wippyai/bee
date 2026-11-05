-- MIT. How a display routes the person's input: an open dialog, title editor,
-- copy mode, workspace menu or Start panel takes it first; then the display's
-- own keys and the mouse on the bar and window frames; everything else reaches
-- the focused window's app.
local tty = require("tty")
local client = require("client")
local model = require("model")
local layout = require("layout")
local menu = require("menu")
local dialog = require("dialog")
local confirmation = require("confirmation")
local title_editor = require("title_editor")
local copy = require("copy")
local workspace_menu = require("workspace_menu")
local part_handover = require("part_handover")
local display_state = require("display_state")
local actions = require("actions")
local M = {}
type Result = part_handover.Result
type State = display_state.State

local APP_DIALOG = display_state.APP_DIALOG
local scene, set_scene, input_focus = display_state.scene, display_state.set_scene, display_state.input_focus
local run, invoke = actions.run, actions.invoke

-- answer applies the accepted answer of the dialog spec_id names.
local function answer(state: State, spec_id: string, value: string, gesture: string)
    if spec_id:sub(1, #APP_DIALOG) == APP_DIALOG then
        actions.answer_app(state, spec_id, "accept", value, gesture)
    elseif spec_id == "workspace_add" then
        local path, shown = value, state.desktop
        local call_job = state.jobs.call_job
        run(state, function(): Result
            local added, err = client.call(state.target, "workspace_add", {path = path})
            if not added then return {kind = "failed", problem = err} end
            if type(added.workspace) ~= "string" then return {kind = "failed", problem = "workspace_add returned no workspace"} end
            return call_job("desktop_workspace", {id = shown, workspace = added.workspace})
        end)
    elseif spec_id:sub(1, 15) == "desktop_rename:" then
        actions.call(state, "desktop_rename", {id = spec_id:sub(16), title = value})
    elseif spec_id:sub(1, 14) == "desktop_close:" then
        local id = spec_id:sub(15)
        local review = state.desktop_review
        state.desktop_review = nil
        if not review or review.id ~= id then state.status = "Desktop confirmation is unavailable"; return end
        run(state, function(): Result
            local result, err = client.call(review.node, "desktop_close", {id = id, approval_id = review.approval_id, gesture = gesture})
            return result and {kind = "done"} or {kind = "failed", problem = err}
        end)
    end
end

-- F4 opens the request the focused window waits on in Needs you; Enter
-- and every typed key reach the window itself.
local function open_focused_review(state: State): boolean
    local id = input_focus(state)
    for _, instance in ipairs(state.running) do
        if instance.id == id and instance.review then
            actions.open_app(state, "bee.approvals.inbox.app:app", {"--review", instance.review.approval_id})
            return true
        end
    end
    return false
end

local function send_focused(state: State, event: tty.InputEvent)
    local id = input_focus(state)
    local view = state.views[id]
    if view then
        if state.alerts[id] and event.type == "key" and not event.ctrl and not event.alt then
            local key = event.key:lower()
            if key == "a" or key == "d" or key == "f" or key:match("^[1-4]$") then
                local snapshot = view:snapshot()
                if state.presented_focus ~= id or not snapshot or snapshot.revision ~= state.presented_revisions[id] then return end
            end
        end
        local sent, err = view:send(event)
        if not sent then state.status = tostring(err) end
    end
end

local function on_bar(state: State, event: tty.MouseEvent)
    local x, y = event.x, event.y
    if event.action ~= "press" or (event.button ~= "left" and event.button ~= "right") then return end
    if x <= 7 and event.button == "left" then
        if state.start then state.start = nil else state.start = {selected = 1, offset = 0} end
        return
    end
    for _, hit in ipairs(state.tab_hits) do
        if x >= hit.x and x < hit.x + hit.width then
            if hit.action == "attention" then invoke(state, "attention")
            elseif hit.action == "workspaces" then invoke(state, "workspaces")
            elseif event.button == "right" and hit.id ~= "" then
                state.start = {selected = 1, offset = 0, kind = "window", target = hit.id, x = x, y = y + 1}
            elseif hit.action == "close" then actions.close_app(state, hit.id)
            elseif hit.action == "minimize" then invoke(state, "minimize", hit.id)
            elseif hit.action == "fullscreen" then invoke(state, "fullscreen", hit.id)
            elseif hit.id ~= "" then display_state.focus(state, hit.id) end
            return
        end
    end
    if event.button == "right" then state.start = {selected = 1, offset = 0, kind = "desktop", x = x, y = y + 1} end
end

local function on_mouse(state: State, event: tty.MouseEvent)
    local x, y = event.x, event.y
    local current = scene(state)
    local capture = state.capture
    if capture then
        if event.action == "release" then
            local placed = layout.drag(current, capture, x, y) or state.preview
            if placed then set_scene(state, model.place(current, capture.id, placed)) end
            state.capture, state.preview = nil, nil
        else
            state.preview = layout.drag(current, capture, x, y)
        end
        return
    end
    if event.action == "press" and event.button == "left" then
        for _, hit in ipairs(state.tab_hits) do
            if hit.action == "attention" and hit.y and y >= hit.y and y < hit.y + (hit.height or 1)
                and x >= hit.x and x < hit.x + hit.width then invoke(state, "attention"); return end
        end
    end
    if state.height >= 3 and y == 1 then on_bar(state, event); return end
    local visible = model.visible(current)
    for index = #visible, 1, -1 do
        local win = visible[index]
        local rect = layout.rectangle(current, win, nil, nil)
        if layout.contains(rect, x, y) then
            local body = layout.interior(win, rect)
            if event.action == "press" then
                display_state.focus(state, win.id)
                current = scene(state)
            end
            if event.action == "press" and event.button == "right"
                and (event.shift == true or win.mode == "collapsed" or not layout.contains(body, x, y)) then
                state.start = {selected = 1, offset = 0, kind = "window", target = win.id, x = x, y = y}
                return
            end
            local control = layout.control_at(win, rect, x, y)
            if control and event.action == "press" and event.button == "left" then
                invoke(state, control, win.id)
                return
            end
            if event.action == "press" and event.button == "left" and (body.x ~= rect.x or win.mode == "collapsed") then
                local edge = win.mode == "collapsed" and "move" or layout.edge(rect, x, y)
                if edge ~= "" then state.capture = {id = win.id, x = x, y = y, bounds = rect, edge = edge} end
            end
            if not state.capture and win.mode ~= "collapsed" and layout.contains(body, x, y) then
                local content = state.contents[win.id]
                if state.views[win.id] then actions.copied(state, win.id, copy.pointer(state.clip, win.id, body, content and content.rows or {}, event, display_state.drags(state, win.id))) end
            end
            return
        end
    end
    if event.action == "press" then
        if event.button == "left" then set_scene(state, model.focus(current, ""))
        elseif event.button == "right" then state.start = {selected = 1, offset = 0, kind = "desktop", x = x, y = y} end
    end
end

local function on_workspaces(state: State, current_menu: workspace_menu.Menu, event: tty.TTYEvent)
    local width, height = state.width, state.height
    local response: workspace_menu.Response
    if event.type == "mouse" then
        if event.action ~= "press" then return end
        if not workspace_menu.contains(width, height, current_menu, event.x, event.y) then state.workspaces_open = nil; return end
        if event.button ~= "left" then return end
        local tab = workspace_menu.tab_at(current_menu, width, height, event.x, event.y)
        if tab then
            actions.browse_node(state, workspace_menu.choose(current_menu, tab))
            return
        end
        local index = workspace_menu.row_at(current_menu, width, height, event.x, event.y)
        if not index then return end
        current_menu.selected = index
        response = workspace_menu.respond(current_menu, {type = "key", key = "enter", key_type = "enter", action = "press"})
    else
        response = workspace_menu.respond(current_menu, event)
    end
    if response.close then state.workspaces_open = nil end
    actions.browse_node(state, response.browse)
    if response.node then actions.retarget(state, response.node, nil, response.switch)
    elseif response.switch then actions.switch(state, response.switch) end
    if response.create then actions.new_desktop(state) end
    if response.forget then actions.call(state, "workspace_remove", {id = response.forget.id}) end
    if response.use then actions.use_workspace(state, response.use) end
    if response.rename then
        actions.ask(state, {id = "desktop_rename:" .. response.rename.id, kind = "text", title = "Rename desktop",
            message = "", accept = "Rename", initial = response.rename.title})
    end
    if response.remove then
        local opened, err = client.call(state.target, "desktop_confirmation", {id = response.remove.id})
        if opened and type(opened.approval_id) == "string" then
            state.desktop_review = {id = response.remove.id, approval_id = opened.approval_id, node = state.target}
            actions.ask(state, {id = "desktop_close:" .. response.remove.id, kind = "confirm", title = "Close desktop",
                message = "Close " .. response.remove.title .. " and stop its apps?", accept = "Close", initial = ""})
        else state.status = err or "Confirmation is unavailable" end
    end
    if response.add then
        actions.ask(state, {id = "workspace_add", kind = "text", title = "Add workspace",
            message = "Absolute path of the folder", accept = "Add", initial = ""})
    end
end

local function on_key(state: State, event: tty.KeyEvent)
    local kind = event.key_type
    if event.action ~= "release" then
        if event.ctrl == true and event.key == "w" then actions.close_app(state, input_focus(state)); return end
        if kind == "f9" and event.alt == true then invoke(state, "minimize"); return end
        if kind == "f11" then invoke(state, "fullscreen"); return end
        if kind == "f12" then invoke(state, "rejoin"); return end
        if event.alt == true and (event.key == "q" or event.key == "c") then actions.begin_copy(state, event.key == "q" and "hints" or "cursor", input_focus(state)); return end
        if kind == "tab" and event.alt == true then
            local list = display_state.order(state)
            if #list > 0 then
                local focused = input_focus(state)
                local step = event.shift == true and -1 or 1
                local next_id = step < 0 and list[#list] or list[1]
                for index, id in ipairs(list) do
                    if id == focused then next_id = list[(index - 1 + step + #list) % #list + 1]; break end
                end
                display_state.focus(state, next_id)
            end
            return
        end
    end
    send_focused(state, event)
end

-- on_dialog routes an event to the open dialog.
local function on_dialog(state: State, current_modal: dialog.State, event: tty.TTYEvent)
    local response = dialog.respond(current_modal, event, state.width, state.height)
    state.modal = response.state
    if response.action == "accept" then
        state.modal = nil
        answer(state, current_modal.spec.id, response.value, confirmation.gesture(event))
        actions.show_app_dialog(state)
    elseif response.action == "cancel" then
        state.modal = nil
        if current_modal.spec.id:sub(1, #APP_DIALOG) == APP_DIALOG then actions.answer_app(state, current_modal.spec.id, "cancel", "", confirmation.gesture(event)) end
        local review = state.desktop_review
        if review then
            state.desktop_review = nil
            run(state, function(): Result
                local result, err = client.call(review.node, "desktop_confirmation", {operation = "cancel", id = review.id, approval_id = review.approval_id})
                return result and {kind = "done"} or {kind = "failed", problem = err}
            end)
        end
        actions.show_app_dialog(state)
    end
end

-- on_input routes one terminal event and reports whether the display quits.
function M.on_input(state: State, event: tty.TTYEvent): boolean
    if event.type == "close" then return true end
    if event.type == "resize" then
        state.width, state.height = math.floor(event.width), math.floor(event.height)
        copy.cancel(state.clip)
        state.capture, state.preview = nil, nil
        if state.workspaces_open and not workspace_menu.available(state.width, state.height) then state.workspaces_open = nil end
        return false
    end
    if event.type == "key" and event.ctrl == true and event.key == "q" and event.action ~= "release" then return true end
    if state.noticed and (event.type == "key" or (event.type == "mouse" and event.action == "press")) then
        state.status, state.noticed = "", false
    end
    if event.type == "key" and event.key_type == "f4" and event.action ~= "release" then
        if open_focused_review(state) then return false end
        if display_state.current_alert(state) then invoke(state, "attention"); return false end
    end
    local current_modal = state.modal
    if current_modal then
        on_dialog(state, current_modal, event)
        return false
    end
    local current_editor = state.editor
    if current_editor then
        local response = title_editor.respond(current_editor, event, title_editor.panel(state.width, state.height))
        state.editor = response.state
        if response.action == "save" then
            set_scene(state, model.personalize(scene(state), response.state.id, response.state.left .. response.state.right, response.state.accent))
            state.editor = nil
        elseif response.action == "cancel" then state.editor = nil end
        return false
    end
    if copy.engaged(state.clip) then
        local id = copy.view(state.clip)
        local outcome = copy.input(state.clip, event, id and copy.body(scene(state), id) or nil)
        actions.copied(state, id, outcome)
        if not outcome.pass then return false end
    end
    local current_menu = state.workspaces_open
    if current_menu then
        on_workspaces(state, current_menu, event)
        return false
    end
    if state.capture and event.type == "key" and (event.key_type == "esc" or event.key_type == "escape") and event.action ~= "release" then
        state.capture, state.preview = nil, nil
        return false
    end
    if event.type == "key" and event.key_type == "f1" and event.action ~= "release" then
        if state.start then state.start = nil else state.start = {selected = 1, offset = 0} end
        state.capture, state.preview = nil, nil
        return false
    end
    if event.type == "key" and event.key_type == "f3" and event.action ~= "release" then
        invoke(state, "workspaces")
        return false
    end
    local current_start = state.start
    if current_start and not (event.type == "mouse" and state.height >= 3 and event.y == 1 and event.x <= 7 and event.action == "press") then
        local items = menu.entries(current_start, scene(state), state.catalog, menu.destinations(state.desktops, state.desktop))
        local panel = menu.panel(state.width, state.height, items, current_start)
        local response = menu.respond(current_start, panel, items, event)
        state.start = response.state
        if response.close then state.start = nil end
        if response.action ~= "" then invoke(state, response.action, current_start.target) end
        return false
    end
    if event.type == "key" then on_key(state, event)
    elseif event.type == "mouse" then on_mouse(state, event)
    elseif event.type == "paste" then send_focused(state, event) end
    return false
end

return M
