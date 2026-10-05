-- MIT. Settings: the node's appearance and About. Themes, backgrounds and tab
-- style are node settings; choosing one asks the node, which restyles every
-- display and app. About reads installed Bee packs and their Hub releases
-- through the Hub facade when it opens, on R, and again after each registry
-- commit, which is when installed packs change. Edit mode asks the person,
-- through the node's dialogs, which namespaces this workspace may edit and
-- for how long, and governance admits them. view owns geometry.
local tty = require("tty")
local channel = require("channel")
local process = require("process")
local system = require("system")
local funcs = require("funcs")
local eventbus = require("events")
local appearance = require("appearance")
local frame = require("frame")
local client = require("client")
local view = require("view")
local choice = require("choice")
local live_updates = require("live_updates")
local app = require("app")

type Result = {kind: string, themes: {appearance.Theme}?, problem: string?, sequence: integer?}
type UpdateRead = {future: funcs.Future, response: channel.Channel}

local HUB = "bee.hub.binding:call"
local SUPER_EDIT = "bee.gov.binding:super_edit_call"

local function main(options: unknown)
    local node = assert(system.node.id())
    local folder = ""
    if type(options) == "table" and type(options.workspace) == "table" and type(options.workspace.path) == "string" then
        folder = options.workspace.path
    end
    local runtime_version = system.version()
    local build: view.Build = {runtime = runtime_version ~= "" and runtime_version or "unknown", lua = _VERSION, node = node, folder = folder}
    local input = assert(tty.events())
    local menu = frame.menu()
    local lifecycle = assert(process.events())
    local changes = assert(process.listen(appearance.TOPIC, {message = true}))
    local launch = app.launch(options)
    local answers = assert(process.listen("bee.app.query.result", {message = true}))
    -- edit_query is the dialog edit mode waits on and edit_operation what its
    -- answer continues; edit_input is the namespace list being confirmed.
    local edit_query, edit_operation, edit_input = "", "", ""
    local registry_changes = assert(eventbus.subscribe("registry", "registry.commit"))
    local commits = registry_changes:channel()
    assert(tty.start())
    local output = assert(tty.surface())
    local width, height = tty.screen_size()
    local chosen = choice.new(appearance.chosen(options))
    local preferences = choice.shown(chosen)
    local themes: {appearance.Theme} = {}
    local status = "Loading themes…"
    local pane: view.Pane = "theme"
    local offset = 0
    local hits: {frame.Hit} = {}
    local results = channel.new(4)
    local running, dirty = true, true
    local live_status: live_updates.Status? = nil
    local live_pending = false
    local update_read: UpdateRead? = nil
    local refresh_again = false

    local function run(job: () -> Result)
        coroutine.spawn(function() results:send(job()) end)
    end
    local function count(): integer return view.count(pane, themes) end
    local function selected(): integer
        if pane == "taskbar" then return preferences.taskbar == "icons" and 2 or 1 end
        if pane == "theme" then
            for index, theme in ipairs(themes) do if theme.id == preferences.theme.id then return index end end
        else
            for index, background in ipairs(appearance.backgrounds()) do if background == preferences.background then return index end end
        end
        return 1
    end
    local function reveal()
        if pane == "about" then
            offset = view.about_offset(offset, math.floor(width), math.floor(height), live_status, live_pending, build)
            return
        end
        offset = view.offset(selected(), offset, view.grid(math.floor(width), math.floor(height)), count(), true)
    end
    local function choose(index: integer)
        if count() == 0 then return end
        local value = math.floor(math.max(1, math.min(count(), index)))
        local args: {[string]: unknown} = {}
        local next_value: appearance.Preferences = {theme = preferences.theme, background = preferences.background, taskbar = preferences.taskbar}
        if pane == "theme" then
            args.theme = themes[value].id
            next_value.theme = themes[value]
        elseif pane == "background" then
            args.background = appearance.backgrounds()[value]
            next_value.background = appearance.backgrounds()[value]
        else
            args.taskbar = value == 2 and "icons" or "labels"
            next_value.taskbar = value == 2 and "icons" or "labels"
        end
        local sequence = choice.request(chosen, next_value)
        preferences = choice.shown(chosen)
        status = ""
        reveal()
        run(function(): Result
            local _, err = client.call(node, "appearance", args)
            if err then return {kind = "failed", themes = nil, problem = err, sequence = sequence} end
            return {kind = "applied", themes = nil, problem = nil, sequence = sequence}
        end)
        dirty = true
    end
    local function browse(amount: integer)
        if pane == "about" then
            offset = view.about_offset(offset + amount, math.floor(width), math.floor(height), live_status, live_pending, build)
        else
            offset = view.offset(selected(), offset + amount, view.grid(math.floor(width), math.floor(height)), count(), false)
        end
        dirty = true
    end
    local function read_failed(problem: string)
        live_status = live_updates.failure(problem)
        live_pending = false
        reveal()
        dirty = true
    end
    -- request_live_updates reads the update status; a request while one is in
    -- flight runs once more after it when forced.
    local function request_live_updates(force: boolean)
        if update_read then
            if force then refresh_again = true end
            return
        end
        live_pending = true
        dirty = true
        local future, future_error = funcs.new():async(HUB, {operation = "updates"})
        if not future or future_error then return read_failed(tostring(future_error or "Hub status call is unavailable")) end
        local response = future:response()
        if not response then
            future:cancel()
            return read_failed("Hub status response channel is unavailable")
        end
        update_read = {future = future, response = response}
    end
    -- apply_edit_mode asks governance to change or report this workspace's
    -- edit mode and shows its answer.
    local function apply_edit_mode(operation: string, input: string?): boolean
        if not launch then status = "Edit mode needs a bee.app launch"; dirty = true; return false end
        local request: {[string]: unknown} = {operation = operation, workspace_id = launch.workspace_id}
        if input then request.input = input end
        local raw, call_error = funcs.new():call(SUPER_EDIT, request)
        dirty = true
        if call_error then status = "Edit mode failed: " .. tostring(call_error); return false end
        local reply = type(raw) == "table" and raw or nil
        if not reply or reply.ok ~= true then
            status = "Edit mode refused: " .. tostring(reply and (reply.message or reply.code) or "invalid reply")
            return false
        end
        local value = type(reply.value) == "table" and reply.value or nil
        status = value and type(value.message) == "string" and value.message or "Edit mode updated"
        return true
    end
    -- ask_edit_mode puts an edit-mode question to the person.
    local function ask_edit_mode(kind: "text" | "confirm", operation: string, initial: string?)
        if not launch then status = "Edit mode needs a bee.app launch"; dirty = true; return end
        if edit_query ~= "" then status = "Finish the current edit-mode question first"; dirty = true; return end
        if kind == "confirm" and initial then edit_input = initial end
        local title = kind == "text" and "Enable edit mode" or (operation == "enable_confirm" and "Confirm edit mode" or "Disable edit mode")
        local message = kind == "text" and "Enter exact namespaces followed by --for DURATION (maximum 24h)."
            or view.confirm_message(edit_input, operation ~= "enable_confirm")
        local accept = kind == "text" and "Review" or (operation == "enable_confirm" and "Enable" or "Disable")
        local request_id, query_error = app.query(launch, {kind = kind, title = title, message = message, accept = accept,
            initial = kind == "text" and (initial or "") or ""})
        if not request_id then status = tostring(query_error or "Could not ask the person"); dirty = true; return end
        edit_query, edit_operation = request_id, operation
        if kind == "text" then edit_input = "" end
        status = kind == "text" and "Waiting for the namespace list" or "Waiting for confirmation"
        dirty = true
    end
    local function switch(next_pane: view.Pane)
        pane = next_pane; offset = 0; reveal(); dirty = true
        if pane == "about" and not live_status then request_live_updates(false) end
        if pane == "edit_mode" then apply_edit_mode("status", nil) end
    end

    run(function(): Result
        local value, err = client.call(node, "themes", {})
        if not value then return {kind = "failed", themes = nil, problem = err} end
        local decoded: {appearance.Theme} = {}
        if type(value.themes) == "table" then
            for _, item in ipairs(value.themes) do
                local theme = appearance.decode_theme(item)
                if theme then decoded[#decoded + 1] = theme end
            end
        end
        return {kind = "themes", themes = decoded, problem = nil}
    end)
    while running do
        if dirty then
            local drawn = view.draw(math.floor(width), math.floor(height), preferences, themes, pane, offset, status, live_status, live_pending, build)
            frame.render(drawn, menu, preferences)
            hits = drawn.hits
            assert(output:present(drawn.rows, {cursor = {x = 1, y = 1, visible = false}}))
            dirty = false
        end
        local cases = {input:case_receive(), lifecycle:case_receive(), changes:case_receive(), results:case_receive(), commits:case_receive(),
            answers:case_receive()}
        if update_read then cases[#cases + 1] = update_read.response:case_receive() end
        local event = channel.select(cases)
        if not event.ok then break end
        if event.channel == lifecycle then
            if event.value.kind == process.event.CANCEL then running = false end
        elseif event.channel == commits then
            if pane == "about" or update_read then request_live_updates(true) else live_status = nil end
        elseif update_read and event.channel == update_read.response then
            local current = update_read
            local result, result_error = current.future:result()
            update_read = nil
            live_pending = false
            if result_error or not result then live_status = live_updates.failure(tostring(result_error or "Hub status call returned no reply"))
            else live_status = live_updates.decode(result:data()) end
            reveal()
            dirty = true
            if refresh_again then refresh_again = false; request_live_updates(false) end
        elseif event.channel == answers then
            local answer = launch and app.query_result(launch, tostring(event.value:from()), event.value:payload():data()) or nil
            if answer and answer.request_id == edit_query then
                local operation = edit_operation
                edit_query, edit_operation = "", ""
                if answer.error ~= "" then status = "Another question is open; try again"
                elseif answer.action ~= "accept" then status = "Edit mode unchanged"; edit_input = ""
                elseif operation == "enable_input" then
                    if answer.value == "" then status = "Enter at least one namespace and a duration"
                    else ask_edit_mode("confirm", "enable_confirm", answer.value) end
                elseif operation == "enable_confirm" then
                    if apply_edit_mode("enable", edit_input) then edit_input = "" end
                elseif operation == "disable_confirm" then
                    edit_input = ""
                    apply_edit_mode("disable", nil)
                end
                dirty = true
            end
        elseif event.channel == changes then
            choice.announced(chosen, appearance.chosen(event.value:payload():data()))
            preferences = choice.shown(chosen)
            reveal(); dirty = true
        elseif event.channel == results then
            local result = event.value :: Result
            if result.kind == "themes" and result.themes then themes = result.themes; status = ""; reveal()
            elseif result.kind == "failed" and result.sequence then
                choice.settled(chosen, result.sequence, false)
                preferences = choice.shown(chosen)
                status = "Not applied: " .. tostring(result.problem)
            elseif result.kind == "failed" then status = "Themes unavailable: " .. tostring(result.problem)
            elseif result.sequence then
                choice.settled(chosen, result.sequence, true)
                preferences = choice.shown(chosen)
                status = ""
            end
            dirty = true
        else
            local data, handled = frame.route(menu, event.value, false)
            if handled then dirty = true end
            if data then
                if data.type == "close" then running = false
                elseif data.type == "resize" then
                    width, height = data.width, data.height
                    reveal(); dirty = true
                elseif data.type == "key" and data.action ~= "release" then
                    local key = data.key_type
                    local grid = view.grid(math.floor(width), math.floor(height))
                    if pane == "edit_mode" and key == "runes" and not data.ctrl and not data.alt and (data.key == "e" or data.key == "E") then
                        ask_edit_mode("text", "enable_input", nil)
                    elseif pane == "edit_mode" and key == "runes" and not data.ctrl and not data.alt and (data.key == "d" or data.key == "D") then
                        ask_edit_mode("confirm", "disable_confirm", nil)
                    elseif pane == "edit_mode" and key ~= "tab" then
                        -- Edit mode has no cards to choose or page.
                    elseif pane == "about" and key == "runes" and data.key == "r" and not data.ctrl and not data.alt then request_live_updates(true)
                    elseif pane == "about" and (key == "up" or key == "down") then browse(key == "up" and -1 or 1)
                    elseif pane == "about" and (key == "pgup" or key == "pgdown") then
                        browse((key == "pgup" and -1 or 1) * math.floor(math.max(1, height - 5)))
                    elseif key == "left" then choose(selected() - 1)
                    elseif key == "right" then choose(selected() + 1)
                    elseif key == "up" then choose(selected() - grid.columns)
                    elseif key == "down" then choose(selected() + grid.columns)
                    elseif key == "home" then choose(1)
                    elseif key == "end" then choose(count())
                    elseif key == "pgup" then browse(-grid.capacity)
                    elseif key == "pgdown" then browse(grid.capacity)
                    elseif key == "tab" then switch(pane == "theme" and "background" or (pane == "background" and "taskbar"
                        or (pane == "taskbar" and "edit_mode" or (pane == "edit_mode" and "about" or "theme"))))
                    end
                elseif data.type == "mouse" then
                    local x, y = math.floor(tonumber(data.x) or 1), math.floor(tonumber(data.y) or 1)
                    if data.action == "wheel" and y >= 4 and y < height - 2 then
                        local step = pane == "about" and 1 or view.grid(math.floor(width), math.floor(height)).columns
                        browse((data.button == "wheel_up" or data.button == "up") and -step or step)
                    elseif data.action == "press" and data.button == "left" then
                        local hit = frame.hit(hits, x, y)
                        if hit then
                            if hit.kind == "theme" then switch("theme")
                            elseif hit.kind == "background" then switch("background")
                            elseif hit.kind == "taskbar" then switch("taskbar")
                            elseif hit.kind == "edit_mode" then switch("edit_mode")
                            elseif hit.kind == "about" then switch("about")
                            elseif hit.kind == "check" then request_live_updates(true)
                            elseif hit.kind == "select" then choose(hit.index)
                            elseif hit.kind == "step" then choose(selected() + hit.index)
                            elseif hit.kind == "page" then browse(hit.index * view.grid(math.floor(width), math.floor(height)).capacity) end
                        end
                    end
                end
            end
        end
    end
    if update_read then update_read.future:cancel() end
    process.unlisten(answers)
    registry_changes:close()
    output:close()
    tty.stop()
end
return {main = main}
