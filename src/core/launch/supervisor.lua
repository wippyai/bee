-- MIT. Owns one local workspace host; never acquires a terminal or client store.
local process = require("process")
local channel = require("channel")
local security = require("security")
local ctx = require("ctx")
local time = require("time")
local uuid = require("uuid")
local protocol = require("protocol")
local contract = require("contract")
local decode = require("decode")
local interaction = require("interaction")
type Channel = channel.Channel
type Phase = "booting" | "client_boot" | "admitting" | "running" | "rendering" | "saving" | "stopping" | "finishing"
local function main(client: string, database_resource: string?)
    if client == "" or ctx.get("bee.launch_owner") ~= client then error("Untrusted local supervisor bootstrap") end
    local subscriptions: {Channel<process.Message>} = {}
    local host = ""
    local function listen(topic: string): Channel<process.Message>
        local value, err = process.listen(topic, {message = true})
        if not value then error(tostring(err)) end
        subscriptions[#subscriptions + 1] = value
        return value
    end
    local function run()
        local hosts, ready = listen("bee.host.ready"), listen("bee.client.ready")
        local renderers, results = listen("bee.client.renderer"), listen("bee.host.client_result")
        local quits, answers = listen("bee.client.quit"), listen("bee.client.shutdown_answer")
        local questions, replies = listen("bee.interaction.state"), listen("bee.app.reply")
        local saved, finished = listen("bee.client.saved"), listen("bee.client.exit_ready")
        local events, event_error = process.events()
        if not events then error(tostring(event_error)) end
        assert(process.monitor(client))
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
                saved:case_receive(), finished:case_receive(), events:case_receive()}
            if phase == "running" then
                cases[#cases + 1] = renderers:case_receive()
                cases[#cases + 1] = quits:case_receive()
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
                if event.kind == process.event.EXIT then
                    if tostring(event.from) == client then return end
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
                    send(client, "bee.launch.host", {version = 1, workspace_id = workspace_id, host = host, desktop = value.desktop})
                elseif selected.channel == ready and sender == client and phase == "client_boot" then
                    if not protocol.ready(data, workspace_id) then error("Client did not acknowledge durable legacy import") end
                    pending = uuid.v7(); advance("admitting")
                    send(host, "bee.host.client", {version = 1, workspace_id = workspace_id, request_id = pending,
                        op = "admit", recipient = client, permissions = {open = true, close = true, control = true,
                            appearance = true, workspace_appearance = true}})
                elseif selected.channel == results and sender == host and type(data) == "table" then
                    if protocol.request(data, workspace_id) == pending and (phase == "admitting" or phase == "rendering") then
                        if data.error_code ~= "" then
                            if phase == "admitting" then error("Local client admission failed: " .. tostring(data.error)) end
                            advance("running"); pending = ""
                            send(client, "bee.client.control", {version = 1, workspace_id = workspace_id, request_id = uuid.v7(), op = "pause"})
                        else
                            local token = contract.text(data.connection_id, 80)
                            if not token or token == "" then error("Missing local client connection") end
                            connection_id = token; pending = ""; advance("running")
                        end
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
    if host ~= "" then process.terminate(host) end
    for _, subscription in ipairs(subscriptions) do process.unlisten(subscription) end
    if not ok then error(err) end
end
return {main = main}
