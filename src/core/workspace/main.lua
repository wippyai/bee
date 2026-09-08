-- Stable local lifetime and physical terminal adapter. The replaceable
-- presenter receives a virtual terminal, never the physical output lease.
local tty = require("tty")
local security = require("security")
local process = require("process")
local channel = require("channel")
local time = require("time")
local uuid = require("uuid")
local model = require("model")
local decode = require("decode")
local decode_input = require("decode_input")
local appearance = require("appearance")
local physical = require("physical")
local persistence = require("persistence")
local recovery = require("recovery")
local interaction = require("interaction")
local contract = require("contract")
local command = require("command")

local arguments = require("arguments")
local function main(initial_application: string?, secondary_application: string?, initial_arguments: {string}?, initial_fullscreen: boolean?)
    local input = assert(tty.events())
    local lifecycle = assert(process.events())
    local control = assert(process.listen("bee.workspace.control", {message = true}))
    local commands = assert(process.listen("bee.desktop.command", {message = true}))
    local requests = assert(process.listen("bee.app.request", {message = true}))
    local ready = assert(process.listen("bee.app.ready", {message = true}))
    local replies = assert(process.listen("bee.app.reply", {message = true}))
    local scenes = assert(process.listen("bee.desktop.scene", {message = true}))
    local acknowledgements = assert(process.listen("bee.desktop.ack", {message = true}))
    local dialog_states = assert(process.listen("bee.interaction.state", {message = true}))
    local dialog_answers = assert(process.listen("bee.interaction.response", {message = true}))
    local dialog_items: {interaction.Wire} = {}
    local shutdown_dialog: interaction.Wire? = nil
    local catalogs = assert(process.listen("bee.application.catalog", {message = true}))
    local appearance_pending: {[string]: boolean} = {}
    local catalog_items: {decode.CatalogItem} = {}
    local checkpoints = assert(process.listen("bee.application.checkpoint", {message = true}))
    local appearance_requests = assert(process.listen("bee.appearance.request", {message = true}))
    local display = physical.open()
    local width, height = display.width, display.height
    local database, database_error = persistence.open()
    if not database then error(tostring(database_error)) end
    local workspace_id = database.workspace_id
    local saved = database.saved
    local preferences = saved and saved.desktop.preferences or appearance.defaults()
    local records: {[string]: recovery.Record} = {}
    local restore_queue: {recovery.Record} = {}
    local record_order: {string} = {}
    if saved then
        for _, record in ipairs(saved.applications) do
            records[record.id] = record; record_order[#record_order + 1] = record.id
            if record.restart_policy == "automatic" then restore_queue[#restore_queue + 1] = record end
        end
    end
    local restore_request = ""
    local restore_focus = saved and saved.desktop.scene.focus or ""
    local owner = tostring(process.pid())
    local session_policy, session_error = security.policy("bee:session_policy")
    if session_error then error(tostring(session_error)) end
    local broker_policy, broker_error = security.policy("bee:broker_policy")
    if broker_error then error(tostring(broker_error)) end
    local presenter_policy, presenter_error = security.policy("bee:presenter_policy")
    if presenter_error then error(tostring(presenter_error)) end
    local session_scope = security.new_scope({session_policy})
    local private_core, private_core_error = security.policy("bee:core_spawn_boundary")
    if private_core_error then error(tostring(private_core_error)) end
    local broker_scope = security.new_scope({broker_policy, private_core})
    local presenter_scope = security.new_scope({presenter_policy})
    local session = tostring(assert(process.with_options({}):with_context({["bee.workspace_owner"] = owner, ["bee.workspace_id"] = workspace_id}):with_scope(session_scope)
        :spawn_monitored("bee.session:main", "bee:workers", owner, width, height, preferences)))
    local broker = tostring(assert(process.with_options({}):with_context({["bee.workspace_owner"] = owner, ["bee.workspace_id"] = workspace_id}):with_scope(broker_scope)
        :spawn_monitored("bee.applications:broker", "bee:workers", owner, preferences)))
    local scene = model.new(width, height)
    local tabs: {string} = {}
    local updates = assert(display.view:updates())
    local presenter = ""
    local active, presenter_ready, broker_ready = false, false, false
    local presented = false
    local paused = false
    local initial_opened, quitting = false, false
    local initial_request = ""
    local shutdown_request = ""
    local requested_rejoin = false
    local binding = ""
    local fatal: string? = nil
    local deadline_ticks, recoveries = 0, 0
    local ticker = assert(time.ticker("100ms"))
    local ticks = ticker:channel()

    -- A lost core command cannot be reconstructed like a presenter snapshot.
    -- End this local owner through its save path instead of awaiting an impossible
    -- reply. A failed send is never retried as a second side-effecting operation.
    local function send_control(recipient: string, topic: string, value: unknown): boolean
        local sent, err = process.send(recipient, topic, value)
        if not sent then
            local request = ""
            if type(value) == "table" and type(value.request_id) == "string"
                and #value.request_id <= 80 and not value.request_id:find("%c") then
                request = " [" .. value.request_id .. "]"
            end
            if not fatal then fatal = "Core delivery failed: " .. topic .. request .. ": " .. tostring(err) end
            quitting = true
        end
        return sent == true
    end

    local function application_request(value: unknown): boolean
        local request = contract.request(value)
        if not request then return false end
        if request.workspace_id ~= workspace_id then
            local reply = contract.reply(request.request_id, request.op, "workspace_mismatch", "Request targets another workspace")
            reply.id, reply.workspace_id = request.id, workspace_id
            process.send(presenter, "bee.app.reply", reply)
            return false
        end
        local sent, err = process.send(broker, "bee.app.request", value)
        if not sent then
            local reply = contract.reply(request.request_id, request.op, "delivery_failed", tostring(err))
            reply.id, reply.workspace_id = request.id, workspace_id
            process.send(presenter, "bee.app.reply", reply)
        end
        return sent == true
    end
    local function prepare_quit()
        local sent, err = process.send(broker, "bee.application.shutdown", {version = 1, op = "prepare"})
        if not sent then
            local reply = contract.reply("", "quit", "delivery_failed", tostring(err))
            reply.workspace_id = workspace_id
            process.send(presenter, "bee.app.reply", reply)
        end
    end

    local function broker_request(op: string, definition_id: string, id: string, recipient: string, launch_arguments: {string}?)
        local request_id = uuid.v7()
        local restored: recovery.Record? = nil
        if op == "open" and (not launch_arguments or #launch_arguments == 0) then
            for _, saved_id in ipairs(record_order) do
                local record = records[saved_id]
                if record and record.definition_id == definition_id then
                    local live = false
                    for _, window in ipairs(scene.windows) do if window.id == saved_id then live = true end end
                    if not live then restored = record; break end
                end
            end
        end
        local request = {version = 1, request_id = request_id, op = op, workspace_id = workspace_id,
            definition_id = definition_id, id = id, recipient = recipient,
            restore_instance_id = restored and restored.instance_id or "", restore_view_id = restored and restored.id or "",
            resume_schema = restored and restored.resume_schema or "", resume_state = restored and restored.resume_state or "",
            arguments = op == "open" and launch_arguments or nil}
        if op == "open" then application_request(request)
        else send_control(broker, "bee.app.request", request) end
        return request_id
    end
    local function persist(): (boolean, string?)
        local applications: {recovery.Record} = {}
        for _, id in ipairs(record_order) do
            local record = records[id]
            if record then applications[#applications + 1] = record end
        end
        local persisted_scene, persisted_tabs = scene, tabs
        -- Bootstrap and sequential restoration have an incomplete projection.
        -- Keep the saved desktop until restoration finishes, including on failure.
        if saved and (not initial_opened or restore_request ~= "" or #restore_queue > 0) then
            persisted_scene, persisted_tabs = saved.desktop.scene, saved.desktop.tabs
        end
        return database:write({version = 1, desktop = {scene = persisted_scene, tabs = persisted_tabs,
            preferences = preferences}, applications = applications})
    end
    local function restore_next()
        local record = table.remove(restore_queue, 1)
        if record then
            restore_request = uuid.v7()
            send_control(broker, "bee.app.request", {version = 1, request_id = restore_request, op = "open", workspace_id = workspace_id,
                definition_id = record.definition_id, restore_instance_id = record.instance_id, restore_view_id = record.id,
                resume_schema = record.resume_schema, resume_state = record.resume_state})
        else
            restore_request = ""
            if restore_focus ~= "" then
                send_control(session, "bee.desktop.command", {version = 1, op = "focus", id = restore_focus})
                restore_focus = ""
            end
            if initial_application and initial_application ~= "" then initial_request = broker_request("open", initial_application, "", "", initial_arguments) end
        end
    end
    local function restore_window(record: recovery.Record)
        local window = record.window
        if not window then return end
        send_control(session, "bee.desktop.command", {version = 1, op = "personalize", id = record.id,
            user_title = window.user_title or "", accent = window.accent or ""})
        local rect = window.normal_bounds
        send_control(session, "bee.desktop.command", {version = 1, op = "place", id = record.id,
            x = rect.x, y = rect.y, width = rect.width, height = rect.height})
        local mode = window.mode == "minimized" and window.restore_mode or window.mode
        if mode == "fullscreen" or mode == "collapsed" then
            send_control(session, "bee.desktop.command", {version = 1, op = mode == "fullscreen" and "fullscreen" or "collapse", id = record.id})
        end
        if window.mode == "minimized" then send_control(session, "bee.desktop.command", {version = 1, op = "minimize", id = record.id}) end
    end
    local function send_dialogs()
        if active then process.send(presenter, "bee.interaction.state", {version = 1, items = dialog_items, shutdown = shutdown_dialog}) end
    end
    local function send_scene()
        send_dialogs()
        if active then process.send(presenter, "bee.desktop.scene", {scene = scene, tabs = tabs, preferences = preferences, catalog = catalog_items}) end
    end
    local function send_appearance_state(request_id: string?, code: string?, message: string?)
        if broker_ready then
            send_control(broker, "bee.appearance.state", {version = 1, request_id = request_id or "", revision = scene.revision,
                theme = preferences.theme, background = preferences.background, taskbar = preferences.taskbar, error_code = code or "", error = message or ""})
        end
    end
    local function spawn_presenter()
        local grant = assert(display.view:grant())
        presenter = tostring(assert(process.with_options({terminal = grant}):with_context({["bee.workspace_owner"] = owner, ["bee.workspace_id"] = workspace_id}):with_scope(presenter_scope)
            :spawn_monitored("bee.terminal:main", "bee:workers", owner, initial_application, secondary_application)))
        active, presenter_ready = false, false
        paused = false
        binding = ""
        presented = false
        deadline_ticks = 0
    end
    local function recovery_screen()
        physical.paused(display)
    end
    local function pause_presenter()
        active, paused, presenter_ready = false, true, false
        binding = ""
        broker_request("bind", "", "", "")
        local retiring = presenter
        presenter = "" -- Fence all late messages, including a timed-out process.
        if retiring ~= "" then process.terminate(retiring) end
        recovery_screen()
    end
    local function replace_presenter()
        physical.replace(display)
        updates = assert(display.view:updates())
        spawn_presenter()
    end
    local function bind_presenter()
        if broker_ready and presenter_ready then
            binding = broker_request("bind", "", "", presenter)
        end
    end
    spawn_presenter()
    while not quitting do
        local selected = channel.select({input:case_receive(), lifecycle:case_receive(), control:case_receive(),
            commands:case_receive(), requests:case_receive(), dialog_states:case_receive(), dialog_answers:case_receive(), appearance_requests:case_receive(), ready:case_receive(), catalogs:case_receive(), replies:case_receive(),
            scenes:case_receive(), checkpoints:case_receive(), acknowledgements:case_receive(), updates:case_receive(), ticks:case_receive()})
        if not selected.ok then break end
        if selected.channel == lifecycle then
            local event = selected.value
            if event.kind == process.event.CANCEL then break end
            if event.kind == process.event.EXIT then
                local exited = tostring(event.from)
                if exited == session or exited == broker then fatal = "Workspace service exited"; break end
                if exited == presenter then
                    active = false
                    if not requested_rejoin then recoveries = recoveries + 1 end
                    requested_rejoin = false
                    if recoveries > 3 then pause_presenter()
                    else replace_presenter() end
                end
            end
        elseif selected.channel == dialog_states and selected.value:from() == broker then
            local payload: unknown = selected.value:payload():data()
            local items = interaction.snapshot(payload)
            local global = interaction.shutdown(payload)
            if items and type(payload) == "table" and (payload.shutdown == nil or global) then
                shutdown_dialog = global and interaction.wire(global) or nil
                dialog_items = {}
                for _, spec in ipairs(items) do dialog_items[#dialog_items + 1] = interaction.wire(spec) end
                send_dialogs()
            end
        elseif selected.channel == dialog_answers and selected.value:from() == presenter and active then
            local response = interaction.response(selected.value:payload():data())
            if response then
                send_control(broker, "bee.interaction.response", {version = 1, request_id = response.request_id,
                    id = response.id, instance_id = response.instance_id, action = response.action, value = response.value})
            end
        elseif selected.channel == control then
            local msg = selected.value
            if msg:from() == presenter and shutdown_request == "" then
                local data: unknown = msg:payload():data()
                if type(data) == "table" then
                    if data.op == "ready" and not presenter_ready then
                        presenter_ready = true; bind_presenter()
                    elseif data.op == "quit" and active then prepare_quit()
                    elseif data.op == "rejoin" and active then
                        requested_rejoin = true
                        active = false
                        broker_request("bind", "", "", "")
                        process.send(presenter, "bee.workspace.retire", {})
                        -- The presenter closes only its own attachments and exits.
                        -- EXIT is the fence before a fresh producer is spawned.
                    end
                end
            end
        elseif selected.channel == ready then
            if selected.value:from() == broker then broker_ready = true; bind_presenter() end
        elseif selected.channel == requests then
            if selected.value:from() == presenter and active and shutdown_request == "" then
                local data: unknown = selected.value:payload():data()
                if type(data) == "table" and (data.op == "open" or data.op == "close") then
                    if data.op == "open" then
                        for _, id in ipairs(record_order) do
                            local record = records[id]
                            if record and record.definition_id == data.definition_id then
                                local live = false
                                for _, window in ipairs(scene.windows) do if window.id == id then live = true end end
                                if not live then
                                    data.restore_instance_id, data.restore_view_id = record.instance_id, record.id
                                    data.resume_schema, data.resume_state = record.resume_schema, record.resume_state
                                    break
                                end
                            end
                        end
                    end
                    application_request(data)
                end
            end
        elseif selected.channel == catalogs then
            if selected.value:from() == broker then
                local data: unknown = selected.value:payload():data()
                if type(data) == "table" and data.version == 1 then
                    local items = decode.catalog(data.items)
                    if items then catalog_items = items; send_scene() end
                end
            end
        elseif selected.channel == appearance_requests then
            if selected.value:from() == broker then
                local data: unknown = selected.value:payload():data()
                if type(data) == "table" and data.version == 1 and type(data.request_id) == "string" then
                    appearance_pending[data.request_id] = true
                    local sent, err = process.send(session, "bee.desktop.command", data)
                    if not sent then
                        appearance_pending[data.request_id] = nil
                        send_appearance_state(data.request_id, "unavailable", tostring(err))
                    end
                end
            end
        elseif selected.channel == commands then
            if selected.value:from() == presenter and active and shutdown_request == "" then
                local data: unknown = selected.value:payload():data()
                -- Application lifecycle alone creates/removes logical windows.
                if type(data) == "table" and (data.op == "focus" or data.op == "place" or data.op == "fullscreen"
                    or data.op == "minimize" or data.op == "collapse" or data.op == "restore" or data.op == "snap" or data.op == "personalize") then
                    send_control(session, "bee.desktop.command", data)
                end
            end
        elseif selected.channel == replies then
            if selected.value:from() == broker then
                local reply = decode.reply(selected.value:payload():data())
                if reply and decode.belongs(reply, workspace_id) then
                    if reply.op == "quit" and reply.error == "" and shutdown_request == "" then
                        -- Keep the store and event loop alive through cooperative app cleanup.
                        shutdown_request = broker_request("shutdown", "", "", "")
                    elseif reply.op == "shutdown" and reply.request_id == shutdown_request then
                        if reply.error ~= "" then fatal = reply.error end
                        quitting = true
                    elseif reply.op == "bind" and reply.request_id == binding then
                        if reply.error_code ~= "" then
                            pause_presenter()
                        else
                        active = true
                        send_appearance_state()
                        send_control(session, "bee.desktop.command", {version = 1, op = "snapshot"})
                        if not initial_opened then
                            initial_opened = true
                            restore_next()
                        end
                        end
                    elseif reply.op == "title" and reply.error == "" then
                        send_control(session, "bee.desktop.command", {version = 1, op = "announce", id = reply.id,
                            instance_id = reply.instance_id, title = reply.title})
                    elseif reply.op == "page" then send_scene()
                    elseif reply.op == "open" and reply.error == "" then
                        send_control(session, "bee.desktop.command", {version = 1, op = "add", id = reply.id,
                            instance_id = reply.instance_id, workspace_id = workspace_id, title = reply.title, icon = reply.icon})
                        local record = records[reply.id]
                        if record then restore_window(record) end
                    elseif reply.op == "focus" and reply.error == "" then
                        send_control(session, "bee.desktop.command", {version = 1, op = "focus", id = reply.id})
                        send_appearance_state()
                    elseif (reply.op == "close" and reply.error == "") or reply.op == "closed" then
                        records[reply.id] = nil
                        for index = #record_order, 1, -1 do if record_order[index] == reply.id then table.remove(record_order, index) end end
                        send_control(session, "bee.desktop.command", {version = 1, op = "remove", id = reply.id})
                    end
                    if reply.request_id == restore_request and reply.op == "open" and not quitting then restore_next() end
                    if initial_fullscreen and reply.request_id == initial_request and reply.error == ""
                        and (reply.op == "open" or reply.op == "focus") then
                        send_control(session, "bee.desktop.command", {version = 1, op = "maximize", id = reply.id})
                        initial_request = ""
                    end
                    if reply.op == "attached" then
                        if reply.request_id == binding or (active and reply.error_code == "attachment_failed") then
                            process.send(presenter, "bee.app.reply", reply)
                        end
                    elseif reply.op ~= "bind" and active then process.send(presenter, "bee.app.reply", reply) end
                end
            end
        elseif selected.channel == checkpoints and selected.value:from() == broker then
            local data: unknown = selected.value:payload():data()
            local record = recovery.record(data)
            if type(data) ~= "table" or data.workspace_id ~= workspace_id then record = nil end
            if type(data) == "table" and data.version == 1 and type(data.request_id) == "string" then
                local ok, err = false, "Invalid checkpoint"
                if record then
                    local previous = records[record.id]
                    if previous then record.window = previous.window end
                    for _, window in ipairs(scene.windows) do if window.id == record.id then record.window = window end end
                    if not previous then record_order[#record_order + 1] = record.id end
                    records[record.id] = record
                    ok, err = persist()
                    if not ok then
                        records[record.id] = previous
                        if not previous then table.remove(record_order) end
                    end
                end
                send_control(broker, "bee.application.persisted", {version = 1, request_id = data.request_id,
                    error_code = ok and "" or "persistence_failed", error = err or ""})
            end
        elseif selected.channel == acknowledgements then
            if selected.value:from() == session then
                local ack = decode.ack(selected.value:payload():data())
                if ack then
                    if ack.preferences and ack.tabs and ack.scene.revision >= scene.revision then
                        scene, tabs, preferences = ack.scene, ack.tabs, ack.preferences
                    end
                    if appearance_pending[ack.request_id] then
                        appearance_pending[ack.request_id] = nil
                        send_appearance_state(ack.request_id, ack.error_code, ack.error)
                    end
                    if active then process.send(presenter, "bee.desktop.ack", ack) end
                end
            end
        elseif selected.channel == scenes then
            if selected.value:from() == session then
                local envelope = decode.desktop(selected.value:payload():data())
                if envelope and envelope.scene.revision >= scene.revision then
                    local changed = preferences.theme ~= envelope.preferences.theme or preferences.background ~= envelope.preferences.background or preferences.taskbar ~= envelope.preferences.taskbar
                    scene, tabs, preferences = envelope.scene, envelope.tabs, envelope.preferences
                    local ordered: {string} = {}
                    local included: {[string]: boolean} = {}
                    for _, id in ipairs(tabs) do
                        if records[id] then ordered[#ordered + 1] = id; included[id] = true end
                    end
                    for _, id in ipairs(record_order) do
                        if records[id] and not included[id] then ordered[#ordered + 1] = id end
                    end
                    record_order = ordered
                    for _, window in ipairs(scene.windows) do
                        local record = records[window.id]
                        if record then record.window = window end
                    end
                    local committed, commit_error = persist()
                    if not committed then fatal = "Workspace save failed: " .. tostring(commit_error); break end
                    if changed then send_appearance_state() end
                    send_scene()
                end
            end
        elseif selected.channel == updates then
            if active and physical.present(display) then
                presented = true
                deadline_ticks = 0
            end
        elseif selected.channel == ticks then
            if not paused and (not active or not presented) then
                deadline_ticks = deadline_ticks + 1
                if deadline_ticks >= 50 then pause_presenter() end
            end
        elseif selected.channel == input then
            local event = decode_input.decode(selected.value)
            if event and shutdown_request == "" then
                if event.type == "close" then break end
                local quit_key = event.type == "key" and event.ctrl and event.key == "q" and event.action ~= "release"
                if quit_key then
                    if paused or not broker_ready then break end
                    prepare_quit()
                end
                if paused and event.type == "key" and event.key_type == "f12" and event.action ~= "release" then
                    recoveries = 0
                    replace_presenter()
                end
                if event.type == "resize" then
                    width, height = event.width, event.height
                    physical.resize(display, width, height)
                    send_control(session, "bee.desktop.command", {version = 1, op = "screen", width = width, height = height})
                    if paused then recovery_screen() end
                elseif active and not quit_key then
                    display.view:send(event)
                end
            end
        end
    end
    ticker:stop()
    local saved_ok, save_error = persist()
    if not saved_ok then fatal = "Workspace save failed: " .. tostring(save_error) end
    database:close()
    if shutdown_request == "" then broker_request("shutdown", "", "", "") end
    send_control(session, "bee.desktop.command", {version = 1, op = "shutdown"})
    if presenter ~= "" then process.terminate(presenter) end
    process.unlisten(appearance_requests)
    process.unlisten(dialog_states); process.unlisten(dialog_answers)
    process.unlisten(catalogs)
    process.unlisten(checkpoints)
    physical.close(display)
    if fatal then error(fatal) end
end
local function launch(application: string, ...)
    local values: unknown = {...}
    local decoded = arguments.decode(values)
    if not decoded then error("Invalid application arguments") end
    return main(application, nil, decoded)
end
local function entry(application: string?, ...)
    local decoded = arguments.decode({...})
    if not decoded then error("Invalid application arguments") end
    if not application or application == "" then return main() end
    -- Preserve the existing explicit-ID desktop invocation and bee-app contract.
    if application:find(":", 1, true) then
        if #decoded > 1 then error("Use bee-app for explicit application arguments") end
        return main(application, decoded[1])
    end
    local selected, err = command.resolve(application, decoded)
    if not selected then error(err or "Command resolution failed") end
    return main(selected.definition_id, nil, selected.arguments, selected.fullscreen)
end
return {main = entry, launch = launch}
