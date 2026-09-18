-- MIT. Independent desktop owner. The workspace host retains application lifetime.
local process = require("process")
local status_bindings = require("status_bindings")
local status_surface = require("status_surface")
local clipboard = require("clipboard")
local channel = require("channel")
local tty = require("tty")
local ctx = require("ctx")
local security = require("security")
local uuid = require("uuid")
local hash = require("hash")
local time = require("time")
local logger = require("logger")
local log = logger:named("bee.client")
local store = require("store")
local state = require("state")
local decode = require("decode")
local input_decode = require("input_decode")
local contract = require("contract")
local inventory = require("inventory")
local host_protocol = require("host_protocol")
local transfer = require("transfer")
local transfer_ui = require("transfer_ui")
local assignment_layout = require("assignment_layout")
local physical = require("physical")
local inbox = require("inbox")
local lifecycle = require("lifecycle")
local interaction = require("interaction")
local command = require("command")
local retained_protocol = require("retained_protocol")
local arguments = require("arguments")
local launcher = require("launcher")
local appearance = require("appearance")
local node_appearance = require("node_appearance")
type Channel = channel.Channel
type Binding = {generation: string, tab_id: string}
type TransferPending = {action: transfer_ui.Action, view_id: string, renderer_generation: string, presenter: string}
type AppearancePending = {request: host_protocol.ClientAppearanceRequest}

local function run_client(owner: string, host: string, workspace_id: string, database_resource: string, initial_application: string?, options: unknown, owner_monitored: boolean, terminal: launcher.Terminal?)
    local bootstrap = lifecycle.bootstrap(options)
    if not bootstrap then error("Invalid client bootstrap options") end
    local defaults_reader = node_appearance.new()
    local defaults_timer = assert(time.ticker("1s"))
    local defaults_ticks = defaults_timer:channel()
    local owned_database: store.Store? = nil
    local owned_display: physical.Display? = terminal and terminal.display or nil
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
        local input = terminal and terminal.input or assert(tty.events())
        local admissions = listen("bee.host.admitted")
        local copy_results = listen("bee.selection.copied")
        local launch_requests = listen("bee.client.launch")
        local attachment_updates = listen("bee.desktop.attachments")
        local presentations = listen("bee.host.presentation")
        local catalogs = listen("bee.host.catalog")
        local views = listen("bee.host.views")
        local assignment_updates = listen("bee.host.assignments")
        local transfer_results = listen("bee.host.transfer_result")
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
        if not owner_monitored then
            local monitored, owner_error = process.monitor(owner)
            if not monitored then error("Monitor client owner: " .. tostring(owner_error)) end
        end
        local host_monitored, host_error = process.monitor(host)
        if not host_monitored then error("Monitor workspace host: " .. tostring(host_error)) end
        local database, database_error = store.open(database_resource, bootstrap.desktop_id)
        if not database then error(tostring(database_error)) end
        owned_database = database
        local import_receipt = ""
        if bootstrap.legacy_desktop ~= nil and bootstrap.desktop_id == nil then
            local receipt, import_error = store.import_legacy(database, workspace_id, bootstrap.legacy_desktop, bootstrap.inherit_appearance and "inherit" or "custom")
            if not receipt then error(tostring(import_error)) end
            import_receipt = receipt
        end
        local saved, read_error = store.read(database)
        if read_error then error(read_error) end
        local display: physical.Display = terminal and terminal.display or physical.open()
        owned_display = display
        local layout: state.State = saved or state.empty(display.width, display.height)
        for _, target in ipairs(layout.targets) do
            if target.workspace_id ~= workspace_id then error("This client bootstrap requires one workspace") end
        end
        local targets: {[string]: state.Target} = {}
        local retired: {[string]: string} = {}
        local removals: {[string]: string} = {}
        local pending: {[string]: {op: string, tab_id: string}} = {}
        local pending_count = 0
        local appearance_pending: {[string]: AppearancePending} = {}
        local defaults_request = ""
        local node_defaults: node_appearance.Snapshot? = nil
        for _, target in ipairs(layout.targets) do targets[target.tab_id] = target end
        local catalog: {contract.Descriptor} = {}
        local live: {inventory.View} = {}
        local catalog_revision, views_revision = -1, -1
        local controls_apps = false
        local assignment_snapshot: transfer.Snapshot? = nil
        local transfer_pending: {[string]: TransferPending} = {}
        local transfer_pending_count = 0
        local connection_id, renderer_generation = "", ""
        local bindings: {[string]: Binding} = {}
        local active = false
        local paused = false
        local waiting_presenter = false
        local presenter_failures = 0
        local presenter_deadline = time.after("3s")
        local inbox_state: inbox.State? = nil
        local shutdown_question: interaction.Wire? = nil
        local shutdown_answered = ""
        local quit_request = ""
        local saved_for_exit = false
        local initial_opened = false
        local initial_request = ""
        local launch_pending: {request_id: string, desktop_id: string, fullscreen: boolean}? = nil
        local attachment_state: unknown = nil
        local self = tostring(process.pid())
        local function send(recipient: string, topic: string, value: unknown)
            local sent, err = process.send(recipient, topic, value)
            if not sent then error("Core delivery failed: " .. topic .. ": " .. tostring(err)) end
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
        local presentation: status_surface.Snapshot = {revision = 0, items = {}}
        local transfer_revision = 0
        local transfer_signature, transfer_presenter = "", ""
        local function selected_targets(): {state.Target}
            local selected: {state.Target} = {}
            for key, target in pairs(targets) do
                if not retired[key] then selected[#selected + 1] = target end
            end
            return selected
        end
        local function publish_transfers()
            local snapshot = assignment_snapshot
            if not active or not snapshot or not controls_apps then return end
            local items = assignment_layout.menu(snapshot, selected_targets())
            local parts: {string} = {}
            for _, item in ipairs(items) do
                parts[#parts + 1] = item.tab_id .. "\0" .. item.instance_id .. "\0" .. tostring(item.assignment_revision)
                    .. "\0" .. table.concat(item.targets, "\0")
            end
            local signature = table.concat(parts, "\1")
            if signature == transfer_signature and presenter == transfer_presenter then return end
            if transfer_revision >= 9007199254740990 then error("Display transfer presentation revision exhausted") end
            transfer_revision = transfer_revision + 1
            transfer_signature, transfer_presenter = signature, presenter
            send(presenter, "bee.display.transfers", {version = 1, revision = transfer_revision, items = items})
        end
        local function transfer_result(action: transfer_ui.Action, code: string, message: string)
            send(presenter, "bee.display.transfer_result", {version = 1, request_id = action.request_id,
                id = action.id, instance_id = action.instance_id, target_display_id = action.target_display_id,
                error_code = code, error = message})
        end
        local function request_transfer(data: unknown)
            local action = transfer_ui.action(data)
            if not action then return end
            local existing = transfer_pending[action.request_id]
            if existing then
                local previous = existing.action
                if previous.id ~= action.id or previous.instance_id ~= action.instance_id
                    or previous.target_display_id ~= action.target_display_id or previous.expected_revision ~= action.expected_revision then
                    transfer_result(action, "request_conflict", "Transfer request identity was reused")
                end
                return
            end
            local target = targets[action.id]
            local snapshot = assignment_snapshot
            local allowed = false
            if snapshot and target and not retired[action.id] and target.instance_id == action.instance_id then
                for _, item in ipairs(assignment_layout.menu(snapshot, {target})) do
                    if item.assignment_revision == action.expected_revision then
                        for _, candidate in ipairs(item.targets) do
                            if candidate == action.target_display_id then allowed = true end
                        end
                    end
                end
            end
            if not allowed or not target then
                transfer_result(action, "unavailable", "The application or destination changed; select the display again")
                return
            end
            if transfer_pending_count >= 16 then
                transfer_result(action, "busy", "Display transfers are still pending")
                return
            end
            transfer_pending[action.request_id] = {action = action, view_id = target.view_id,
                renderer_generation = renderer_generation, presenter = presenter}
            transfer_pending_count = transfer_pending_count + 1
            send(host, "bee.host.transfer", {version = 1, workspace_id = workspace_id, connection_id = connection_id,
                renderer_generation = renderer_generation, request_id = action.request_id,
                view_id = target.view_id, instance_id = target.instance_id, target_display_id = action.target_display_id,
                expected_revision = action.expected_revision})
        end
        local function publish()
            publish_transfers()
            if active then send(presenter, "bee.desktop.scene", {scene = layout.scene, tabs = layout.tabs,
                preferences = layout.preferences, catalog = catalog, status_surface = presentation}) end
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
        local status_revision = 0
        local status_fingerprint = ""
        local function publish_bindings()
            if connection_id == "" or views_revision < 0 then return end
            local items: {status_bindings.Binding} = {}
            local identity: {string} = {tostring(layout.scene.revision)}
            for _, window in ipairs(layout.scene.windows) do
                local target = targets[window.id]
                if target and not retired[window.id] and target.workspace_id == workspace_id
                    and target.instance_id == window.instance_id then
                    for _, view in ipairs(live) do
                        if view.view_id == target.view_id and view.instance_id == target.instance_id then
                            items[#items + 1] = {tab_id = window.id, instance_id = view.instance_id, thread_id = view.thread_id}
                            identity[#identity + 1] = window.id
                            identity[#identity + 1] = view.instance_id
                            identity[#identity + 1] = view.thread_id or ""
                            break
                        end
                    end
                end
            end
            local fingerprint = contract.argument_fingerprint(identity)
            if fingerprint == status_fingerprint then return end
            if status_revision >= 9007199254740990 then error("Status binding revision exhausted") end
            status_revision = status_revision + 1
            send(session, "bee.desktop.bindings", {version = 1, workspace_id = workspace_id, revision = status_revision, items = items})
            status_fingerprint = fingerprint
        end
        local function adopt(value: unknown, mode: state.AppearanceMode?)
            local incoming_status = status_surface.decode(value)
            local status_changed = incoming_status ~= nil and incoming_status.revision > presentation.revision
            if incoming_status and status_changed then presentation = incoming_status end
            local projected, projection_error = state.project(layout, value, targets)
            if projection_error then error(projection_error) end
            if not projected then
                if status_changed then publish() end
                return
            end
            local next_layout: state.State = projected
            if mode then next_layout.appearance_mode = mode end
            if next_layout.appearance_mode == layout.appearance_mode
                and next_layout.scene.revision == layout.scene.revision
                and next_layout.scene.focus == layout.scene.focus
                and #next_layout.scene.windows == #layout.scene.windows
                and #next_layout.tabs == #layout.tabs
                and next_layout.preferences.theme == layout.preferences.theme
                and next_layout.preferences.background == layout.preferences.background
                and next_layout.preferences.taskbar == layout.preferences.taskbar then
                if status_changed then publish() end
                return
            end
            local appearance_changed = next_layout.preferences.theme ~= layout.preferences.theme
                or next_layout.preferences.background ~= layout.preferences.background
                or next_layout.preferences.taskbar ~= layout.preferences.taskbar
            local committed, err = store.write(database, next_layout)
            if not committed then error(tostring(err)) end
            layout = next_layout
            if appearance_changed and active then
                send(host, "bee.client.appearance.changed", {version = 1, workspace_id = workspace_id,
                    connection_id = connection_id, renderer = presenter, renderer_generation = renderer_generation,
                    revision = layout.scene.revision, theme = layout.preferences.theme,
                    background = layout.preferences.background, taskbar = layout.preferences.taskbar or "labels"})
            end
            publish_bindings()
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
                send(owner, "bee.client.quit", {version = 1, workspace_id = workspace_id, request_id = quit_request, emergency = paused})
            end
            return false
        end
        local function assigned_here(view_id: string, instance_id: string, binding: boolean): boolean
            if not controls_apps then return true end
            local snapshot = assignment_snapshot
            if snapshot then
                for _, item in ipairs(snapshot.items) do
                    if item.view_id == view_id and item.instance_id == instance_id then
                        return item.display_id == database.client_id and (not binding or not item.pending)
                    end
                end
            end
            -- The projection can arrive after renderer readiness. The host
            -- remains the authority and checks any request sent in that interval.
            return true
        end
        local function bind(target: state.Target)
            if not active or not assigned_here(target.view_id, target.instance_id, true) then return end
            local count = 0
            for _, pending_binding in pairs(bindings) do
                if pending_binding.tab_id == target.tab_id and pending_binding.generation == renderer_generation then return end
                count = count + 1
            end
            if count >= 128 then error("Client attachment request capacity exhausted") end
            local request_id = uuid.v7()
            bindings[request_id] = {generation = renderer_generation, tab_id = target.tab_id}
            send(host, "bee.app.request", {version = 1, request_id = request_id, op = "bind", workspace_id = workspace_id,
                connection_id = connection_id, renderer_generation = renderer_generation,
                id = target.view_id, instance_id = target.instance_id})
        end
        local function include_view(view_id: string, instance_id: string, title: string, icon: string?): string
            local existing = tab(view_id, instance_id)
            if existing and not retired[existing] then return existing end
            local key, err = hash.sha256(workspace_id .. "\0" .. instance_id .. "\0" .. view_id)
            if not key then error(tostring(err)) end
            targets[key] = {tab_id = key, workspace_id = workspace_id, view_id = view_id, instance_id = instance_id}
            retired[key] = nil
            send(session, "bee.desktop.command", {version = 1, op = "add", id = key, workspace_id = workspace_id,
                instance_id = instance_id, title = title, icon = icon})
            return key
        end
        local function reconcile_assignments()
            local snapshot = assignment_snapshot
            if not controls_apps or not snapshot or views_revision < 0 then return end
            local changes = assignment_layout.plan(workspace_id, database.client_id, selected_targets(), live, snapshot.items)
            for _, key in ipairs(changes.remove) do remove(key) end
            for _, view in ipairs(changes.add) do
                local key = include_view(view.view_id, view.instance_id, view.title, view.icon)
                local target = targets[key]
                if target then bind(target) end
            end
        end
        local function observe(value: inventory.Views)
            if value.workspace_id ~= workspace_id or value.connection_id ~= connection_id or value.revision <= views_revision then return end
            local first_inventory = views_revision < 0
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
                if (first_inventory or previous[identity]) and not available[identity] then remove(key) end
            end
            reconcile_assignments()
            publish_bindings()
        end
        local updates = assert(display.view:updates())
        local function spawn_presenter()
            waiting_presenter = true
            presenter_deadline = time.after("3s")
            local grant = assert(display.view:grant())
            presenter = tostring(assert(process.with_options({terminal = grant}):with_context({["bee.workspace_owner"] = self,
                ["bee.workspace_id"] = workspace_id, ["bee.display_id"] = database.client_id,
                ["bee.hive_supervisor"] = bootstrap.hive_supervisor}):with_scope(scope("bee:presenter_policy")):spawn_monitored(
                    "bee.terminal:main", "bee:workers", self, initial_application, bootstrap.secondary_application)))
        end
        local function pause_presenter()
            active, paused, waiting_presenter, bindings = false, true, false, {}
            physical.paused(display, bootstrap.quit_mode == "supervisor")
        end
        local function restart_presenter()
            active, paused, bindings = false, false, {}
            if retired_view then
                if presenter ~= "" and presenter ~= retired_presenter then process.terminate(presenter) end
                physical.replace(display)
            else
                retired_presenter, retired_view = presenter, physical.stage(display)
            end
            updates = assert(display.view:updates())
            spawn_presenter()
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
                local defaults_pending: node_appearance.Pending? = nil
                if bootstrap.node_defaults then
                    defaults_pending = node_appearance.advance(defaults_reader, math.floor(time.now():unix_nano() / 1000000))
                end
                local cases = {defaults_ticks:case_receive(), events:case_receive(), input:case_receive(), admissions:case_receive(),
                    presentations:case_receive(), replies:case_receive(),
                    controls:case_receive(), requests:case_receive(), commands:case_receive(), scenes:case_receive(), launch_requests:case_receive(),
                    acknowledgements:case_receive(), updates:case_receive(), question_states:case_receive(),
                    question_results:case_receive(), answers:case_receive(), appearance_requests:case_receive(),
                    supervisor_controls:case_receive(), copy_results:case_receive(), attachment_updates:case_receive()}
                -- Once saved for local shutdown, retain the physical display but
                -- stop consuming app removals and scene edits. Host cleanup must
                -- not overwrite the layout that will be restored on next boot.
                if saved_for_exit then cases = {events:case_receive(), supervisor_controls:case_receive(), copy_results:case_receive()} end
                if waiting_presenter and not saved_for_exit then cases[#cases + 1] = presenter_deadline:case_receive() end
                -- These channels are independent of admission delivery. Leave their
                -- initial snapshots queued until we can validate the connection.
                if connection_id ~= "" and not saved_for_exit then
                    cases[#cases + 1] = catalogs:case_receive()
                    cases[#cases + 1] = views:case_receive()
                    cases[#cases + 1] = assignment_updates:case_receive()
                    cases[#cases + 1] = transfer_results:case_receive()
                end
                if defaults_pending then cases[#cases + 1] = defaults_pending.response:case_receive() end
                local selected = channel.select(cases)
                if not selected.ok then break end
                if selected.channel == presenter_deadline then
                    log:warn("Presenter readiness timed out", {workspace_id = workspace_id, presenter = presenter})
                    pause_presenter()
                elseif selected.channel == defaults_ticks then
                    local defaults = node_defaults
                    if defaults and layout.appearance_mode == "inherit" and defaults_request == "" and next(appearance_pending) == nil
                        and (layout.preferences.theme ~= defaults.preferences.theme
                            or layout.preferences.background ~= defaults.preferences.background
                            or layout.preferences.taskbar ~= defaults.preferences.taskbar) then
                        defaults_request = uuid.v7()
                        local sent = process.send(session, "bee.desktop.command", {version = 1, op = "appearance",
                            request_id = defaults_request, expected_revision = layout.scene.revision,
                            theme = defaults.preferences.theme, background = defaults.preferences.background,
                            taskbar = defaults.preferences.taskbar})
                        if not sent then defaults_request = "" end
                    end
                elseif defaults_pending and selected.channel == defaults_pending.response then
                    local defaults = node_appearance.complete(defaults_reader, defaults_pending)
                    if defaults and (not node_defaults or (defaults.node_id == node_defaults.node_id and defaults.revision >= node_defaults.revision)) then
                        node_defaults = defaults
                    end
                elseif selected.channel == events then
                    local event = selected.value
                    if event.kind == process.event.CANCEL then break end
                    if event.kind == process.event.EXIT then
                        local exited = tostring(event.from)
                        local failure = decode.exit_error(event.result)
                        if exited == owner or exited == session or (exited == host and (not saved_for_exit or failure ~= nil)) then
                            error("Desktop dependency exited: " .. exited .. ": " .. (failure or "without completing its lifetime protocol"))
                        end
                        if exited == presenter then
                            log:warn("Presenter exited", {workspace_id = workspace_id, presenter = presenter,
                                error = failure or "no error reported", recovery_attempt = presenter_failures})
                            if saved_for_exit then break end
                            if not paused and presenter_failures < 3 then
                                presenter_failures = presenter_failures + 1
                                restart_presenter()
                            else pause_presenter() end
                        end
                    end
                elseif selected.channel == input then
                    local event = input_decode.decode(selected.value)
                    if event then
                        if event.type == "close" then
                            save_before_exit(); break
                        end
                        if event.type == "key" and event.ctrl and event.key == "q" and event.action ~= "release" then
                            if request_quit() then break end
                        elseif paused and event.type == "key" and event.key_type == "f12" and event.action ~= "release" then
                            restart_presenter()
                        elseif event.type == "resize" then
                            physical.resize(display, event.width, event.height)
                            send(session, "bee.desktop.command", {version = 1, op = "screen", width = event.width, height = event.height})
                            if paused then physical.paused(display, bootstrap.quit_mode == "supervisor") end
                        elseif active then display.view:send(event) end
                    end
                elseif selected.channel == updates then
                    if active then physical.present(display) end
                else
                    local message = selected.value
                    local sender = tostring(message:from())
                    local data: unknown = message:payload():data()
                    if selected.channel == copy_results and sender == presenter then
                        local result = clipboard.copy_result(data)
                        if result then
                            if result.error ~= "" then
                                send(presenter, "bee.clipboard.result", {version = 1, request_id = result.request_id,
                                    status = "rejected", error = result.error})
                            end
                            send(owner, "bee.client.copied", {version = 1, request_id = result.request_id,
                                selected = result.selected, text = result.text, error = result.error})
                        end
                    elseif selected.channel == attachment_updates and sender == owner and bootstrap.quit_mode == "supervisor" then
                        attachment_state = data
                        if active and not paused and not waiting_presenter then
                            send(presenter, "bee.desktop.attachments", data)
                        end
                    elseif selected.channel == admissions and sender == host and connection_id == "" then
                        if type(data) ~= "table" or data.version ~= 1 or data.workspace_id ~= workspace_id then error("Invalid client admission") end
                        local token, generation = contract.text(data.connection_id, 80), contract.text(data.renderer_generation, 80)
                        local display_id = contract.workspace_id(data.display_id)
                        if not token or token == "" or not generation or generation == "" or display_id ~= database.client_id then error("Invalid admission identity") end
                        if type(data.permissions) ~= "table" or type(data.permissions.control) ~= "boolean" then error("Invalid admission control permission") end
                        controls_apps = data.permissions.control
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
                            elseif request.action == "inherit" and not node_defaults then
                                appearance_result(request, "unavailable", "Node defaults are not available yet")
                            else
                                local count = 0
                                for _ in pairs(appearance_pending) do count = count + 1 end
                                if count >= 16 then
                                    appearance_result(request, "busy", "Client appearance request capacity reached")
                                else
                                    local selected_preferences = {theme = request.theme, background = request.background, taskbar = request.taskbar}
                                    if request.action == "inherit" and node_defaults then
                                        selected_preferences = {theme = node_defaults.preferences.theme, background = node_defaults.preferences.background,
                                            taskbar = node_defaults.preferences.taskbar or "labels"}
                                    end
                                    local session_request_id = uuid.v7()
                                    appearance_pending[session_request_id] = {request = request}
                                    local sent, err = process.send(session, "bee.desktop.command", {version = 1,
                                        op = "appearance", request_id = session_request_id, theme = selected_preferences.theme,
                                        background = selected_preferences.background, taskbar = selected_preferences.taskbar,
                                        expected_revision = layout.scene.revision})
                                    if not sent then
                                        appearance_pending[session_request_id] = nil
                                        appearance_result(request, "delivery_failed", tostring(err))
                                    end
                                end
                            end
                        end
                    elseif selected.channel == launch_requests and sender == owner and bootstrap.quit_mode == "supervisor" then
                        local did = type(data) == "table" and contract.workspace_id(data.desktop_id) or nil
                        local request = did and retained_protocol.launch(data, workspace_id, did) or nil
                        if request and did then
                            local code, message = "", ""
                            local selected_command: command.Launch? = nil
                            if launch_pending then code, message = "BUSY", "A desktop launch is already pending"
                            elseif not active or paused or saved_for_exit then code, message = "UNAVAILABLE", "Desktop is not ready to launch"
                            else
                                local resolved, resolve_error = command.resolve(request.name, request.arguments)
                                if not resolved then code, message = "INVALID_ARGUMENT", resolve_error or "Command resolution failed"
                                else selected_command = resolved end
                            end
                            if selected_command then
                                launch_pending = {request_id = request.request_id, desktop_id = did, fullscreen = selected_command.fullscreen}
                                send(host, "bee.app.request", {version = 1, workspace_id = workspace_id, connection_id = connection_id,
                                    request_id = request.request_id, op = "open", definition_id = selected_command.definition_id,
                                    arguments = selected_command.arguments})
                            else
                                send(owner, "bee.client.launched", {version = 1, workspace_id = workspace_id, desktop_id = did,
                                    request_id = request.request_id, id = "", instance_id = "", error_code = code, error = message})
                            end
                        end
                    elseif selected.channel == supervisor_controls and sender == owner and bootstrap.quit_mode == "supervisor" then
                        local control = lifecycle.control(data, workspace_id)
                        if control then
                            if control.op == "pause" and not saved_for_exit then
                                pause_presenter()
                            elseif control.op == "save" then
                                if not saved_for_exit then save_before_exit(); saved_for_exit = true end
                                send(owner, "bee.client.saved", {version = 1, workspace_id = workspace_id, request_id = control.request_id})
                            elseif control.op == "exit" then
                                if control.error then
                                    -- The fatal control is authoritative even if
                                    -- its best-effort acknowledgement cannot be
                                    -- delivered to an owner already unwinding.
                                    process.send(owner, "bee.client.exit_ready", {version = 1, workspace_id = workspace_id, request_id = control.request_id})
                                    error(control.error)
                                end
                                if not saved_for_exit then save_before_exit() end
                                send(owner, "bee.client.exit_ready", {version = 1, workspace_id = workspace_id, request_id = control.request_id})
                                break
                            elseif not saved_for_exit then
                                if control.error and active then
                                    local reply = contract.reply(control.request_id, "quit", "delivery_failed", control.error)
                                    reply.workspace_id = workspace_id
                                    send(presenter, "bee.app.reply", reply)
                                end
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
                            if data.op == "transfer" then
                                if active and not paused and not waiting_presenter then request_transfer(data) end
                            elseif data.op == "clipboard" then
                                local request = clipboard.request(data, sender, presenter, active and not paused and not waiting_presenter)
                                if request then
                                    local submitted, failure = physical.clipboard(display, request.text)
                                    -- Submission is not an operating-system clipboard acknowledgement.
                                    send(presenter, "bee.clipboard.result", {version = 1, request_id = request.request_id,
                                        status = submitted and "submitted" or "unavailable", error = failure})
                                end
                            elseif data.op == "ready" then
                                if waiting_presenter and not paused then
                                    waiting_presenter = false
                                    send(owner, "bee.client.renderer", {version = 1, workspace_id = workspace_id,
                                        connection_id = connection_id, renderer = presenter})
                                end
                            elseif data.op == "quit" then
                                if request_quit() then break end
                            elseif data.op == "rejoin" and active then
                                -- Keep the old renderer alive until the host revokes its grants.
                                -- A separate viewport prevents competing output leases during handoff.
                                restart_presenter()
                            end
                        end
                    elseif selected.channel == presentations and sender == host then
                        if type(data) == "table" and data.version == 1 and data.workspace_id == workspace_id and data.connection_id == connection_id
                            and not (active and data.renderer == presenter and data.generation == renderer_generation
                                and data.pending == false and data.error_code == "") then
                            local generation = contract.text(data.generation, 80)
                            if not generation or generation == "" then error("Invalid renderer generation") end
                            if data.error_code ~= "" then
                                pause_presenter()
                            elseif data.renderer == presenter and data.pending == false and not paused then
                                renderer_generation, active, paused = generation, true, false
                                if attachment_state ~= nil then send(presenter, "bee.desktop.attachments", attachment_state) end
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
                            elseif data.renderer == "" and active then pause_presenter() end
                        end
                    elseif selected.channel == catalogs and sender == host then
                        local value = inventory.catalog(data)
                        if value and value.workspace_id == workspace_id and value.connection_id == connection_id and value.revision > catalog_revision then
                            catalog_revision, catalog = value.revision, value.items; publish()
                        end
                    elseif selected.channel == transfer_results and sender == host then
                        local result = transfer.result(data)
                        local pending_transfer: TransferPending? = nil
                        if result then pending_transfer = transfer_pending[result.request_id] end
                        if result and pending_transfer and result.workspace_id == workspace_id and result.connection_id == connection_id
                            and result.view_id == pending_transfer.view_id and result.instance_id == pending_transfer.action.instance_id
                            and result.target_display_id == pending_transfer.action.target_display_id then
                            transfer_pending[result.request_id] = nil
                            transfer_pending_count = transfer_pending_count - 1
                            if active and pending_transfer.presenter == presenter
                                and pending_transfer.renderer_generation == renderer_generation then
                                transfer_result(pending_transfer.action, result.error_code, result.error)
                            end
                        end
                    elseif selected.channel == assignment_updates and sender == host then
                        local snapshot = transfer.snapshot(data)
                        if snapshot and snapshot.workspace_id == workspace_id and snapshot.connection_id == connection_id
                            and snapshot.display_id == database.client_id
                            and (not assignment_snapshot or snapshot.revision > assignment_snapshot.revision) then
                            assignment_snapshot = snapshot
                            reconcile_assignments()
                            publish_transfers()
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
                                    thread_id = request.thread_id,
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
                                if current and assigned_here(reply.id, reply.instance_id, false) then
                                    reply.title, reply.icon = current.title, current.icon
                                    key = include_view(reply.id, reply.instance_id, reply.title, reply.icon)
                                    local target = targets[key]
                                    if not target then error("Missing selected target") end
                                    bind(target)
                                    send(session, "bee.desktop.command", {version = 1, op = "focus", id = key})
                                    if (reply.request_id == initial_request and bootstrap.fullscreen)
                                        or (launch_pending and reply.request_id == launch_pending.request_id and launch_pending.fullscreen) then
                                        local fullscreen = false
                                        for _, window in ipairs(layout.scene.windows) do
                                            if window.id == key and window.mode == "fullscreen" then fullscreen = true end
                                        end
                                        if not fullscreen then send(session, "bee.desktop.command", {version = 1, op = "fullscreen", id = key}) end
                                        initial_request = ""
                                    end
                                else
                                    reply.error_code, reply.error = "unavailable", "Application is no longer available on this display"
                                end
                            end
                            if launch_pending and reply.request_id == launch_pending.request_id and (reply.op == "open" or reply.op == "focus") then
                                send(owner, "bee.client.launched", {version = 1, workspace_id = workspace_id,
                                    desktop_id = launch_pending.desktop_id, request_id = launch_pending.request_id,
                                    id = reply.error_code == "" and reply.id or "", instance_id = reply.error_code == "" and reply.instance_id or "",
                                    error_code = reply.error_code, error = reply.error})
                                launch_pending = nil
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
                            if ack.request_id == defaults_request then defaults_request = "" end
                            -- Scene and acknowledgement topics can arrive independently.
                            -- Commit the acknowledged projection before forwarding success.
                            if ack.error_code == "" then
                                local appearance_change = appearance_pending[ack.request_id]
                                if appearance_change then
                                    adopt(data, appearance_change.request.action == "inherit" and "inherit" or "custom")
                                else adopt(data) end
                            end
                            local key = removals[ack.request_id]
                            if key then
                                if ack.error_code ~= "" then error("Session rejected target removal") end
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
    defaults_timer:stop()
    node_appearance.close(defaults_reader)
    if owned_database then store.close(owned_database) end
    if presenter ~= "" then process.terminate(presenter) end
    if retired_presenter ~= "" then process.terminate(retired_presenter) end
    if retired_view then retired_view:close() end
    if session ~= "" then process.terminate(session) end
    if owned_display then physical.close(owned_display) end
    for _, subscription in ipairs(subscriptions) do process.unlisten(subscription) end
    if not completed then error(tostring(err)) end
end
local function main(owner: string, host: string, workspace_id: string, database_resource: string, initial_application: string?, options: unknown)
    if owner == "" or ctx.get("bee.client_owner") ~= owner or not contract.workspace_id(workspace_id)
        or host == "" or host == owner then error("Untrusted client bootstrap") end
    return run_client(owner, host, workspace_id, database_resource, initial_application, options, false)
end
-- Private terminal entry. The spawn boundary protects this constructor; it never
-- makes an externally supplied owner acceptable to the ordinary client entry.
local function local_entry(database_resource: string, initial_application: string?, options: unknown)
    local bootstrap = lifecycle.bootstrap(options)
    if not bootstrap then error("Invalid local launch options") end
    local boot = launcher.open()
    if not boot then return end
    local function run()
        return run_client(boot.supervisor, boot.host, boot.workspace_id, database_resource, initial_application,
            {version = 1, quit_mode = "supervisor", legacy_desktop = boot.desktop,
                arguments = bootstrap.arguments, fullscreen = bootstrap.fullscreen,
                secondary_application = bootstrap.secondary_application}, true, boot.terminal)
    end
    local ok, err = pcall(run)
    process.terminate(boot.supervisor)
    if not ok then error(err) end
end
-- Private command entry used to prove normal handler semantics before promotion.
local function local_command(database_resource: string, name: string?, ...)
    local tail = arguments.decode({...})
    if not tail then error("Invalid application arguments") end
    if not name or name == "" then return local_entry(database_resource, nil, nil) end
    if name:find(":", 1, true) then
        if #tail > 1 then error("Use bee-app for explicit application arguments") end
        return local_entry(database_resource, name, {version = 1, secondary_application = tail[1]})
    end
    local selected, err = command.resolve(name, tail)
    if not selected then error(err or "Command resolution failed") end
    return local_entry(database_resource, selected.definition_id,
        {version = 1, arguments = selected.arguments, fullscreen = selected.fullscreen})
end
local function local_application(database_resource: string, application: string, ...)
    local values = arguments.decode({...})
    if not values then error("Invalid application arguments") end
    return local_entry(database_resource, application, {version = 1, arguments = values})
end
-- Public argv never selects a database resource. Composition owns that binding.
local function desktop(name: string?, ...)
    return local_command("bee:client_db", name, ...)
end
local function application(application_id: string, ...)
    return local_application("bee:client_db", application_id, ...)
end
return {main = main, local_entry = local_entry, local_command = local_command, local_application = local_application,
    desktop = desktop, application = application}
