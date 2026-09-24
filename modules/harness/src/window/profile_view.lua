-- MIT. Agent profile form rendering and input; persistence belongs to profile_form.
-- The folder and thread choices read the workspace catalog's roots and
-- folders and the caller's own threads through the owner calls the state is
-- given; choosing either saves nothing until the profile is saved.
local tty = require("tty")
local appearance = require("appearance")
local frame = require("frame")
local text = require("text")
local caller = require("caller")
local folder_picker = require("folder_picker")
local editor = require("editor")
local forms = require("forms")
local M = {}
M.THREADS = "bee.threads.service:list"
M.THREAD_PAGE = 64
type Ask = (string, {[string]: unknown}) -> caller.Reply
type Field = {kind: string, name: string, label: string, option_kind: string?, max_bytes: integer?}
-- A thread row; thread_id nil is the new thread the launch opens.
type ThreadRow = {thread_id: string?, title: string}
type Threads = {items: {ThreadRow}, selected: integer, error: string?}
type State = {form: forms.Form, title: string, guidance: string, option_text: {[string]: string}, selected: integer,
    status: string, confirming_remove: boolean, ask: Ask, browsing: folder_picker.Picker?, threads: Threads?,
    thread_titles: {[string]: string}, list_offset: integer}
type Frame = {rows: {string}, hits: {frame.Hit}}

function M.new(form: forms.Form, ask: Ask): State
    local option_text: {[string]: string} = {}
    local options = editor.options(form.draft) or {}
    for _, option in ipairs(options) do
        if option.kind == "text" then
            option_text[option.name] = type(option.value) == "string" and option.value or ""
        end
    end
    return {form = form, title = form.draft.title, guidance = form.draft.instructions,
        option_text = option_text, selected = 1, status = "", confirming_remove = false, ask = ask,
        browsing = nil, threads = nil, thread_titles = {}, list_offset = 0}
end
local function folder_label(state: State): string
    local workdir = state.form.draft.workdir
    if not workdir then return "Folder: Definition folder" end
    if workdir.path == "" then return "Folder: " .. workdir.root_ref end
    return "Folder: " .. workdir.root_ref .. "/" .. workdir.path
end
local function thread_label(state: State): string
    local thread = state.form.draft.thread
    if not thread then return "Thread: New thread" end
    return "Thread: " .. (state.thread_titles[thread.thread_id] or thread.thread_id)
end
local function fields(state: State): {Field}
    local result: {Field} = {{kind = "title", name = "", label = "Name"}}
    if state.form.draft._allowed.instructions then result[#result + 1] = {kind = "guidance", name = "", label = "Instructions"} end
    if state.form.draft._allowed.workdir then result[#result + 1] = {kind = "workdir", name = "", label = folder_label(state)} end
    if state.form.draft._allowed.thread then result[#result + 1] = {kind = "thread", name = "", label = thread_label(state)} end
    local options = editor.options(state.form.draft)
    for _, option in ipairs(options or {}) do
        result[#result + 1] = {kind = "option", name = option.name, option_kind = option.kind,
            max_bytes = option.max_bytes, label = option.name .. ": " .. (option.value == nil and "Default" or tostring(option.value))}
    end
    local tools = editor.tools(state.form.draft)
    for _, tool in ipairs(tools or {}) do
        result[#result + 1] = {kind = "tool", name = tool.name, label = (tool.selected and "[x] " or "[ ] ") .. tool.name}
    end
    return result
end
local function erase(value: string): string
    local index = #value
    while index > 1 do
        local byte = value:byte(index)
        if byte < 128 or byte >= 192 then break end
        index = index - 1
    end
    return value:sub(1, index - 1)
end
function M.action(state: State, action: string): string?
    if action == "cancel" then
        if state.confirming_remove then state.confirming_remove = false; return nil end
        return "cancel"
    end
    if action == "remove" then
        if state.form.revision < 1 or state.form.pending == "save" then return nil end
        if state.confirming_remove then return "remove" end
        state.confirming_remove = true
        return nil
    end
    if action == "save" then
        if state.confirming_remove then return nil end
        if state.form.pending then return state.form.pending end
        local named, name_error = editor.set_title(state.form.draft, state.title)
        if not named then state.status = name_error or "Invalid name"; return nil end
        local guided, guidance_error = editor.set_guidance(state.form.draft, state.guidance)
        if not guided then state.status = guidance_error or "Invalid instructions"; return nil end
        for name, value in pairs(state.option_text) do
            local changed, option_error = editor.set_text_option(state.form.draft, name, value)
            if not changed then state.status = option_error or "Invalid option"; return nil end
        end
        return "save"
    end
    return nil
end
local function load_folders(state: State, picker: folder_picker.Picker)
    local intent = folder_picker.folders_intent(picker)
    if intent then folder_picker.apply_folders(picker, state.ask(intent.target, intent.request)) end
    state.list_offset = 0
end
local function browse(state: State)
    local picker = folder_picker.new()
    local intent = folder_picker.roots_intent()
    folder_picker.apply_roots(picker, state.ask(intent.target, intent.request))
    state.browsing, state.list_offset = picker, 0
end
-- The threads this Agent may write to: its own threads, the ones it belongs to.
local function choose_thread(state: State)
    local items: {ThreadRow} = {{thread_id = nil, title = "New thread"}}
    local reply = state.ask(M.THREADS, {limit = M.THREAD_PAGE})
    local listed: Threads = {items = items, selected = 1, error = nil}
    local value = reply.ok and type(reply.value) == "table" and reply.value :: {[string]: unknown} or nil
    local threads = value and value.threads
    if not value or type(threads) ~= "table" then
        listed.error = reply.error and text.bound(reply.error.code .. ": " .. reply.error.message, 200) or "Threads could not be read"
    else
        for _, raw in ipairs(threads :: {unknown}) do
            local row = type(raw) == "table" and raw :: {[string]: unknown} or nil
            local id = row and row.thread_id
            if type(id) == "string" and id ~= "" and not id:find("%c") then
                local title = row and type(row.title) == "string" and text.bound(row.title :: string, 200) or id
                state.thread_titles[id] = title
                items[#items + 1] = {thread_id = id, title = title}
            end
        end
    end
    local current = state.form.draft.thread
    for index, item in ipairs(items) do
        if current and item.thread_id == current.thread_id then listed.selected = index end
    end
    state.threads, state.list_offset = listed, 0
end
local function key_of(event: tty.TTYEvent): string
    if event.type ~= "key" or event.action ~= "press" then return "" end
    return event.key_type
end
local function browse_input(state: State, picker: folder_picker.Picker, event: tty.TTYEvent, drawn: Frame)
    local key = key_of(event)
    if event.type == "mouse" and event.action == "press" and event.button == "left" then
        local hit = frame.hit(drawn.hits, math.floor(tonumber(event.x) or 0), math.floor(tonumber(event.y) or 0))
        if hit and hit.kind == "folder" then
            if picker.selected == hit.index then
                if folder_picker.open(picker) then load_folders(state, picker) end
            else folder_picker.select(picker, hit.index) end
        end
        return
    end
    if key == "escape" or key == "esc" then state.browsing = nil
    elseif key == "up" or key == "down" then
        if folder_picker.move(picker, key == "up" and -1 or 1) == "page" then load_folders(state, picker) end
    elseif key == "pgdown" then if folder_picker.forward(picker) then load_folders(state, picker) end
    elseif key == "pgup" then if folder_picker.backward(picker) then load_folders(state, picker) end
    elseif key == "enter" then if folder_picker.open(picker) then load_folders(state, picker) end
    elseif key == "backspace" or key == "left" then if folder_picker.up(picker) then load_folders(state, picker) end
    elseif event.type == "key" and event.action == "press" and (event.key == "u" or event.key == "d") and not event.ctrl then
        local root = picker.root
        if event.key == "u" and not root then return end
        local ok, err = editor.set_workdir(state.form.draft, event.key == "u" and root and root.root_ref or nil, picker.path)
        state.status = ok and "" or (err or "Folder is unavailable")
        state.browsing = nil
    end
end
local function thread_input(state: State, threads: Threads, event: tty.TTYEvent, drawn: Frame)
    local key = key_of(event)
    local chosen: integer? = nil
    if event.type == "mouse" and event.action == "press" and event.button == "left" then
        local hit = frame.hit(drawn.hits, math.floor(tonumber(event.x) or 0), math.floor(tonumber(event.y) or 0))
        if hit and hit.kind == "thread" then
            if threads.selected == hit.index then chosen = hit.index else threads.selected = hit.index end
        end
    elseif key == "escape" or key == "esc" then state.threads = nil
    elseif key == "up" then threads.selected = math.floor(math.max(1, threads.selected - 1))
    elseif key == "down" then threads.selected = math.floor(math.min(#threads.items, threads.selected + 1))
    elseif key == "enter" then chosen = threads.selected end
    if chosen then
        local item = threads.items[chosen]
        if item then
            local ok, err = editor.set_thread(state.form.draft, item.thread_id)
            state.status = ok and "" or (err or "Thread is unavailable")
        end
        state.threads = nil
    end
end
function M.input(state: State, event: tty.TTYEvent, drawn: Frame): string?
    local picker = state.browsing
    if picker then browse_input(state, picker, event, drawn); return nil end
    local threads = state.threads
    if threads then thread_input(state, threads, event, drawn); return nil end
    local listed = fields(state)
    if event.type == "mouse" and event.action == "press" and event.button == "left" then
        local hit = frame.hit(drawn.hits, math.floor(tonumber(event.x) or 0), math.floor(tonumber(event.y) or 0))
        if hit and hit.kind == "field" then state.selected = hit.index
        elseif hit then return M.action(state, hit.kind) end
    elseif event.type == "key" and event.action == "press" then
        if event.key_type == "escape" or event.key_type == "esc" then return M.action(state, "cancel") end
        if state.confirming_remove then
            if event.key_type == "enter" then return M.action(state, "remove") end
            return nil
        end
        if event.ctrl and event.key == "s" then return M.action(state, "save") end
        if event.ctrl and event.key == "d" then return M.action(state, "remove") end
        if event.key_type == "tab" or event.key_type == "down" or event.key_type == "up" then
            local delta = (event.key_type == "up" or (event.key_type == "tab" and event.shift)) and -1 or 1
            state.selected = math.floor(((state.selected - 1 + delta) % #listed) + 1)
            return nil
        end
    end
    if state.form.pending or state.confirming_remove then return nil end
    local field = listed[state.selected]
    if not field then return nil end
    if field.kind == "workdir" or field.kind == "thread" then
        if event.type == "key" and event.action == "press" and (event.key_type == "enter" or event.key_type == "space" or event.key == " ") then
            if field.kind == "workdir" then browse(state) else choose_thread(state) end
        end
        return nil
    end
    if field.kind == "tool" or (field.kind == "option" and field.option_kind == "enum") then
        if event.type == "key" and event.action == "press" and
            (event.key_type == "enter" or event.key_type == "space" or event.key == " " or event.key_type == "left" or event.key_type == "right") then
            local ok: boolean = false
            local err: string? = nil
            if field.kind == "tool" then ok, err = editor.toggle_tool(state.form.draft, field.name)
            else ok, err = editor.cycle_option(state.form.draft, field.name, event.key_type == "left" and -1 or 1) end
            state.status = ok and "" or (err or "Option is unavailable")
        end
        return nil
    end
    local value = field.kind == "title" and state.title
        or (field.kind == "option" and (state.option_text[field.name] or "") or state.guidance)
    local limit = field.kind == "title" and editor.MAX_TITLE_BYTES
        or (field.kind == "option" and (field.max_bytes or editor.MAX_INSTRUCTIONS_BYTES) or editor.MAX_INSTRUCTIONS_BYTES)
    if event.type == "paste" then value = value .. event.text
    elseif event.type == "key" and event.action == "press" then
        if event.ctrl and event.key == "u" then value = ""
        elseif event.key_type == "backspace" or event.key_type == "backspace2" then value = erase(value)
        elseif event.key_type == "enter" and field.kind == "guidance" then value = value .. "\n"
        elseif event.key_type == "space" and not event.ctrl and not event.alt then value = value .. " "
        elseif not event.ctrl and not event.alt and event.key ~= "" and not event.key:find("%c") then value = value .. event.key end
    end
    if #value > limit then state.status = "Text exceeds " .. tostring(limit) .. " bytes"; return nil end
    if field.kind == "title" then state.title = value
    elseif field.kind == "option" then state.option_text[field.name] = value
    else state.guidance = value end
    return nil
end

local HINTS = frame.hints({{key = "Tab", verb = "fields"}, {key = "Ctrl+S", verb = "save"}, {key = "Ctrl+D", verb = "remove"}, {key = "Esc", verb = "cancel"}})
local FOLDER_HINTS = frame.hints({{key = "Enter", verb = "open"}, {key = "⌫", verb = "up"}, {key = "U", verb = "use this folder"},
    {key = "D", verb = "definition folder"}, {key = "Esc", verb = "back"}})
local THREAD_HINTS = frame.hints({{key = "Enter", verb = "choose"}, {key = "Esc", verb = "back"}})
local function draw_folders(painter: frame.Painter, state: State, picker: folder_picker.Picker): Frame
    local layout = frame.layout(painter, false, false)
    local location = folder_picker.location(picker)
    frame.header(painter, "AGENT FOLDER", location ~= "" and location or "Choose a root")
    local work = layout.work
    if work.height >= 1 then
        local held = picker.held and " · a workspace" or ""
        frame.put(painter, work.x, work.y, (location ~= "" and location or "Choose a root") .. held, work.width, painter.theme.text)
    end
    local body: frame.Rect = {x = work.x, y = work.y + 2, width = work.width, height = math.floor(math.max(0, work.height - 2))}
    local window = folder_picker.draw(painter, body, picker, state.list_offset, "U use this folder")
    state.list_offset = window.offset
    frame.footer(painter, text.bound(state.status, 4096), FOLDER_HINTS)
    return {rows = frame.rows(painter), hits = painter.hits}
end
local function draw_threads(painter: frame.Painter, state: State, threads: Threads): Frame
    local layout = frame.layout(painter, false, false)
    frame.header(painter, "AGENT THREAD", "New or one of this Agent's threads")
    local work = layout.work
    local cells: {{string}} = {}
    for index, item in ipairs(threads.items) do cells[index] = {item.title} end
    if work.height >= 1 then
        local window = frame.table(painter, work.y, work.y + work.height - 1, {columns = {{title = "Thread", width = 0}}, cells = cells,
            kind = "thread", selected = threads.selected, offset = state.list_offset, focused = true, area = work})
        state.list_offset = window.offset
    end
    frame.footer(painter, text.bound(threads.error or state.status, 4096), THREAD_HINTS)
    return {rows = frame.rows(painter), hits = painter.hits}
end
function M.draw(width: integer, height: integer, preferences: appearance.Preferences, state: State): Frame
    local painter = frame.new(width, height, preferences)
    local picker = state.browsing
    if picker then return draw_folders(painter, state, picker) end
    local threads = state.threads
    if threads then return draw_threads(painter, state, threads) end
    frame.header(painter, state.form.revision > 0 and "EDIT AGENT PROFILE" or "NEW AGENT PROFILE")
    local listed = fields(state)
    local capacity = math.floor(math.max(0, height - 7))
    local window = frame.window(#listed, capacity, state.selected, 0)
    for slot = 1, window.capacity do
        local index = window.offset + slot
        local field = listed[index]
        if not field then break end
        local label = field.label
        if field.kind == "title" then label = label .. ": " .. state.title
        elseif field.kind == "option" and field.option_kind == "text" then
            label = field.name .. ": " .. (state.option_text[field.name] or "Default")
        elseif field.kind == "guidance" then label = label .. ": " .. state.guidance:gsub("\r?\n", " ↵ ") end
        frame.row(painter, slot + 2, text.bound(label, 4096), index == state.selected, "field", index, "")
    end
    frame.line(painter, height - 3, state.confirming_remove and "Remove this profile? Enter confirms; Esc keeps it." or
        (state.form.pending and "Request submitted. Retry uses the same values." or "Instructions append to the harness. Saving does not launch."),
        state.confirming_remove and painter.theme.text or painter.theme.muted)
    if height >= 3 then
        local buttons: {frame.Button} = {{kind = "save", label = "Save", enabled = not state.confirming_remove and state.form.pending ~= "remove", primary = true}}
        if state.form.revision > 0 then
            buttons[#buttons + 1] = {kind = "remove", label = state.confirming_remove and "Confirm" or "Remove",
                enabled = state.form.pending ~= "save", primary = state.confirming_remove}
        end
        buttons[#buttons + 1] = {kind = "cancel", label = "Cancel", enabled = true}
        frame.actions(painter, height - 1, buttons)
    end
    frame.footer(painter, text.bound(state.status, 4096), HINTS)
    return {rows = frame.rows(painter), hits = painter.hits}
end
return M
