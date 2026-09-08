-- MIT. Independent desktop owner. The workspace host retains application lifetime.
local process = require("process")
local channel = require("channel")
local tty = require("tty")
local ctx = require("ctx")
local security = require("security")
local uuid = require("uuid")
local hash = require("hash")
local time = require("time")
local store = require("store")
local state = require("state")
local decode = require("decode")
local input_decode = require("input_decode")
local contract = require("contract")
local inventory = require("inventory")
local host_protocol = require("host_protocol")
local physical = require("physical")
local inbox = require("inbox")
local lifecycle = require("lifecycle")
local interaction = require("interaction")
type Channel = channel.Channel
type Binding = {generation: string, tab_id: string}
type AppearancePending = {request: host_protocol.ClientAppearanceRequest}

local function main(owner: string, host: string, workspace_id: string, database_resource: string, initial_application: string?, options: unknown)
    if owner == "" or ctx.get("bee.client_owner") ~= owner or not contract.workspace_id(workspace_id)
        or host == "" or host == owner then error("Untrusted client bootstrap") end
    local bootstrap = lifecycle.bootstrap(options)
    if not bootstrap then error("Invalid client bootstrap options") end
    local owned_database: store.Store? = nil
    local owned_display: physical.Display? = nil
    local presenter, session = "", ""
    local retired_presenter = ""
    local retired_view: tty.Viewport? = nil
    local subscriptions: {Channel<process.Message>} = {}
    local function listen(topic: string): Channel<process.Message>
        local subscription, err = process.listen(topic, {message = true})
        if not subscription then error(tostring(err)) end
        subscriptions[#subscriptions + 1] = subscription
        return subscription
    end
    local function boot()
        local events = assert(process.events())
        local input = assert(tty.events())
        local admissions = listen("bee.host.admitted")
        local presentations = listen("bee.host.presentation")
        local catalogs = listen("bee.host.catalog")
        local views = listen("bee.host.views")
        local replies = listen("bee.host.reply")
        local controls = listen("bee.workspace.control")
        local requests = listen("bee.app.request")
        local commands = listen("bee.desktop.command")
        local scenes = listen("bee.desktop.scene")
        local acknowledgements = listen("bee.desktop.ack")
        local question_states = listen("bee.host.questions")
        local question_results = listen("bee.host.question_result")
        local answers = listen("bee.interaction.response")
        local appearance_requests = listen("bee.client.appearance.request")
        local supervisor_controls = listen("bee.client.control")
        assert(process.monitor(owner)); assert(process.monitor(host))
        local database, database_error = store.open(database_resource)
        if not database then error(tostring(database_error)) end
        owned_database = database
        local import_receipt = ""
        if bootstrap.legacy_desktop ~= nil then
            local receipt, import_error = store.import_legacy(database, workspace_id, bootstrap.legacy_desktop)
            if not receipt then error(tostring(import_error)) end
            import_receipt = receipt
        end
        local saved, read_error = store.read(database)
        if read_error then error(read_error) end
        local display: physical.Display = physical.open()
        owned_display = display
        local layout = saved or state.empty(display.width, display.height)
        for _, target in ipairs(layout.targets) do
            if target.workspace_id ~= workspace_id then error("This client bootstrap requires one workspace") end
        end
        local targets: {[string]: state.Target} = {}
        local retired: {[string]: string} = {}
        local removals: {[string]: string} = {}
        local pending: {[string]: {op: string, tab_id: string}} = {}
        local pending_count = 0
        local appearance_pending: {[string]: AppearancePending} = {}
        for _, target in ipairs(layout.targets) do targets[target.tab_id] = target end
        local catalog: {contract.Descriptor} = {}
        local live: {inventory.View} = {}
        local catalog_revision, views_revision = -1, -1
        local connection_id, renderer_generation = "", ""
        local bindings: {[string]: Binding} = {}
        local active = false
        local inbox_state: inbox.State? = nil
        local shutdown_question: interaction.Wire? = nil
        local shutdown_answered = ""
        local quit_request = ""
        local saved_for_exit = false
        local initial_opened = false
        local initial_request = ""
        local self = tostring(process.pid())
        local function send(recipient: string, topic: string, value: unknown)
            assert(process.send(recipient, topic, value))
        end
        local function scope(name: string): security.Scope
            local policy, err = security.policy(name)
            if not policy then error(tostring(err)) end
            return security.new_scope({policy})
        end
        session = tostring(assert(process.with_options({}):with_context({["bee.workspace_owner"] = self,
            ["bee.workspace_id"] = workspace_id}):with_scope(scope("bee:session_policy")):spawn_monitored(
                "bee.session:main", "bee:workers", self, display.width, display.height, layout.preferences,
                {scene = layout.scene, tabs = layout.tabs, preferences = layout.preferences})))
        local function tab(view_id: string, instance_id: string): string?
            for key, target in pairs(targets) do
                if target.view_id == view_id and target.instance_id == instance_id then return key end
            end
            return nil
        end
        local function publish()
            if active then send(presenter, "bee.desktop.scene", {scene = layout.scene, tabs = layout.tabs,
                preferences = layout.preferences, catalog = catalog}) end
        end
        local function publish_questions()
            if active and inbox_state then
                send(presenter, "bee.interaction.state", {version = 1, items = inbox_state.items, shutdown = shutdown_question})
            end
        end
        local function select_targets()
            if inbox_state and inbox.select(inbox_state, layout.targets) then
                publish_questions()
                send(host, "bee.host.selection", inbox.selection(inbox_state))
            end
        end
        local function adopt(value: unknown)
            local next_layout, projection_error = state.project(layout, value, targets)
            if projection_error then error(projection_error) end
            if not next_layout then return end
            if next_layout.scene.revision == layout.scene.revision
                and next_layout.scene.focus == layout.scene.focus
                and #next_layout.scene.windows == #layout.scene.windows
                and #next_layout.tabs == #layout.tabs
                and next_layout.preferences.theme == layout.preferences.theme
                and next_layout.preferences.background == layout.preferences.background
                and next_layout.preferences.taskbar == layout.preferences.taskbar then
                return
            end
            local committed, err = store.write(database, next_layout)
            if not committed then error(tostring(err)) end
            layout = next_layout
            select_targets()
            publish()
        end
        local function remove(key: string)
            if retired[key] then return end
            local request_id = uuid.v7()
            retired[key], removals[request_id] = request_id, key
            send(session, "bee.desktop.command", {version = 1, op = "remove", id = key, request_id = request_id})
        end
        local function save_before_exit()
            -- The session command queue fences every command already accepted by
            -- this owner. Its acknowledgement carries the entire final projection.
            local request_id = uuid.v7()
            send(session, "bee.desktop.command", {version = 1, op = "snapshot", request_id = request_id})
            local deadline = time.after("1s")
            while true do
                local selected = channel.select({acknowledgements:case_receive(), deadline:case_receive()})
                if not selected.ok or selected.channel == deadline then error("Client layout save acknowledgement timed out") end
                local message = selected.value
                if tostring(message:from()) == session then
                    local data: unknown = message:payload():data()
                    local ack = decode.ack(data)
                    if ack and ack.request_id == request_id then
                        if ack.error_code ~= "" then error("Session rejected final client snapshot") end
                        adopt(data)
                        return
                    end
                end
            end
        end
        local function request_quit(): boolean
            if bootstrap.quit_mode == "detach" then save_before_exit(); return true end
            if quit_request == "" then
                quit_request = uuid.v7()
                send(owner, "bee.client.quit", {version = 1, workspace_id = workspace_id, request_id = quit_request})
            end
            return false
        end
        local function bind(target: state.Target)
            if not active then return end
            local count = 0
            for _ in pairs(bindings) do count = count + 1 end
            if count >= 128 then error("Client attachment request capacity exhausted") end
            local request_id = uuid.v7()
            bindings[request_id] = {generation = renderer_generation, tab_id = target.tab_id}
            send(host, "bee.app.request", {version = 1, request_id = request_id, op = "bind", workspace_id = workspace_id,
                connection_id = connection_id, renderer_generation = renderer_generation,
                id = target.view_id, instance_id = target.instance_id})
        end
        local function include(reply: contract.Reply): string
            local existing = tab(reply.id, reply.instance_id)
            if existing and not retired[existing] then return existing end
            local key, err = hash.sha256(workspace_id .. "\0" .. reply.instance_id .. "\0" .. reply.id)
            if not key then error(tostring(err)) end
            targets[key] = {tab_id = key, workspace_id = workspace_id, view_id = reply.id, instance_id = reply.instance_id}
            retired[key] = nil
            send(session, "bee.desktop.command", {version = 1, op = "add", id = key, workspace_id = workspace_id,
                instance_id = reply.instance_id, title = reply.title, icon = reply.icon})
            return key
        end
        local function observe(value: inventory.Views)
            if value.workspace_id ~= workspace_id or value.connection_id ~= connection_id or value.revision <= views_revision then return end
            local previous: {[string]: boolean} = {}
            for _, view in ipairs(live) do previous[view.view_id .. "\0" .. view.instance_id] = true end
            views_revision, live = value.revision, value.items
            -- Discovery updates selected tabs but never selects additional views.
            local available: {[string]: boolean} = {}
            for _, view in ipairs(live) do
                local identity = view.view_id .. "\0" .. view.instance_id
                available[identity] = true
                local key = tab(view.view_id, view.instance_id)
                local target = key and targets[key] or nil
                if target then
                    if not previous[identity] then bind(target) end
                    send(session, "bee.desktop.command", {version = 1, op = "announce", id = key,
                        instance_id = view.instance_id, title = view.title})
                end
            end
            for key, target in pairs(targets) do
                local identity = target.view_id .. "\0" .. target.instance_id
                if previous[identity] and not available[identity] then remove(key) end
            end
        end
        local updates = assert(display.view:updates())
        local function spawn_presenter()
            local grant = assert(display.view:grant())
            presenter = tostring(assert(process.with_options({terminal = grant}):with_context({["bee.workspace_owner"] = self,
                ["bee.workspace_id"] = workspace_id}):with_scope(scope("bee:presenter_policy")):spawn_monitored(
                    "bee.terminal:main", "bee:workers", self)))
        end
        local function appearance_result(request: host_protocol.ClientAppearanceRequest, code: string, message: string)
            local current = layout.preferences
            send(host, "bee.client.appearance.result", {version = 1, request_id = request.request_id,
                action = request.action, workspace_id = request.workspace_id, connection_id = request.connection_id,
                renderer = request.renderer, renderer_generation = request.renderer_generation,
                revision = layout.scene.revision, theme = current.theme, background = current.background,
                taskbar = current.taskbar, error_code = code, error = message})
        end
        local function run()
            send(owner, "bee.client.ready", {version = 1, workspace_id = workspace_id,
                client_id = database.client_id, import_receipt = import_receipt})
            while true do
                local cases = {events:case_receive(), input:case_receive(), admissions:case_receive(),
                    presentations:case_receive(), replies:case_receive(),
                    controls:case_receive(), requests:case_receive(), commands:case_receive(), scenes:case_receive(),
                    acknowledgements:case_receive(), updates:case_receive(), question_states:case_receive(),
                    question_results:case_receive(), answers:case_receive(), appearance_requests:case_receive(),
                    supervisor_controls:case_receive()}
                -- Once saved for local shutdown, retain the physical display but
                -- stop consuming app removals and scene edits. Host cleanup must
                -- not overwrite the layout that will be restored on next boot.
                if saved_for_exit then cases = {events:case_receive(), supervisor_controls:case_receive()} end
                -- These channels are independent of admission delivery. Leave their
                -- initial snapshots queued until we can validate the connection.
                if connection_id ~= "" and not saved_for_exit then
                    cases[#cases + 1] = catalogs:case_receive()
                    cases[#cases + 1] = views:case_receive()
                end
                local selected = channel.select(cases)
                if not selected.ok then break end
                if selected.channel == events then
                    local event = selected.value
                    if event.kind == process.event.CANCEL then break end
                    if event.kind == process.event.EXIT then
                        local exited = tostring(event.from)
                        if exited == owner or (exited == host and not saved_for_exit) or exited == session or exited == presenter then break end
                    end
                elseif selected.channel == input then
                    local event = input_decode.decode(selected.value)
                    if event then
                        if event.type == "close" then
                            save_before_exit(); break
                        end
                        if event.type == "key" and event.ctrl and event.key == "q" and event.action ~= "release" then
                            if request_quit() then break end
                        elseif event.type == "resize" then
                            physical.resize(display, event.width, event.height)
                            send(session, "bee.desktop.command", {version = 1, op = "screen", width = event.width, height = event.height})
                        elseif active then display.view:send(event) end
                    end
                elseif selected.channel == updates then
                    if active then physical.present(display) end
                else
                    local message = selected.value
                    local sender = tostring(message:from())
                    local data: unknown = message:payload():data()
                    if selected.channel == admissions and sender == host and connection_id == "" then
                        if type(data) ~= "table" or data.version ~= 1 or data.workspace_id ~= workspace_id then error("Invalid client admission") end
                        local token, generation = contract.text(data.connection_id, 80), contract.text(data.renderer_generation, 80)
                        if not token or token == "" or not generation or generation == "" then error("Invalid admission identity") end
                        connection_id, renderer_generation = token, generation
                        inbox_state = inbox.new(workspace_id, token)
                        select_targets()
                        spawn_presenter()
                elseif selected.channel == question_states and sender == host then
                        if inbox_state and inbox.observe(inbox_state, data) then publish_questions() end
                    elseif selected.channel == appearance_requests and sender == host then
                        local request = host_protocol.client_appearance(data)
                        if request then
                            if request.workspace_id ~= workspace_id or request.connection_id ~= connection_id
                                or request.renderer_generation ~= renderer_generation or request.renderer ~= presenter or not active then
                                appearance_result(request, "stale_renderer", "Client renderer is no longer current")
                            elseif request.action == "state" then
                                appearance_result(request, "", "")
                            else
                                local count = 0
                                for _ in pairs(appearance_pending) do count = count + 1 end
                                if count >= 16 then
                                    appearance_result(request, "busy", "Client appearance request capacity reached")
                                else
                                    local session_request_id = uuid.v7()
                                    appearance_pending[session_request_id] = {request = request}
                                    local sent, err = process.send(session, "bee.desktop.command", {version = 1,
                                        op = "appearance", request_id = session_request_id, theme = request.theme,
                                        background = request.background, taskbar = request.taskbar,
                                        expected_revision = layout.scene.revision})
                                    if not sent then
                                        appearance_pending[session_request_id] = nil
                                        appearance_result(request, "delivery_failed", tostring(err))
                                    end
                                end
                            end
                        end
                    elseif selected.channel == supervisor_controls and sender == owner and bootstrap.quit_mode == "supervisor" then
                        local control = lifecycle.control(data, workspace_id)
                        if control then
                            if control.op == "save" then
                                if not saved_for_exit then save_before_exit(); saved_for_exit = true end
                                send(owner, "bee.client.saved", {version = 1, workspace_id = workspace_id, request_id = control.request_id})
                            elseif control.op == "exit" then
                                if not saved_for_exit then save_before_exit() end
                                send(owner, "bee.client.exit_ready", {version = 1, workspace_id = workspace_id, request_id = control.request_id})
                                break
                            elseif not saved_for_exit then
                                shutdown_question = control.shutdown
                                if not shutdown_question or shutdown_question.request_id ~= shutdown_answered then shutdown_answered = "" end
                                if not shutdown_question then quit_request = "" end
                                publish_questions()
                            end
                        end
                    elseif selected.channel == answers and sender == presenter and active then
                        local response = interaction.response(data)
                        if response and shutdown_question and response.id == shutdown_question.id
                            and response.instance_id == shutdown_question.instance_id and response.request_id == shutdown_question.request_id
                            and response.value == "" then
                            if shutdown_answered ~= response.request_id then
                                send(owner, "bee.client.shutdown_answer", {version = 1, workspace_id = workspace_id,
                                    request_id = response.request_id, id = response.id, instance_id = response.instance_id,
                                    action = response.action, value = response.value})
                                shutdown_answered = response.request_id
                            end
                        elseif inbox_state then
                            local response = inbox.answer(inbox_state, data)
                            if response then send(host, "bee.host.answer", response) end
                        end
                    elseif selected.channel == question_results and sender == host then
                        if inbox_state then
                            local result = inbox.result(inbox_state, data)
                            if result and active then send(presenter, "bee.interaction.result", result) end
                        end
                    elseif selected.channel == controls and sender == presenter then
                        if type(data) == "table" and data.version == 1 then
                            if data.op == "ready" then
                                send(owner, "bee.client.renderer", {version = 1, workspace_id = workspace_id,
                                    connection_id = connection_id, renderer = presenter})
                            elseif data.op == "quit" then
                                if request_quit() then break end
                            elseif data.op == "rejoin" and active then
                                -- Keep the old renderer alive until the host revokes its grants.
                                -- A separate viewport prevents competing output leases during handoff.
                                active, bindings = false, {}
                                retired_presenter, retired_view = presenter, physical.stage(display)
                                updates = assert(display.view:updates())
                                spawn_presenter()
                            end
                        end
                    elseif selected.channel == presentations and sender == host then
                        if type(data) == "table" and data.version == 1 and data.workspace_id == workspace_id and data.connection_id == connection_id
                            and not (active and data.renderer == presenter and data.generation == renderer_generation
                                and data.pending == false and data.error_code == "") then
                            local generation = contract.text(data.generation, 80)
                            if not generation or generation == "" or data.renderer ~= presenter or data.error_code ~= "" then error("Renderer admission failed") end
                            renderer_generation, active = generation, true
                            if retired_presenter ~= "" then process.terminate(retired_presenter); retired_presenter = "" end
                            if retired_view then retired_view:close(); retired_view = nil end
                            publish()
                            publish_questions()
                            for _, view in ipairs(live) do
                                local key = tab(view.view_id, view.instance_id)
                                local target = key and targets[key] or nil
                                if target then bind(target) end
                            end
                            if not initial_opened and initial_application and initial_application ~= "" then
                                initial_opened = true
                                initial_request = uuid.v7()
                                send(host, "bee.app.request", {version = 1, request_id = initial_request, op = "open",
                                    workspace_id = workspace_id, connection_id = connection_id, definition_id = initial_application,
                                    arguments = bootstrap.arguments})
                            end
                        end
                    elseif selected.channel == catalogs and sender == host then
                        local value = inventory.catalog(data)
                        if value and value.workspace_id == workspace_id and value.connection_id == connection_id and value.revision > catalog_revision then
                            catalog_revision, catalog = value.revision, value.items; publish()
                        end
                    elseif selected.channel == views and sender == host then
                        local value = inventory.views(data)
                        if value then observe(value) end
                    elseif selected.channel == requests and sender == presenter and active then
                        local request = contract.request(data)
                        if request and request.workspace_id == workspace_id and (request.op == "open" or request.op == "close") then
                            local target = targets[request.id]
                            if request.op == "open" or target then
                                if pending_count >= 128 then error("Client request capacity exhausted") end
                                if pending[request.request_id] then error("Client request identity reused") end
                                pending[request.request_id] = {op = request.op, tab_id = request.id}
                                pending_count = pending_count + 1
                                send(host, "bee.app.request", {version = 1, request_id = request.request_id, op = request.op,
                                    workspace_id = workspace_id, connection_id = connection_id, definition_id = request.definition_id,
                                    id = target and target.view_id or "", instance_id = target and target.instance_id or ""})
                            end
                        end
                    elseif selected.channel == commands and sender == presenter and active then
                        if type(data) == "table" and (data.op == "focus" or data.op == "place" or data.op == "fullscreen"
                            or data.op == "minimize" or data.op == "collapse" or data.op == "restore" or data.op == "snap" or data.op == "personalize") then
                            send(session, "bee.desktop.command", data)
                        end
                    elseif selected.channel == replies and sender == host then
                        local result = host_protocol.result(data)
                        local reply: contract.Reply? = nil
                        if result and result.views.connection_id == connection_id and result.views.workspace_id == workspace_id then
                            observe(result.views)
                            reply = result.reply
                        end
                        local binding: Binding? = nil
                        if reply then binding = bindings[reply.request_id] end
                        if reply and decode.belongs(reply, workspace_id)
                            and ((reply.op ~= "attached" and reply.op ~= "bind") or (binding and binding.generation == renderer_generation)) then
                            local key = tab(reply.id, reply.instance_id)
                            if not key and binding then key = binding.tab_id end
                            if reply.op == "bind" then bindings[reply.request_id] = nil end
                            local route = pending[reply.request_id]
                            if not key and route and route.tab_id ~= "" then key = route.tab_id end
                            if route and (reply.op == route.op or (route.op == "open" and reply.op == "focus")) then
                                pending[reply.request_id] = nil; pending_count = pending_count - 1
                            end
                            if reply.error_code == "" and (reply.op == "open" or reply.op == "focus") then
                                local current: inventory.View? = nil
                                for _, view in ipairs(live) do
                                    if view.view_id == reply.id and view.instance_id == reply.instance_id then current = view end
                                end
                                if current then
                                    reply.title, reply.icon = current.title, current.icon
                                    key = include(reply)
                                    local target = targets[key]
                                    if not target then error("Missing selected target") end
                                    bind(target)
                                    send(session, "bee.desktop.command", {version = 1, op = "focus", id = key})
                                    if reply.request_id == initial_request and bootstrap.fullscreen then
                                        local fullscreen = false
                                        for _, window in ipairs(layout.scene.windows) do
                                            if window.id == key and window.mode == "fullscreen" then fullscreen = true end
                                        end
                                        if not fullscreen then send(session, "bee.desktop.command", {version = 1, op = "fullscreen", id = key}) end
                                        initial_request = ""
                                    end
                                else
                                    reply.error_code, reply.error = "unavailable", "Application is no longer running"
                                end
                            end
                            if key and ((reply.op == "close" and reply.error_code == "") or reply.op == "closed") then
                                remove(key)
                            end
                            if active and (reply.op ~= "bind" or reply.error_code ~= "") then
                                -- This copy is the renderer's local scene projection; host replies retain native IDs.
                                reply.id = key or ""
                                send(presenter, "bee.app.reply", reply)
                            end
                        end
                    elseif selected.channel == scenes and sender == session then
                        adopt(data)
                    elseif selected.channel == acknowledgements and sender == session then
                        local ack = decode.ack(data)
                        if ack then
                            local key = removals[ack.request_id]
                            if key then
                                if ack.error_code ~= "" then error("Session rejected target removal") end
                                adopt(data)
                                if retired[key] == ack.request_id and not state.target(layout, key) then
                                    targets[key], retired[key] = nil, nil
                                end
                                removals[ack.request_id] = nil
                            else
                                local pending_appearance = appearance_pending[ack.request_id]
                                if pending_appearance then
                                    local appearance_request = pending_appearance.request
                                    if not appearance_request then error("Missing pending appearance request") end
                                    appearance_pending[ack.request_id] = nil
                                    local code, message = ack.error_code, ack.error
                                    if code == "" then
                                        -- Session and durable projection must agree before
                                        -- reporting success. A failed commit ends this client
                                        -- through the same cleanup path as any scene write.
                                        adopt(data)
                                    end
                                    appearance_result(appearance_request, code, message)
                                end
                                if active then send(presenter, "bee.desktop.ack", ack) end
                            end
                        end
                    end
                end
            end
        end
        run()
    end
    local completed, err = pcall(boot)
    if owned_database then store.close(owned_database) end
    if presenter ~= "" then process.terminate(presenter) end
    if retired_presenter ~= "" then process.terminate(retired_presenter) end
    if retired_view then retired_view:close() end
    if session ~= "" then process.terminate(session) end
    if owned_display then physical.close(owned_display) end
    for _, subscription in ipairs(subscriptions) do process.unlisten(subscription) end
    if not completed then error(tostring(err)) end
end
return {main = main}
