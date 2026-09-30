-- A standalone application: the controlling display owns preferences; view owns geometry.
local tty = require("tty")
local client = require("client")
local channel = require("channel")
local process = require("process")
local uuid = require("uuid")
local time = require("time")
local json = require("json")
local funcs = require("funcs")
local appearance = require("appearance")
local frame = require("frame")
local view = require("view")
local function main(value: unknown)
    local launch = client.launch(value)
    if not launch then error("Invalid application launch") end
    local broker = launch.broker_pid
    local announced = false
    local input = assert(tty.events())
    local menu = frame.menu()
    local lifecycle = assert(process.events())
    local states = assert(process.listen("bee.appearance.state", {message = true}))
    local queries = assert(process.listen("bee.application.query.result", {message = true}))
    assert(tty.start())
    local output = assert(tty.surface())
    local width, height = tty.screen_size()
    local preferences: appearance.Preferences = appearance.defaults()
    local confirmed: appearance.Preferences = preferences
    local status = ""
    local pending_timeout: time.Timer? = nil
    local pane: view.Pane = "theme"
    local offset = 0
    local last_checkpoint = ""
    if launch.resume_state ~= "" then
        local restored: unknown = json.decode(launch.resume_state)
        if type(restored) ~= "table" or (restored.pane ~= "theme" and restored.pane ~= "background" and restored.pane ~= "taskbar"
            and restored.pane ~= "edit_mode" and restored.pane ~= "about")
            or type(restored.offset) ~= "number" or restored.offset < 0 or restored.offset > 10000
            or restored.offset ~= math.floor(restored.offset) then error("Invalid Settings checkpoint") end
        pane = restored.pane; offset = math.floor(restored.offset)
    end
    local hits: {frame.Hit} = {}
    local pending = ""
    local edit_query = ""
    local edit_query_op = ""
    local edit_input = ""
    local running, dirty = true, true
    local function arm_pending_timeout()
        if pending_timeout then pending_timeout:stop() end
        pending_timeout = assert(time.timer("5s"))
    end
    local function count(): integer return pane == "taskbar" and 2 or (pane == "theme" and #appearance.themes() or (pane == "background" and #appearance.backgrounds() or (pane == "about" and view.about_count(width) or 0))) end
    local function selected(): integer
        if pane == "taskbar" then return preferences.taskbar == "icons" and 2 or 1 end
        if pane == "theme" then
            for index, theme in ipairs(appearance.themes()) do if theme.id == preferences.theme then return index end end
        else
            for index, background in ipairs(appearance.backgrounds()) do if background == preferences.background then return index end end
        end
        return 1
    end
    local function reveal()
        if pane == "about" then
            offset = math.floor(math.max(0, math.min(math.max(0, view.about_count(width) - math.max(0, height - 5)), offset)))
            return
        end
        offset = view.offset(selected(), offset, view.grid(width, height), count(), true)
    end
    local function choose(index: integer)
        if pane == "about" or pane == "edit_mode" then return end
        local value = math.floor(math.max(1, math.min(count(), index)))
        local next_preferences: appearance.Preferences
        if pane == "theme" then next_preferences = {theme = appearance.themes()[value].id, background = preferences.background, taskbar = preferences.taskbar}
        elseif pane == "background" then next_preferences = {theme = preferences.theme, background = appearance.backgrounds()[value], taskbar = preferences.taskbar}
        else next_preferences = {theme = preferences.theme, background = preferences.background, taskbar = value == 2 and "icons" or "labels"} end
        preferences = next_preferences
        pending = uuid.v7(); arm_pending_timeout(); status = ""
        if broker then
            local sent, err = process.send(broker, "bee.appearance.request", {version = 1, request_id = pending, op = "set", theme = preferences.theme, background = preferences.background, taskbar = preferences.taskbar})
            if not sent then
                pending = ""; preferences = confirmed; status = tostring(err)
                if pending_timeout then pending_timeout:stop(); pending_timeout = nil end
            end
        end
        reveal(); dirty = true
    end
    local function inherit()
        if not broker then return end
        pending = uuid.v7(); arm_pending_timeout(); status = ""
        local sent, err = process.send(broker, "bee.appearance.request", {version = 1, request_id = pending,
            op = "inherit", theme = preferences.theme, background = preferences.background, taskbar = preferences.taskbar})
        if not sent then
            pending = ""; status = tostring(err)
            if pending_timeout then pending_timeout:stop(); pending_timeout = nil end
        end
        dirty = true
    end
    local function browse(amount: integer)
        if pane == "about" then
            local capacity = math.max(0, height - 5)
            offset = math.floor(math.max(0, math.min(math.max(0, view.about_count(width) - capacity), offset + amount)))
            dirty = true
            return
        end
        local grid = view.grid(width, height)
        offset = view.offset(selected(), offset + amount, grid, count(), false)
        dirty = true
    end
    local function switch(next_pane: view.Pane)
        pane = next_pane; offset = 0; reveal(); dirty = true
    end
    local function query_edit_mode(kind: "text" | "confirm", operation: string, initial: string?)
        if edit_query ~= "" then status = "Finish the current edit-mode prompt first"; dirty = true; return end
        local title = kind == "text" and "Enable edit mode" or (operation == "enable_confirm" and "Confirm edit mode" or "Disable edit mode")
        local message = kind == "text"
            and "Enter exact namespaces followed by --for DURATION (maximum 24h)."
            or (operation == "enable_confirm" and ("Enable these exact namespaces and duration?\n" .. (initial or ""))
                or "Remove this workspace's super-edit profiles and active overlays?")
        local accept = kind == "text" and "Review" or (operation == "enable_confirm" and "Enable" or "Disable")
        local request_id, query_error = client.query(launch, {kind = kind, title = title, message = message,
            accept = accept, initial = kind == "text" and "" or ""})
        if not request_id then status = tostring(query_error or "Could not ask the person"); dirty = true; return end
        edit_query = request_id
        edit_query_op = operation
        edit_input = initial or ""
        status = kind == "text" and "Waiting for namespace list" or "Waiting for confirmation"
        dirty = true
    end
    local function apply_edit_mode(operation: "enable" | "disable", input: string?)
        local request: {[string]: unknown} = {operation = operation, workspace_id = launch.workspace_id}
        if input then request.input = input end
        local ok, result, call_error = pcall(function()
            local value, failure = funcs.new():call("bee.gov.binding:super_edit_call", request)
            return value, failure
        end)
        if not ok then status = "Edit mode failed: " .. tostring(result); dirty = true; return end
        if call_error then status = "Edit mode failed: " .. tostring(call_error); dirty = true; return end
        local reply = type(result) == "table" and result :: {[string]: unknown} or nil
        if not reply or reply.ok ~= true then
            status = "Edit mode refused: " .. tostring(reply and (reply.message or reply.code) or "invalid reply")
        else
            local value = type(reply.value) == "table" and reply.value :: {[string]: unknown} or nil
            status = value and type(value.message) == "string" and value.message or "Edit mode updated"
        end
        dirty = true
    end
    if broker then process.send(broker, "bee.appearance.request", {version = 1, request_id = uuid.v7(), op = "state"}) end
    while running do
        if dirty then
            local drawn = view.draw(width, height, preferences, pane, offset, status)
            frame.render(drawn, menu, preferences)
            hits = drawn.hits
            assert(output:present(drawn.rows, {cursor = {x = 1, y = 1, visible = false}}))
            if not announced then client.ready(launch); announced = true end
            local checkpoint = json.encode({pane = pane, offset = offset})
            if checkpoint ~= last_checkpoint then
                local sent = client.checkpoint(launch, checkpoint)
                if sent then last_checkpoint = checkpoint end
            end
            dirty = false
        end
        local cases = {input:case_receive(), lifecycle:case_receive(), states:case_receive(), queries:case_receive()}
        if pending_timeout then cases[#cases + 1] = pending_timeout:channel():case_receive() end
        local event = channel.select(cases)
        if not event.ok then break end
        if event.channel == lifecycle then
            if event.value.kind == process.event.CANCEL then running = false end
        elseif pending_timeout and event.channel == pending_timeout:channel() then
            pending_timeout = nil
            if pending ~= "" then pending = ""; preferences = confirmed; status = "Appearance update timed out"; dirty = true end
        elseif event.channel == states then
            local message = event.value
            if broker and message:from() == broker then
                local payload: unknown = message:payload():data()
                local next_preferences = appearance.decode(payload)
                if next_preferences and type(payload) == "table" and payload.version == 1 then
                    local error_code = type(payload.error_code) == "string" and payload.error_code or ""
                    if error_code == "" then confirmed = next_preferences end
                    -- An older acknowledgement must not undo a newer key/click.
                    if pending == "" or pending == payload.request_id then
                        preferences = confirmed
                        pending = ""
                        if pending_timeout then pending_timeout:stop(); pending_timeout = nil end
                        dirty = true
                        status = type(payload.error) == "string" and payload.error or ""
                    end
                end
            end
        elseif event.channel == queries then
            local message = event.value
            if broker and message:from() == broker then
                local answer = client.query_result(launch, tostring(message:from()), message:payload():data())
                if answer and answer.request_id == edit_query then
                    local operation = edit_query_op
                    local submitted = answer.value
                    edit_query, edit_query_op = "", ""
                    if answer.error ~= "" then status = "Edit mode prompt is busy"; edit_input = ""
                    elseif answer.action ~= "accept" then status = "Edit mode cancelled"; edit_input = ""
                    elseif operation == "enable_input" then
                        if submitted == "" then
                            status = "Enter at least one namespace and a duration"
                            edit_input = ""
                        else query_edit_mode("confirm", "enable_confirm", submitted) end
                    elseif operation == "enable_confirm" then
                        local namespaces = edit_input
                        edit_input = ""
                        apply_edit_mode("enable", namespaces)
                    elseif operation == "disable_confirm" then
                        edit_input = ""
                        apply_edit_mode("disable", nil)
                    else edit_input = "" end
                    dirty = true
                end
            end
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
                    local grid = view.grid(width, height)
                    if pane == "edit_mode" and key == "runes" and not data.ctrl and not data.alt
                        and (data.key == "e" or data.key == "E") then query_edit_mode("text", "enable_input", nil)
                    elseif pane == "edit_mode" and key == "runes" and not data.ctrl and not data.alt
                        and (data.key == "d" or data.key == "D") then query_edit_mode("confirm", "disable_confirm", nil)
                    elseif pane ~= "edit_mode" and key == "runes" and data.key == "d" and not data.ctrl and not data.alt then inherit()
                    elseif key == "left" then choose(selected() - 1)
                    elseif key == "right" then choose(selected() + 1)
                    elseif key == "up" then choose(selected() - grid.columns)
                    elseif key == "down" then choose(selected() + grid.columns)
                    elseif key == "home" then choose(1)
                    elseif key == "end" then choose(count())
                    elseif key == "pgup" then browse(-math.floor(pane == "about" and math.max(1, height - 5) or grid.capacity))
                    elseif key == "pgdown" then browse(math.floor(pane == "about" and math.max(1, height - 5) or grid.capacity))
                    elseif key == "tab" then switch(pane == "theme" and "background"
                        or (pane == "background" and "taskbar" or (pane == "taskbar" and "edit_mode"
                        or (pane == "edit_mode" and "about" or "theme"))))
                    elseif key == "esc" or key == "escape" then running = false end
                elseif data.type == "mouse" then
                    local x, y = math.floor(tonumber(data.x) or 1), math.floor(tonumber(data.y) or 1)
                    if data.action == "wheel" and y >= 4 and y < height - 2 then
                        local grid = view.grid(width, height)
                        local step = (data.button == "wheel_up" or data.button == "up") and -grid.columns or grid.columns
                        browse(step)
                    elseif data.action == "press" and data.button == "left" then
                        local hit = frame.hit(hits, x, y)
                        if hit then
                            if hit.kind == "inherit" then inherit()
                            elseif hit.kind == "theme" then switch("theme")
                            elseif hit.kind == "background" then switch("background")
                            elseif hit.kind == "taskbar" then switch("taskbar")
                            elseif hit.kind == "edit_mode" then switch("edit_mode")
                            elseif hit.kind == "about" then switch("about")
                            elseif hit.kind == "select" then choose(hit.index)
                            elseif hit.kind == "step" then choose(selected() + hit.index)
                            elseif hit.kind == "page" then browse(hit.index * view.grid(width, height).capacity) end
                        end
                    end
                end
            end
        end
    end
    if pending_timeout then pending_timeout:stop() end
    process.unlisten(states)
    process.unlisten(queries)
    output:close()
    tty.stop()
end
return {main = main}
