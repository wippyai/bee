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
local canonical = require("canonical")
local settings = require("settings")
local bounds = require("bounds")
local confirmation = require("confirmation")
local M = {}
M.THREADS = "bee.threads.binding:list"
M.THREAD_PAGE = 64
type Ask = (string, {[string]: unknown}) -> caller.Reply
type Field = {kind: string, name: string, label: string, option_kind: string?, max_bytes: integer?}
-- A thread row; thread_id nil is the new thread the launch opens.
type ThreadRow = {thread_id: string?, title: string}
type Threads = {items: {ThreadRow}, selected: integer, error: string?}
type Driver = {definition_ref: string, title: string}
type State = {drivers: {Driver}?, driver_choice: Driver?, settings: {[string]: string}, form: forms.Form, title: string, guidance: string, option_text: {[string]: string}, selected: integer,
    credential_text: {[string]: string},
    status: string, confirmation: confirmation.State, ask: Ask, browsing: folder_picker.Picker?, threads: Threads?,
    thread_titles: {[string]: string}, list_offset: integer, advanced: boolean}
type Frame = {rows: {string}, hits: {frame.Hit}, controls: frame.Controls?}

function M.new(form: forms.Form, ask: Ask, drivers: {Driver}?, origin: {[string]: unknown}?): State
    local option_text: {[string]: string} = {}
    local options = editor.options(form.draft) or {}
    for _, option in ipairs(options) do
        if option.kind == "text" then
            option_text[option.name] = type(option.value) == "string" and option.value or ""
        end
    end
    local state: State = {drivers = drivers, settings = settings.read(form.draft), form = form, title = form.draft.name, guidance = (form.draft.provider.system_prompt_append or ""),
        option_text = option_text, credential_text = {}, selected = 1, status = form.migration_diagnostic and "Migration needs repair before launch. Original values are retained." or "", confirmation = confirmation.new({workspace_id = form.workspace_id, origin = origin or {app_id = "bee.harness.app:app", instance_id = form.profile_id}}, ask), ask = ask,
        browsing = nil, threads = nil, thread_titles = {}, list_offset = 0, advanced = false}
    state.confirmation.ask = function(target: string, request: {[string]: unknown}): caller.Reply return state.ask(target, request) end
    return state
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
local TOOL_NAMES = {
    thread_read = "Read conversation history", thread_message = "Add conversation notes",
    session_catalog = "Browse agents", session_open = "Open sessions", session_run = "Start work",
    session_send = "Send work to sessions", session_await = "Read work results", session_join = "Wait for multiple results",
    session_get = "Inspect sessions", session_list = "Find peer sessions", session_cancel = "Stop work", session_close = "Close sessions",
    capabilities = "Read available permissions", request_capability = "Request permissions", capability_status = "Read permission decisions",
    process_run = "Run approved commands", http_request = "Send approved web requests",
    app_tools = "Use workspace application tools",
    guide = "Read Bee help", preflight = "Check application changes", delivery = "Deliver application changes",
    install_request = "Request app installation", uninstall_request = "Request app removal", install_status = "Read installation status",
}
local function human(name: string): string
    local words = name:gsub("_", " ")
    return words:sub(1, 1):upper() .. words:sub(2)
end
local function fields(state: State): {Field}
    local result: {Field} = {{kind = "title", name = "", label = "Name"},
        {kind = "driver", name = "", label = "Driver: " .. (state.form.driver_name or state.form.draft.driver_binding_ref)}}
    result[#result + 1] = {kind = "answers", name = "", label = "Permission answers: " .. (state.form.draft.bee.permission_answers or "provider") ..
        (state.form.permission_transport and "" or " · host transport unavailable")}
    if state.form.draft._allowed.instructions then result[#result + 1] = {kind = "guidance", name = "", label = "System prompt"} end
    if state.form.draft._allowed.workdir then result[#result + 1] = {kind = "workdir", name = "", label = folder_label(state)} end
    if #(state.form.draft._allowed.placements or {}) > 1 then result[#result + 1] = {kind = "placement", name = "", label = "Run in: " .. ((state.form.placement_names or {})[editor.placement_ref(state.form.draft) or "bee.placement.profiles:native"] or editor.placement_ref(state.form.draft) or "Definition default")} end
    local options = editor.options(state.form.draft)
    local metadata = state.form.fields or {}
    table.sort(options or {}, function(a: {name: string}, b: {name: string}): boolean
        local x, y = metadata[a.name], metadata[b.name]
        local first, second = x and x.order or 0, y and y.order or 0
        if first ~= second then return first < second end
        return a.name < b.name
    end)
    for _, option in ipairs(options or {}) do
        if metadata[option.name] and metadata[option.name].section == "basic" then
            result[#result + 1] = {kind = "option", name = option.name, option_kind = option.kind,
                max_bytes = option.max_bytes, label = (metadata[option.name] and metadata[option.name].label or human(option.name)) .. ": " .. (option.value == nil and "Default" or tostring(option.value))}
        end
    end
    if state.form.repair_json then result[#result + 1] = {kind = "repair", name = "", label = "Migration repair"} end
    if state.advanced then
        local placement = state.form.draft.placement
        if not placement or placement.kind == "native" then result[#result + 1] = {kind = "home", name = "", label = "Native home: " .. (placement and placement.home or "Definition default")} end
        if state.form.migration_diagnostic then
            local reasons = bounds.ids(state.form.migration_diagnostic.reasons, true) or {}
            for _, reason in ipairs(reasons) do result[#result + 1] = {kind = "info", name = "", label = reason} end
            result[#result + 1] = {kind = "info", name = "", label = "Original: " .. (canonical.encode(state.form.migration_diagnostic.source) or "Unavailable")}
        end
        if state.form.draft._allowed.thread then result[#result + 1] = {kind = "thread", name = "", label = thread_label(state)} end
        for _, option in ipairs(options or {}) do
            if not metadata[option.name] or metadata[option.name].section == "advanced" then
                result[#result + 1] = {kind = "option", name = option.name, option_kind = option.kind,
                    max_bytes = option.max_bytes, label = (metadata[option.name] and metadata[option.name].label or human(option.name)) .. ": " .. (option.value == nil and "Default" or tostring(option.value))}
            end
        end
        for index, reason in ipairs(state.form.unsupported or {}) do result[#result + 1] = {kind = "unsupported", name = tostring(index), label = reason} end
        for _, tool in ipairs(editor.tools(state.form.draft) or {}) do
            result[#result + 1] = {kind = "tool", name = tool.name,
                label = (tool.selected and "[x] " or "[ ] ") .. (TOOL_NAMES[tool.name] or human(tool.name))}
            if tool.selected then
                local value = state.settings["mcp." .. tool.name]
                if value == nil then
                    for _, item in ipairs(state.form.draft.bee.mcp or {}) do
                        if item.tool == tool.name then value = canonical.encode(item.scope) end
                    end
                end
                result[#result + 1] = {kind = "scope", name = "mcp." .. tool.name, label = "MCP scope / traits: " .. (value or "{}")}
            end
        end
        for _, ref in ipairs(forms.credential_names(state.form)) do
            local chosen = state.form.draft.bee.credential_refs
            result[#result + 1] = {kind = "credential", name = ref,
                label = ((chosen == nil or bounds.member(ref, chosen)) and "[x] " or "[ ] ") .. "Credential " .. ref}
            if state.form.credential_keys and state.form.credential_keys[ref] then
                result[#result + 1] = {kind = "credential_value", name = ref, label = "API key " .. ref .. ": " ..
                    ((state.credential_text[ref] or "") ~= "" and "********" or "Enter to replace")}
            end
        end
        for _, ref in ipairs(state.form.leases or {}) do
            result[#result + 1] = {kind = "lease", name = ref,
                label = (bounds.member(ref, state.form.draft.bee.approval_leases or {}) and "[x] " or "[ ] ") .. "Approval lease: " .. ref}
        end
        result[#result + 1] = {kind = "refresh", name = "", label = "Refresh runtime options: " .. (state.form.readiness or "not probed")}
        for _, field in ipairs(settings.fields(state.form.draft)) do result[#result + 1] = field end
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
local function confirm_target(state: State, action: string): {[string]: unknown}
    return {profile_id = state.form.profile_id, revision = state.form.revision,
        placement_profile_ref = action == "docker.revoke" and editor.placement_ref(state.form.draft) or nil}
end
function M.action(state: State, action: string, gesture: "enter" | "space" | "click" | "shortcut"?): string?
    if action == "advanced" and not state.form.pending then
        state.advanced = not state.advanced; state.selected = 1; return nil
    end
    if action == "revoke_docker" and state.advanced and (state.form.draft.placement and state.form.draft.placement.kind == "docker") then
        local opened, err = confirmation.open(state.confirmation, "docker.revoke", confirm_target(state, "docker.revoke"), "inline",
            "Revoke Docker access?", "Revoke Docker network and gateway access?")
        state.status = opened and "Revoke Docker network and gateway access? Enter confirms; Esc keeps it." or err or "Confirmation is unavailable"
        return nil
    end
    if action == "cancel" then
        state.credential_text = {}
        if confirmation.active(state.confirmation) then
            local canceled, err = confirmation.cancel(state.confirmation)
            state.status = canceled and "" or err or "Withdrawal is unavailable"
            return nil
        end
        return "cancel"
    end
    if action == "remove" then
        if state.form.revision < 1 or state.form.pending == "save" then return nil end
        if confirmation.matches(state.confirmation, "profile.remove") then
            local accepted, err = confirmation.accept(state.confirmation, confirm_target(state, "profile.remove"), gesture or "shortcut")
            if accepted then return "remove" end
            state.status = err or "Confirmation is unavailable"
            return nil
        end
        local opened, err = confirmation.open(state.confirmation, "profile.remove", confirm_target(state, "profile.remove"), "inline", "Remove this profile?", "Remove this profile?")
        if not opened then state.status = err or "Confirmation is unavailable" end
        return nil
    end
    if action == "copy" or action == "reload" then return action end
    if action == "save" then
        if confirmation.matches(state.confirmation, "profile.remove") then return nil end
        if state.form.pending then return state.form.pending end
        local named, name_error = editor.set_title(state.form.draft, state.title)
        if not named then state.status = name_error or "Invalid name"; return nil end
        local guided, guidance_error = editor.set_guidance(state.form.draft, state.guidance)
        if not guided then state.status = guidance_error or "Invalid instructions"; return nil end
        for name, value in pairs(state.option_text) do
            local changed, option_error = editor.set_text_option(state.form.draft, name, value)
            if not changed then state.status = option_error or "Invalid option"; return nil end
        end
        for name, value in pairs(state.settings) do
            local tool = name:match("^mcp%.(.+)$")
            if tool then
                local changed, scope_error = editor.set_tool_scope(state.form.draft, tool, value)
                if not changed then state.status = scope_error or "Invalid MCP scope"; return nil end
            end
        end
        local settings_error = settings.apply(state.form.draft, state.settings)
        if settings_error then state.status = settings_error; return nil end
        for _, name in ipairs(forms.credential_names(state.form)) do
            local value = state.credential_text[name]
            if value and value ~= "" then
                local reply = state.ask("bee.harness.binding:set_credential", {workspace_id = state.form.workspace_id,
                    definition_ref = state.form.draft.definition_ref, expected_definition_digest = state.form.definition_digest,
                    name = name, value = value})
                state.credential_text[name] = ""
                if not reply.ok then state.status = "Credential could not be stored"; return nil end
            end
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
    local value = reply.ok and type(reply.value) == "table" and reply.value or nil
    local threads = value and value.threads
    if not value or type(threads) ~= "table" then
        listed.error = reply.error and text.bound(reply.error.code .. ": " .. reply.error.message, 200) or "Threads could not be read"
    else
        for _, raw in ipairs(threads) do
            local row = type(raw) == "table" and raw or nil
            local id = row and row.thread_id
            if type(id) == "string" and id ~= "" and not id:find("%c") then
                local title = row and type(row.title) == "string" and text.bound(row.title, 200) or id
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
        elseif hit then return M.action(state, hit.kind, "click") end
    elseif event.type == "key" and event.action == "press" then
        if event.key_type == "escape" or event.key_type == "esc" then return M.action(state, "cancel") end
        if confirmation.matches(state.confirmation, "docker.revoke") then
            if event.key_type == "enter" then
                local accepted, err = confirmation.accept(state.confirmation, confirm_target(state, "docker.revoke"), "enter")
                if not accepted then state.status = err or "Confirmation is unavailable"; return nil end
                local reply = state.ask("bee.placement.docker.binding:prepare_environment", {workspace_id = state.form.workspace_id,
                    placement_profile_ref = editor.placement_ref(state.form.draft), revoke = true})
                state.status = reply.ok and "Docker network and gateway access revoked" or reply.error and reply.error.message or "Revocation did not answer"
            end
            return nil
        end
        if event.ctrl and event.key == "r" then return M.action(state, "revoke_docker") end
        if confirmation.matches(state.confirmation, "profile.remove") then
            if event.key_type == "enter" then return M.action(state, "remove", "enter") end
            return nil
        end
        if event.ctrl and event.key == "p" then return M.action(state, "advanced") end
        if event.ctrl and event.key == "s" then return M.action(state, "save") end
        if event.ctrl and event.key == "d" then return M.action(state, "remove") end
        if event.key_type == "tab" or event.key_type == "down" or event.key_type == "up" then
            local delta = (event.key_type == "up" or (event.key_type == "tab" and event.shift)) and -1 or 1
            state.selected = math.floor(((state.selected - 1 + delta) % #listed) + 1)
            return nil
        end
    end
    if state.form.pending or confirmation.matches(state.confirmation, "profile.remove") then return nil end
    local field = listed[state.selected]
    if not field or field.kind == "unsupported" or field.kind == "info" then return nil end
    if field.kind == "driver" then
        if event.type == "key" and event.action == "press" and (event.key_type == "enter" or event.key_type == "left" or event.key_type == "right") then
            local drivers = state.drivers or {}
            if #drivers == 0 then state.status = "Choose an installed driver from New session"; return nil end
            local current = 0
            for index, item in ipairs(drivers) do if item.definition_ref == state.form.draft.definition_ref then current = index end end
            local delta = event.key_type == "left" and -1 or 1
            state.driver_choice = drivers[((current - 1 + delta) % #drivers) + 1]
            return "driver"
        end
        return nil
    end
    if field.kind == "workdir" or field.kind == "thread" then
        if event.type == "key" and event.action == "press" and (event.key_type == "enter" or event.key_type == "space" or event.key == " ") then
            if field.kind == "workdir" then browse(state) else choose_thread(state) end
        end
        return nil
    end
    if field.kind == "home" or field.kind == "answers" or field.kind == "placement" or field.kind == "credential" or field.kind == "lease" or field.kind == "refresh" or field.kind == "tool" or (field.kind == "option" and field.option_kind == "enum") then
        if event.type == "key" and event.action == "press" and
            (event.key_type == "enter" or event.key_type == "space" or event.key == " " or event.key_type == "left" or event.key_type == "right") then
            local ok: boolean = false
            local err: string? = nil
            if field.kind == "home" then ok, err = editor.cycle_home(state.form.draft)
            elseif field.kind == "answers" then
                local current = state.form.draft.bee.permission_answers
                if state.form.permission_transport then
                    state.form.draft.bee.permission_answers = current == "provider" and "ask" or current == "ask" and "deny" or "provider"
                else state.form.draft.bee.permission_answers = "provider" end
                ok = true
            elseif field.kind == "placement" then ok, err = editor.cycle_placement(state.form.draft, event.key_type == "left" and -1 or 1)
            elseif field.kind == "refresh" then
                local ready = M.action(state, "save") == "save"
                if not ready then return nil end
                local refreshed, refresh_error = forms.refresh(state.form)
                if refreshed then state.form = refreshed; ok = true else err = refresh_error end
            elseif field.kind == "lease" then
                local refs: {string} = {}
                local chosen = false
                for _, ref in ipairs(state.form.draft.bee.approval_leases or {}) do
                    if ref == field.name then chosen = true else refs[#refs + 1] = ref end
                end
                if not chosen then refs[#refs + 1] = field.name end
                state.form.draft.bee.approval_leases = refs; ok = true
            elseif field.kind == "credential" then
                local refs: {string} = {}
                for _, ref in ipairs(state.form.draft.bee.credential_refs or forms.credential_names(state.form)) do refs[#refs + 1] = ref end
                local found = false
                for index, ref in ipairs(refs) do if ref == field.name then table.remove(refs, index); found = true; break end end
                if not found then refs[#refs + 1] = field.name end
                state.form.draft.bee.credential_refs = refs; ok = true
            elseif field.kind == "tool" then ok, err = editor.toggle_tool(state.form.draft, field.name)
            else ok, err = editor.cycle_option(state.form.draft, field.name, event.key_type == "left" and -1 or 1) end
            state.status = ok and "" or (err or "Option is unavailable")
        end
        return nil
    end
    local value = field.kind == "credential_value" and (state.credential_text[field.name] or "") or (field.kind == "settings" or field.kind == "scope") and (state.settings[field.name] or "") or field.kind == "repair" and (state.form.repair_json or "") or field.kind == "title" and state.title
        or (field.kind == "option" and (state.option_text[field.name] or "") or state.guidance)
    if field.kind == "scope" and state.settings[field.name] == nil then
        for _, item in ipairs(state.form.draft.bee.mcp or {}) do
            if "mcp." .. item.tool == field.name then value = canonical.encode(item.scope) or "{}" end
        end
    end
    local limit = field.kind == "credential_value" and 65536 or field.kind == "scope" and 8192 or field.kind == "settings" and 32 or field.kind == "repair" and 65536 or field.kind == "title" and editor.MAX_TITLE_BYTES
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
    if field.kind == "credential_value" then state.credential_text[field.name] = value
    elseif field.kind == "settings" or field.kind == "scope" then state.settings[field.name] = value
    elseif field.kind == "repair" then state.form.repair_json = value
    elseif field.kind == "title" then state.title = value
    elseif field.kind == "option" then state.option_text[field.name] = value
    else state.guidance = value end
    return nil
end

local HINTS = frame.hints({{key = "Tab", verb = "fields"}, {key = "Ctrl+S", verb = "save"},
    {key = "Ctrl+P", verb = "Advanced"}, {key = "Esc", verb = "cancel"}})
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
    frame.footer(painter, text.bound(state.status, 4096), FOLDER_HINTS, nil, footer_buttons)
    return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter)}
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
    frame.footer(painter, text.bound(threads.error or state.status, 4096), THREAD_HINTS, nil, footer_buttons)
    return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter)}
end
function M.draw(width: integer, height: integer, preferences: appearance.Preferences, state: State): Frame
    local painter = frame.new(width, height, preferences)
    local footer_buttons: {frame.Button} = {}
    local picker = state.browsing
    if picker then return draw_folders(painter, state, picker) end
    local threads = state.threads
    if threads then return draw_threads(painter, state, threads) end
    frame.header(painter, state.form.revision > 0 and "EDIT AGENT PROFILE" or "NEW AGENT PROFILE", state.advanced and "Advanced" or "Name · agent settings")
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
            label = human(field.name) .. ": " .. (state.option_text[field.name] or "Default")
        elseif field.kind == "settings" then label = label .. ": " .. (state.settings[field.name] ~= "" and state.settings[field.name] or "Default")
        elseif field.kind == "repair" then label = label .. ": " .. (state.form.repair_json or "")
        elseif field.kind == "guidance" then label = label .. ": " .. state.guidance:gsub("\r?\n", " ↵ ") end
        frame.row(painter, slot + 2, text.bound(label, 4096), index == state.selected, "field", index, "")
    end
    frame.line(painter, height - 3, confirmation.matches(state.confirmation, "profile.remove") and "Remove this profile? Enter confirms; Esc keeps it." or
        (state.form.pending and "Request submitted. Retry uses the same values." or "Instructions append to the harness. Saving does not launch."),
        confirmation.matches(state.confirmation, "profile.remove") and painter.theme.text or painter.theme.muted)
    if height >= 3 then
        local buttons: {frame.Button} = {{kind = "save", key = "Ctrl+S", label = "Save", enabled = not confirmation.matches(state.confirmation, "profile.remove") and state.form.pending ~= "remove", primary = true}}
        if state.advanced and editor.placement_ref(state.form.draft) == "bee.placement.docker.profiles:coding" then
            buttons[#buttons + 1] = {kind = "revoke_docker", key = "Ctrl+R", label = "Revoke Docker access", enabled = not state.form.pending}
        end
        if state.form.revision > 0 then
            buttons[#buttons + 1] = {kind = "remove", key = "Ctrl+D", label = confirmation.matches(state.confirmation, "profile.remove") and "Confirm" or "Remove",
                enabled = state.form.pending ~= "save", primary = confirmation.matches(state.confirmation, "profile.remove")}
        end
        buttons[#buttons + 1] = {kind = "cancel", key = "Esc", label = "Cancel", enabled = true}
        if state.advanced and (state.form.draft.placement and state.form.draft.placement.kind == "docker") then
            buttons[#buttons + 1] = {kind = "revoke_docker", key = "Ctrl+R", label = "Revoke Docker access", enabled = not state.form.pending}
        end
        buttons[#buttons + 1] = {kind = "advanced", key = "Ctrl+P", label = state.advanced and "Basic fields" or "Advanced", enabled = not state.form.pending}
        if state.form.conflict then
            buttons[#buttons + 1] = {kind = "copy", key = "", label = "Save copy", enabled = true}
            buttons[#buttons + 1] = {kind = "reload", key = "", label = "Reload", enabled = true}
        end
        footer_buttons = buttons
    end
    if state.status ~= "" and height >= 7 then frame.line(painter, height - 2, text.bound(state.status, 4096), painter.theme.text) end
    frame.footer(painter, "", HINTS, nil, footer_buttons)
    return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter)}
end
return M
