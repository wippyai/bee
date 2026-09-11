-- MIT. Owns one local workspace host; never acquires a terminal or client store.
local process = require("process")
local channel = require("channel")
local security = require("security")
local ctx = require("ctx")
local time = require("time")
local logger = require("logger")
local log = logger:named("bee.launch")
local uuid = require("uuid")
local protocol = require("protocol")
local contract = require("contract")
local decode = require("decode")
local interaction = require("interaction")
local desktops = require("desktops")
local desktop_storage = require("desktop_storage")
local desktop_lifecycle = require("desktop_lifecycle")
local attachments = require("attachments")
local retained_protocol = require("retained_protocol")
type Channel = channel.Channel
type Phase = "booting" | "client_boot" | "admitting" | "running" | "rendering" | "saving" | "stopping" | "finishing"
local function run_supervisor(client: string, database_resource: string?, retained_owner: string?, initial_application: string?)
    local retained = desktops.new()
    local desktop: desktops.Desktop? = nil
    local desktop_id = ""
    local retained_displays: desktop_lifecycle.State? = nil
    local storage_pending: desktop_storage.Pending? = nil
    local announced = false
    local subscriptions: {Channel<process.Message>} = {}
    local host = ""
    local function listen(topic: string): Channel<process.Message>
        local value, err = process.listen(topic, {message = true})
        if not value then error(tostring(err)) end
        subscriptions[#subscriptions + 1] = value
        return value
    end
    local function run()
        -- This owner monitors remote physical recipients as well as local
        -- dependencies. Link loss revokes a mount, not the retained workspace.
        local trapping, trap_error = process.set_options({trap_links = true})
        if not trapping then error("Cannot handle desktop link loss: " .. tostring(trap_error)) end
        local activations = listen("bee.retained.activate")
        local storage_requests = listen("bee.retained.desktops")
        local attachment_requests = listen("bee.retained.request")
        local copy_results = listen("bee.client.copied")
        local launch_requests = listen("bee.retained.launch")
        local launch_results = listen("bee.client.launched")
        local launch_pending: {id: string, desktop_id: string, client: string}? = nil
        local copy_pending: {id: string, recipient: string, mount: string, desktop_id: string, client: string}? = nil
        local hosts, ready = listen("bee.host.ready"), listen("bee.client.ready")
        local renderers, results = listen("bee.client.renderer"), listen("bee.host.client_result")
        local quits, answers = listen("bee.client.quit"), listen("bee.client.shutdown_answer")
        local questions, replies = listen("bee.interaction.state"), listen("bee.app.reply")
        local saved, finished = listen("bee.client.saved"), listen("bee.client.exit_ready")
        local events, event_error = process.events()
        if not events then error(tostring(event_error)) end
        assert(process.monitor(retained_owner or client))
        local policies: {security.Policy} = {}
        for _, name in ipairs({"bee:host_policy", "bee:host_spawn_policy", "bee:workspace_storage_policy"}) do
            local policy, err = security.policy(name)
            if not policy then error(tostring(err)) end
            policies[#policies + 1] = policy
        end
        local self = tostring(process.pid())
        host = tostring(assert(process.with_options({}):with_context({["bee.host_owner"] = self})
            :with_scope(security.new_scope(policies)):spawn_monitored("bee.host:main", "bee:workers", self, database_resource)))
        local workspace_id, connection_id = "", ""
        local phase: Phase = "booting"
        local pending = ""
        local quit_pending = false
        local quit_accepted = false
        local deferred_renderer: string? = nil
        local deferred_quit: protocol.Quit? = nil
        local question: interaction.Spec? = nil
        local deadline = time.after("10s")
        local function advance(next_phase: Phase)
            phase = next_phase
            if next_phase ~= "running" then deadline = time.after("10s") end
        end
        local function send(recipient: string, topic: string, value: unknown)
            local sent, err = process.send(recipient, topic, value)
            if not sent then error("Core delivery failed: " .. topic .. ": " .. tostring(err)) end
        end
        local function control(op: string)
            pending = uuid.v7()
            send(client, "bee.client.control", {version = 1, workspace_id = workspace_id, request_id = pending, op = op})
        end
        local function primary_renderer(renderer: string)
            pending = uuid.v7(); advance("rendering")
            send(host, "bee.host.client", {version = 1, workspace_id = workspace_id, request_id = pending,
                op = "render", recipient = client, renderer = renderer})
        end
        local function primary_quit(request: protocol.Quit)
            if request.emergency then
                quit_pending = true
                advance("saving"); control("save")
            elseif not quit_pending then
                quit_pending = true
                send(host, "bee.application.shutdown", {version = 1, op = "prepare"})
            end
        end
        local function find_desktop(id: string): desktops.Desktop?
            if id == desktop_id and desktop then return desktop end
            return retained_displays and desktop_lifecycle.find(retained_displays, id) or nil
        end
        local function has_attachment(recipient: string): boolean
            for _, resource in pairs(retained.desktops) do
                local grants = resource.grants
                if (grants.controller and grants.controller.recipient == recipient) or grants.observers[recipient] then return true end
            end
            return false
        end
        local function storage_reply(request: desktop_storage.Request, reply: desktop_storage.Reply)
            if retained_owner then
                local sent, delivery_error = process.send(retained_owner, "bee.retained.desktops_result", {version = 1, workspace_id = workspace_id,
                    request_id = request.request_id, code = reply.code, message = reply.message,
                    desktop_id = reply.desktop_id, desktops = reply.desktops})
                if not sent then
                    log:warn("Desktop storage reply delivery failed", {request_id = request.request_id,
                        error = tostring(delivery_error)})
                end
            end
        end
        while true do
            if phase == "running" then
                local quitting, rendering = deferred_quit, deferred_renderer
                if quit_accepted then
                    quit_accepted = false
                    advance("saving"); control("save")
                elseif quitting then deferred_quit = nil; primary_quit(quitting)
                elseif rendering then deferred_renderer = nil; primary_renderer(rendering) end
            end
            local current_storage = storage_pending
            local cases = {hosts:case_receive(), ready:case_receive(), results:case_receive(),
                answers:case_receive(), questions:case_receive(), replies:case_receive(),
                saved:case_receive(), finished:case_receive(), events:case_receive(), copy_results:case_receive(), launch_results:case_receive()}
            if phase == "running" or retained_displays then
                cases[#cases + 1] = renderers:case_receive()
                cases[#cases + 1] = quits:case_receive()
            end
            if retained_owner and (phase == "running" or phase == "rendering") then
                cases[#cases + 1] = attachment_requests:case_receive()
                cases[#cases + 1] = launch_requests:case_receive()
                cases[#cases + 1] = storage_requests:case_receive()
                cases[#cases + 1] = activations:case_receive()
            end
            if retained_displays then
                for _, timer in ipairs(desktop_lifecycle.deadlines(retained_displays)) do cases[#cases + 1] = timer:case_receive() end
            end
            if current_storage then
                cases[#cases + 1] = current_storage.response:case_receive()
                cases[#cases + 1] = current_storage.deadline:case_receive()
            end
            if phase ~= "running" then cases[#cases + 1] = deadline:case_receive() end
            local selected = channel.select(cases)
            if not selected.ok then error("Local supervisor channel closed") end
            if retained_displays and desktop_lifecycle.timeout(retained_displays, selected.channel) then
                -- This deadline belongs only to the selected desktop.
            elseif current_storage and (selected.channel == current_storage.response or selected.channel == current_storage.deadline) then
                storage_pending = nil
                local reply = selected.channel == current_storage.response and desktop_storage.complete(current_storage)
                    or desktop_storage.cancel(current_storage)
                storage_reply(current_storage.request, reply)
            elseif selected.channel == deadline then
                if phase ~= "rendering" then error("Local supervisor timed out during " .. phase) end
                -- The host may still complete revocation. Preserve its ownership
                -- and let an explicit retry reconcile with that outcome.
                advance("running"); pending = ""
                send(client, "bee.client.control", {version = 1, workspace_id = workspace_id, request_id = uuid.v7(), op = "pause"})
            elseif selected.channel == events then
                local event = selected.value
                if retained_displays then desktop_lifecycle.event(retained_displays, event) end
                if event.kind == process.event.CANCEL then return end
                if event.kind == process.event.LINK_DOWN then
                    if desktop then
                        local detached = attachments.detach(desktop.grants, tostring(event.from))
                        if detached.error_code ~= "" then error("Desktop detach failed: " .. detached.error) end
                    end
                elseif event.kind == process.event.EXIT then
                    if retained_owner and tostring(event.from) == retained_owner then return end
                    if tostring(event.from) == client then desktops.exited(retained, event); return end
                    if retained_owner then
                        local exited = tostring(event.from)
                        local launching = launch_pending
                        if launching and launching.client == exited then
                            launch_pending = nil
                            send(retained_owner, "bee.retained.launched", {version = 1, workspace_id = workspace_id,
                                desktop_id = launching.desktop_id, request_id = launching.id, id = "", instance_id = "",
                                error_code = "UNCERTAIN", error = "Desktop exited before reporting the launch outcome"})
                        end
                        local copying = copy_pending
                        if copying and (copying.client == exited or copying.recipient == exited) then
                            copy_pending = nil
                            send(retained_owner, "bee.retained.copied", {version = 1, request_id = copying.id,
                                selected = false, text = "", error = "Desktop copy attachment exited"})
                        end
                    end
                    if desktop then
                        local detached = attachments.detach(desktop.grants, tostring(event.from))
                        if detached.error_code ~= "" then error("Desktop detach failed: " .. detached.error) end
                    end
                    local failure = decode.exit_error(event.result)
                    if tostring(event.from) == host and (failure ~= nil or (phase ~= "finishing" and phase ~= "stopping")) then
                        error("Local workspace host exited during " .. phase .. ": " .. (failure or "without completing cleanup"))
                    end
                end
            else
                local message = selected.value
                local sender = tostring(message:from())
                local data: unknown = message:payload():data()
                local topic = selected.channel == ready and "ready" or selected.channel == results and "result"
                    or selected.channel == renderers and "renderer" or selected.channel == quits and "quit"
                    or selected.channel == saved and "saved" or selected.channel == finished and "finished" or ""
                if retained_displays and topic ~= "" and desktop_lifecycle.receive(retained_displays, topic, sender, data) then
                    -- This retained display owns its lifecycle message.
                elseif selected.channel == activations and sender == retained_owner and retained_displays and announced then
                    desktop_lifecycle.activate(retained_displays, data)
                elseif selected.channel == storage_requests and sender == retained_owner and announced then
                    local request = desktop_storage.request(data, workspace_id)
                    if request then
                        if storage_pending then
                            storage_reply(request, desktop_storage.failure(request, "BUSY", "A desktop storage operation is pending"))
                        else
                            local started = desktop_storage.start(request)
                            storage_pending = started
                            if not started then
                                storage_reply(request, desktop_storage.failure(request, "UNAVAILABLE", "Desktop storage dispatch failed"))
                            end
                        end
                    end
                elseif selected.channel == hosts and sender == host and phase == "booting" then
                    local value = protocol.host(data)
                    if not value then error("Invalid local host readiness") end
                    workspace_id = value.workspace_id
                    advance("client_boot")
                    if retained_owner then
                        local client_policies: {security.Policy} = {}
                        for _, name in ipairs({"bee:desktop_policy", "bee:client_spawn_policy", "bee:client_storage_policy", "bee:client_node_defaults_call_policy", "bee:client_node_defaults_read_policy"}) do
                            client_policies[#client_policies + 1] = assert(security.policy(name))
                        end
                        local started, start_error = desktops.start(retained,
                            {host = host, workspace_id = workspace_id, database = "bee:client_db", width = 100, height = 32,
                                application = initial_application, options = {version = 1, quit_mode = "supervisor",
                                    legacy_desktop = value.desktop, inherit_appearance = value.fresh, node_defaults = true, hive_supervisor = retained_owner}}, security.new_scope(client_policies))
                        if not started then error(tostring(start_error)) end
                        desktop, client = started, started.pid
                    else
                        send(client, "bee.launch.host", {version = 1, workspace_id = workspace_id, host = host, desktop = value.desktop})
                    end
                elseif selected.channel == ready and sender == client and phase == "client_boot" then
                    local identity = protocol.ready(data, workspace_id, true)
                    if not identity then error("Client did not acknowledge durable legacy import") end
                    desktop_id = identity.client_id
                    pending = uuid.v7(); advance("admitting")
                    send(host, "bee.host.client", {version = 1, workspace_id = workspace_id, request_id = pending,
                        op = "admit", recipient = client, permissions = {open = true, close = true, control = true,
                            appearance = true}})
                elseif selected.channel == results and sender == host and type(data) == "table" then
                    if protocol.request(data, workspace_id) == pending and (phase == "admitting" or phase == "rendering") then
                        if data.error_code ~= "" then
                            if phase == "admitting" then error("Local client admission failed: " .. tostring(data.error)) end
                            log:warn("Renderer admission refused", {workspace_id = workspace_id,
                                request_id = pending, error_code = tostring(data.error_code), error = tostring(data.error)})
                            advance("running"); pending = ""
                            send(client, "bee.client.control", {version = 1, workspace_id = workspace_id, request_id = uuid.v7(), op = "pause"})
                        else
                            local token = contract.text(data.connection_id, 80)
                            if not token or token == "" then error("Missing local client connection") end
                            local rendered = phase == "rendering"
                            connection_id = token; pending = ""; advance("running")
                            if retained_owner and rendered and not announced then
                                announced = true
                                retained_displays = desktop_lifecycle.new(retained_owner, host, workspace_id, desktop_id, retained)
                                local initial = desktop
                                if not initial then error("Initial retained display resource is missing") end
                                desktop_lifecycle.adopt(retained_displays, desktop_id, initial, connection_id)
                                -- From here the workspace has peers, not a privileged display
                                -- whose exit would terminate the host and every application.
                                desktop, client = nil, ""
                                send(retained_owner, "bee.retained.ready", {version = 1, workspace_id = workspace_id,
                                    desktop_id = desktop_id})
                            end
                        end
                    end
                elseif selected.channel == copy_results and retained_owner then
                    local result = retained_protocol.copy_result(data)
                    local pending_copy = copy_pending
                    if result and pending_copy and sender == pending_copy.client and result.request_id == pending_copy.id then
                        copy_pending = nil
                        local source = find_desktop(pending_copy.desktop_id)
                        local controller = source and source.grants.controller or nil
                        if not controller or controller.recipient ~= pending_copy.recipient or controller.mount ~= pending_copy.mount then
                            result = {request_id = result.request_id, selected = false, text = "", error = "Copy attachment retired"}
                        end
                        send(retained_owner, "bee.retained.copied", {version = 1, request_id = result.request_id,
                            selected = result.selected, text = result.text, error = result.error})
                    end
                elseif selected.channel == launch_results and retained_owner then
                    local waiting = launch_pending
                    local result = waiting and sender == waiting.client and retained_protocol.launch_result(data, workspace_id, waiting.desktop_id) or nil
                    if result and waiting and result.request_id == waiting.id then
                        launch_pending = nil
                        send(retained_owner, "bee.retained.launched", {version = 1, workspace_id = workspace_id,
                            desktop_id = waiting.desktop_id, request_id = result.request_id, id = result.id,
                            instance_id = result.instance_id, error_code = result.error_code, error = result.error})
                    end
                elseif selected.channel == launch_requests and sender == retained_owner and announced then
                    local target = type(data) == "table" and contract.workspace_id(data.desktop_id) or nil
                    local resource = target and find_desktop(target) or nil
                    local request = target and retained_protocol.launch(data, workspace_id, target) or nil
                    if request then
                        local controller = resource and resource.grants.controller or nil
                        local code, message = "", ""
                        if not resource then code, message = "NOT_FOUND", "Desktop is not active"
                        elseif not controller or controller.recipient ~= request.recipient then
                            code, message = "DENIED", "Launch requires the active desktop controller"
                        elseif launch_pending then
                            code, message = "BUSY", "A desktop launch is already pending"
                        end
                        if code ~= "" then
                            send(retained_owner, "bee.retained.launched", {version = 1, workspace_id = workspace_id,
                                desktop_id = target, request_id = request.request_id, id = "", instance_id = "",
                                error_code = code, error = message})
                        elseif resource and target then
                            launch_pending = {id = request.request_id, desktop_id = target, client = resource.pid}
                            send(resource.pid, "bee.client.launch", {version = 1, workspace_id = workspace_id, desktop_id = target,
                                request_id = request.request_id, recipient = request.recipient, name = request.name, arguments = request.arguments})
                        end
                    end
                elseif selected.channel == attachment_requests and sender == retained_owner and announced then
                    local requested_id = type(data) == "table" and contract.workspace_id(data.desktop_id) or nil
                    local selected_desktop = requested_id and find_desktop(requested_id) or nil
                    local request = requested_id and retained_protocol.request(data, workspace_id, requested_id) or nil
                    if request and not selected_desktop then
                        if request.op == "copy" then
                            send(retained_owner, "bee.retained.copied", {version = 1, request_id = request.request_id,
                                selected = false, text = "", error = "Desktop is not active"})
                        else
                            send(retained_owner, "bee.retained.result", {version = 1, workspace_id = workspace_id,
                                desktop_id = requested_id, request_id = request.request_id, mount = "",
                                error_code = request.op == "detach" and "" or "not_found",
                                error = request.op == "detach" and "" or "Desktop is not active"})
                        end
                    elseif request and selected_desktop and requested_id and request.op == "copy" then
                        local controller = selected_desktop.grants.controller
                        if copy_pending then
                            send(retained_owner, "bee.retained.copied", {version = 1, request_id = request.request_id,
                                selected = false, text = "", error = "A desktop copy is already pending"})
                        elseif controller and controller.recipient == request.recipient then
                            copy_pending = {id = request.request_id, recipient = request.recipient, mount = controller.mount,
                                desktop_id = requested_id, client = selected_desktop.pid}
                            local sent, err = selected_desktop.view:send({type = "key", key_type = "bee.copy", key = request.request_id, action = "press", ctrl = false, alt = false, shift = false})
                            if not sent then
                                copy_pending = nil
                                send(retained_owner, "bee.retained.copied", {version = 1, request_id = request.request_id,
                                    selected = false, text = "", error = "Copy input marker unavailable"})
                            end
                        else
                            send(retained_owner, "bee.retained.copied", {version = 1, request_id = request.request_id,
                                selected = false, text = "", error = "Copy requires the active desktop attachment"})
                        end
                    elseif request and selected_desktop then
                        if copy_pending and copy_pending.recipient == request.recipient and copy_pending.desktop_id == requested_id then copy_pending = nil end
                        local result: attachments.Result
                        if request.op == "attach" then result = attachments.attach(selected_desktop.grants, request.recipient, request.mode)
                        else result = attachments.detach(selected_desktop.grants, request.recipient) end
                        if result.error_code == "" and request.op == "attach" then
                            local monitored, monitor_error = process.monitor(request.recipient)
                            if not monitored then
                                local removed = attachments.detach(selected_desktop.grants, request.recipient)
                                if removed.error_code ~= "" then error("Desktop grant cleanup failed: " .. removed.error) end
                                result = {mount = "", error_code = "monitor_failed", error = tostring(monitor_error)}
                            end
                        elseif result.error_code == "" and request.recipient ~= retained_owner
                            and request.recipient ~= client and request.recipient ~= host and not has_attachment(request.recipient) then
                            process.unmonitor(request.recipient)
                        end
                        send(sender, "bee.retained.result", {version = 1, workspace_id = workspace_id, desktop_id = requested_id,
                            request_id = request.request_id, mount = result.mount, error_code = result.error_code, error = result.error})
                    end
                elseif selected.channel == renderers and sender == client and type(data) == "table" and data.version == 1 then
                    if data.workspace_id == workspace_id and data.connection_id == connection_id then
                        local renderer = contract.text(data.renderer, 160)
                        if not renderer or renderer == "" then error("Invalid local renderer") end
                        if phase == "running" then primary_renderer(renderer)
                        elseif phase == "running" or phase == "rendering" then deferred_renderer = renderer end
                    end
                elseif selected.channel == quits and sender == client then
                    local request = protocol.quit(data, workspace_id)
                    if request then
                        if phase == "running" then primary_quit(request)
                        elseif phase == "rendering" then deferred_quit = request end
                    end
                elseif selected.channel == questions and sender == host and (phase == "running" or phase == "rendering") then
                    local current = interaction.shutdown(data)
                    if type(data) == "table" and data.version == 1 and (data.shutdown == nil or current) then
                        if current or question then
                            question = current
                            if not current then quit_pending = false end
                            send(client, "bee.client.control", {version = 1, workspace_id = workspace_id,
                                request_id = uuid.v7(), op = "state", shutdown = current and interaction.wire(current) or nil})
                        end
                    end
                elseif selected.channel == answers and sender == client and (phase == "running" or phase == "rendering") then
                    local response = interaction.response(data)
                    if protocol.request(data, workspace_id) and response and question and response.request_id == question.request_id
                        and response.id == question.id and response.instance_id == question.instance_id and response.value == "" then
                        send(host, "bee.interaction.response", data)
                    end
                elseif selected.channel == replies and sender == host then
                    local reply = decode.reply(data)
                    if reply and decode.belongs(reply, workspace_id) then
                        if (phase == "running" or phase == "rendering") and quit_pending and reply.op == "quit" then
                            if reply.error_code == "" then
                                -- Finish an in-flight renderer bind before replacing its correlation with save.
                                quit_accepted = true
                            else
                                quit_pending, question = false, nil
                                send(client, "bee.client.control", {version = 1, workspace_id = workspace_id,
                                    request_id = uuid.v7(), op = "state", error = reply.error})
                            end
                        elseif phase == "stopping" and reply.op == "shutdown" and reply.request_id == pending then
                            if reply.error_code ~= "" then error("Workspace cleanup failed: " .. reply.error) end
                            advance("finishing"); control("exit")
                        end
                    end
                elseif selected.channel == saved and sender == client and phase == "saving" and protocol.request(data, workspace_id) == pending then
                    pending = uuid.v7(); advance("stopping")
                    send(host, "bee.app.request", {version = 1, workspace_id = workspace_id, request_id = pending, op = "shutdown"})
                elseif selected.channel == finished and sender == client and phase == "finishing" and protocol.request(data, workspace_id) == pending then
                    return
                end
            end
        end
    end
    local ok, err = pcall(run)
    if storage_pending then desktop_storage.cancel(storage_pending) end
    if retained_displays then desktop_lifecycle.close(retained_displays) end
    if retained_owner and client ~= "" then process.terminate(client) end
    if host ~= "" then process.terminate(host) end
    for _, subscription in ipairs(subscriptions) do process.unlisten(subscription) end
    if not ok then error(err) end
end
local function main(client: string, database_resource: string?)
    if client == "" or ctx.get("bee.launch_owner") ~= client then error("Untrusted local supervisor bootstrap") end
    return run_supervisor(client, database_resource, nil, nil)
end
local function retained(owner: string, initial_application: string?)
    if owner == "" or ctx.get("bee.retained_owner") ~= owner then error("Untrusted retained supervisor bootstrap") end
    return run_supervisor("", nil, owner, initial_application)
end
return {main = main, retained = retained}
