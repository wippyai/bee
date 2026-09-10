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
local attachments = require("attachments")
local retained_protocol = require("retained_protocol")
type Channel = channel.Channel
type Phase = "booting" | "client_boot" | "admitting" | "running" | "rendering" | "saving" | "stopping" | "finishing"
local function run_supervisor(client: string, database_resource: string?, retained_owner: string?, initial_application: string?)
    local retained = desktops.new()
    local desktop: desktops.Desktop? = nil
    local desktop_id = ""
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
        local attachment_requests = listen("bee.retained.request")
        local copy_results = listen("bee.client.copied")
        local launch_requests = listen("bee.retained.launch")
        local launch_results = listen("bee.client.launched")
        local launch_pending: string? = nil
        local copy_pending: {id: string, recipient: string, mount: string}? = nil
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
        while true do
            local cases = {hosts:case_receive(), ready:case_receive(), results:case_receive(),
                answers:case_receive(), questions:case_receive(), replies:case_receive(),
                saved:case_receive(), finished:case_receive(), events:case_receive(), copy_results:case_receive(), launch_results:case_receive()}
            if phase == "running" then
                cases[#cases + 1] = renderers:case_receive()
                cases[#cases + 1] = quits:case_receive()
            end
            if retained_owner and phase == "running" then
                cases[#cases + 1] = attachment_requests:case_receive()
                cases[#cases + 1] = launch_requests:case_receive()
            end
            if phase ~= "running" then cases[#cases + 1] = deadline:case_receive() end
            local selected = channel.select(cases)
            if not selected.ok then error("Local supervisor channel closed") end
            if selected.channel == deadline then
                if phase ~= "rendering" then error("Local supervisor timed out during " .. phase) end
                -- The host may still complete revocation. Preserve its ownership
                -- and let an explicit retry reconcile with that outcome.
                advance("running"); pending = ""
                send(client, "bee.client.control", {version = 1, workspace_id = workspace_id, request_id = uuid.v7(), op = "pause"})
            elseif selected.channel == events then
                local event = selected.value
                if event.kind == process.event.CANCEL then return end
                if event.kind == process.event.LINK_DOWN then
                    if desktop then
                        local detached = attachments.detach(desktop.grants, tostring(event.from))
                        if detached.error_code ~= "" then error("Desktop detach failed: " .. detached.error) end
                    end
                elseif event.kind == process.event.EXIT then
                    if retained_owner and tostring(event.from) == retained_owner then return end
                    if tostring(event.from) == client then desktops.exited(retained, event); return end
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
                if selected.channel == hosts and sender == host and phase == "booting" then
                    local value = protocol.host(data)
                    if not value then error("Invalid local host readiness") end
                    workspace_id = value.workspace_id
                    advance("client_boot")
                    if retained_owner then
                        local client_policies: {security.Policy} = {}
                        for _, name in ipairs({"bee:desktop_policy", "bee:client_spawn_policy", "bee:client_storage_policy"}) do
                            client_policies[#client_policies + 1] = assert(security.policy(name))
                        end
                        local started, start_error = desktops.start(retained,
                            {host = host, workspace_id = workspace_id, database = "bee:client_db", width = 100, height = 32,
                                application = initial_application, options = {version = 1, quit_mode = "supervisor",
                                    legacy_desktop = value.desktop, workspace_appearance = true}}, security.new_scope(client_policies))
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
                            appearance = true, workspace_appearance = true}})
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
                                send(retained_owner, "bee.retained.ready", {version = 1, workspace_id = workspace_id,
                                    desktop_id = desktop_id})
                            end
                        end
                    end
                elseif selected.channel == copy_results and sender == client and retained_owner and desktop then
                    local result = retained_protocol.copy_result(data)
                    local pending_copy = copy_pending
                    if result and pending_copy and result.request_id == pending_copy.id then
                        copy_pending = nil
                        local controller = desktop.grants.controller
                        if not controller or controller.recipient ~= pending_copy.recipient or controller.mount ~= pending_copy.mount then
                            result = {request_id = result.request_id, selected = false, text = "", error = "Copy attachment retired"}
                        end
                        send(retained_owner, "bee.retained.copied", {version = 1, request_id = result.request_id,
                            selected = result.selected, text = result.text, error = result.error})
                    end
                elseif selected.channel == launch_results and sender == client and retained_owner then
                    local result = retained_protocol.launch_result(data, workspace_id, desktop_id)
                    if result and result.request_id == launch_pending then
                        launch_pending = nil
                        send(retained_owner, "bee.retained.launched", {version = 1, workspace_id = workspace_id,
                            desktop_id = desktop_id, request_id = result.request_id, id = result.id,
                            instance_id = result.instance_id, error_code = result.error_code, error = result.error})
                    end
                elseif selected.channel == launch_requests and sender == retained_owner and desktop and announced then
                    local request = retained_protocol.launch(data, workspace_id, desktop_id)
                    if request then
                        local controller = desktop.grants.controller
                        local code, message = "", ""
                        if not controller or controller.recipient ~= request.recipient then
                            code, message = "DENIED", "Launch requires the active desktop controller"
                        elseif launch_pending then
                            code, message = "BUSY", "A desktop launch is already pending"
                        end
                        if code ~= "" then
                            send(retained_owner, "bee.retained.launched", {version = 1, workspace_id = workspace_id,
                                desktop_id = desktop_id, request_id = request.request_id, id = "", instance_id = "",
                                error_code = code, error = message})
                        else
                            launch_pending = request.request_id
                            send(client, "bee.client.launch", {version = 1, workspace_id = workspace_id, desktop_id = desktop_id,
                                request_id = request.request_id, recipient = request.recipient, name = request.name, arguments = request.arguments})
                        end
                    end
                elseif selected.channel == attachment_requests and sender == retained_owner and desktop and announced then
                    local request = retained_protocol.request(data, workspace_id, desktop_id)
                    if request and request.op == "copy" then
                        local controller = desktop.grants.controller
                        if controller and controller.recipient == request.recipient then
                            copy_pending = {id = request.request_id, recipient = request.recipient, mount = controller.mount}
                            local sent, err = desktop.view:send({type = "key", key_type = "bee.copy", key = request.request_id, action = "press", ctrl = false, alt = false, shift = false})
                            if not sent then
                                copy_pending = nil
                                send(retained_owner, "bee.retained.copied", {version = 1, request_id = request.request_id,
                                    selected = false, text = "", error = "Copy input marker unavailable"})
                            end
                        else
                            send(retained_owner, "bee.retained.copied", {version = 1, request_id = request.request_id,
                                selected = false, text = "", error = "Copy requires the active desktop attachment"})
                        end
                    elseif request then
                        if copy_pending and copy_pending.recipient == request.recipient then copy_pending = nil end
                        local result: attachments.Result
                        if request.op == "attach" then result = attachments.attach(desktop.grants, request.recipient, request.mode)
                        else result = attachments.detach(desktop.grants, request.recipient) end
                        if result.error_code == "" and request.op == "attach" then
                            local monitored, monitor_error = process.monitor(request.recipient)
                            if not monitored then
                                local removed = attachments.detach(desktop.grants, request.recipient)
                                if removed.error_code ~= "" then error("Desktop grant cleanup failed: " .. removed.error) end
                                result = {mount = "", error_code = "monitor_failed", error = tostring(monitor_error)}
                            end
                        elseif result.error_code == "" and request.recipient ~= retained_owner
                            and request.recipient ~= client and request.recipient ~= host then
                            process.unmonitor(request.recipient)
                        end
                        send(sender, "bee.retained.result", {version = 1, workspace_id = workspace_id, desktop_id = desktop_id,
                            request_id = request.request_id, mount = result.mount, error_code = result.error_code, error = result.error})
                    end
                elseif selected.channel == renderers and sender == client and type(data) == "table" and data.version == 1 then
                    if data.workspace_id == workspace_id and data.connection_id == connection_id and phase == "running" then
                        local renderer = contract.text(data.renderer, 160)
                        if not renderer or renderer == "" then error("Invalid local renderer") end
                        pending = uuid.v7(); advance("rendering")
                        send(host, "bee.host.client", {version = 1, workspace_id = workspace_id, request_id = pending,
                            op = "render", recipient = client, renderer = renderer})
                    end
                elseif selected.channel == quits and sender == client and phase == "running" then
                    local request = protocol.quit(data, workspace_id)
                    if request and request.emergency then
                        quit_pending = true
                        advance("saving"); control("save")
                    elseif request and not quit_pending then
                        quit_pending = true
                        send(host, "bee.application.shutdown", {version = 1, op = "prepare"})
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
                elseif selected.channel == answers and sender == client and phase == "running" then
                    local response = interaction.response(data)
                    if protocol.request(data, workspace_id) and response and question and response.request_id == question.request_id
                        and response.id == question.id and response.instance_id == question.instance_id and response.value == "" then
                        send(host, "bee.interaction.response", data)
                    end
                elseif selected.channel == replies and sender == host then
                    local reply = decode.reply(data)
                    if reply and decode.belongs(reply, workspace_id) then
                        if phase == "running" and quit_pending and reply.op == "quit" then
                            if reply.error_code == "" then
                                advance("saving"); control("save")
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
