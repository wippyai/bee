-- MIT. Stable workspace owner; no physical terminal, session or presenter.
local process = require("process")
local channel = require("channel")
local security = require("security")
local ctx = require("ctx")
local uuid = require("uuid")
local persistence = require("persistence")
local recovery = require("recovery")
local contract = require("contract")
local decode = require("decode")
local model = require("model")
local appearance = require("appearance")
local interaction = require("interaction")
local clients = require("clients")
local hash = require("hash")
type Route = {recipient: string, connection_id: string, request_id: string, op: contract.RequestOp, completed: boolean}
type Detach = {recipient: string, connection_id: string, request_id: string}

local function main(owner: string)
    if owner == "" or ctx.get("bee.host_owner") ~= owner then error("Untrusted host bootstrap") end
    local requests = assert(process.listen("bee.app.request", {message = true}))
    local replies = assert(process.listen("bee.app.reply", {message = true}))
    local catalogs = assert(process.listen("bee.application.catalog", {message = true}))
    local checkpoints = assert(process.listen("bee.application.checkpoint", {message = true}))
    local questions = assert(process.listen("bee.interaction.state", {message = true}))
    local answers = assert(process.listen("bee.interaction.response", {message = true}))
    local preferences = assert(process.listen("bee.appearance.request", {message = true}))
    local shutdown_requests = assert(process.listen("bee.application.shutdown", {message = true}))
    local client_requests = assert(process.listen("bee.host.client", {message = true}))
    local events = assert(process.events())
    assert(process.monitor(owner))
    local database, database_error = persistence.open()
    if not database then error(tostring(database_error)) end
    local workspace_id = database.workspace_id
    local empty_tabs: {string} = {}
    local empty_records: {recovery.Record} = {}
    local snapshot: recovery.Snapshot = {version = 1,
        desktop = {scene = model.new(80, 24), tabs = empty_tabs, preferences = appearance.defaults()}, applications = empty_records}
    if database.saved then snapshot = database.saved end
    local broker_policy, broker_error = security.policy("bee:broker_policy")
    if not broker_policy then database:close(); error(tostring(broker_error)) end
    local boundary, boundary_error = security.policy("bee:core_spawn_boundary")
    if not boundary then database:close(); error(tostring(boundary_error)) end
    local self = tostring(process.pid())
    local broker = tostring(assert(process.with_options({}):with_context({
        ["bee.workspace_owner"] = self, ["bee.workspace_id"] = workspace_id,
    }):with_scope(security.new_scope({broker_policy, boundary})):spawn_monitored(
        "bee.applications:broker", "bee:workers", self, snapshot.desktop.preferences)))
    local restoring = ""
    local restore_queue: {recovery.Record} = {}
    for _, record in ipairs(snapshot.applications) do
        if record.restart_policy == "automatic" then restore_queue[#restore_queue + 1] = record end
    end
    local ready = false
    local stopping = false
    local fatal: string? = nil
    local admitted: {[string]: clients.Client} = {}
    local client_count = 0
    local routes: {[string]: Route} = {}
    local route_count = 0
    local completed_routes: {string} = {}
    local detaches: {[string]: Detach} = {}
    local function deliver(topic: string, value: unknown)
        assert(process.send(owner, topic, value))
    end
    local function send(topic: string, value: unknown)
        assert(process.send(broker, topic, value))
    end
    local function client_result(request_id: string, op: string, recipient: string, connection_id: string, code: string, message: string)
        deliver("bee.host.client_result", {version = 1, request_id = request_id, op = op,
            workspace_id = workspace_id, recipient = recipient, connection_id = connection_id, error_code = code, error = message})
    end
    local function begin_detach(client: clients.Client, request_id: string)
        for _, pending in pairs(detaches) do
            if pending.connection_id == client.connection_id then
                if request_id ~= "" then client_result(request_id, "detach", client.recipient, client.connection_id, "busy", "Detach is pending") end
                return
            end
        end
        client.detaching = true
        local id = uuid.v7()
        detaches[id] = {recipient = client.recipient, connection_id = client.connection_id, request_id = request_id}
        send("bee.app.request", {version = 1, request_id = id, workspace_id = workspace_id, op = "unbind", recipient = client.recipient})
    end
    local function forget_routes(connection_id: string)
        for id, route in pairs(routes) do
            if route.connection_id == connection_id then routes[id] = nil; route_count = route_count - 1 end
        end
        local retained: {string} = {}
        for _, id in ipairs(completed_routes) do if routes[id] then retained[#retained + 1] = id end end
        completed_routes = retained
    end
    local function client_request(client: clients.Client, request: contract.Request, data: unknown)
        local code = ""
        if type(data) ~= "table" or data.connection_id ~= client.connection_id or not clients.allowed(client, request) then
            code = "permission_denied"
        elseif request.workspace_id ~= workspace_id then code = "workspace_mismatch"
        elseif not ready or stopping then code = "busy" end
        if code ~= "" then
            local result = contract.reply(request.request_id, request.op, code, "Client request rejected")
            result.workspace_id = workspace_id
            process.send(client.recipient, "bee.app.reply", result)
            return
        end
        local internal, hash_error = hash.sha256(client.connection_id .. "\0" .. request.request_id)
        if not internal then error(tostring(hash_error)) end
        if not routes[internal] then
            while route_count >= 128 and #completed_routes > 0 do
                local oldest = table.remove(completed_routes, 1)
                if routes[oldest] then routes[oldest] = nil; route_count = route_count - 1 end
            end
            if route_count >= 128 then
                local result = contract.reply(request.request_id, request.op, "busy", "Client request capacity reached")
                result.workspace_id = workspace_id
                process.send(client.recipient, "bee.app.reply", result)
                return
            end
            routes[internal] = {recipient = client.recipient, connection_id = client.connection_id,
                request_id = request.request_id, op = request.op, completed = false}
            route_count = route_count + 1
        end
        request.request_id = internal
        if request.op == "bind" then request.recipient = client.recipient end
        send("bee.app.request", request)
    end
    local function restore_next()
        local record = table.remove(restore_queue, 1)
        if record then
            restoring = uuid.v7()
            send("bee.app.request", {version = 1, request_id = restoring, op = "open", workspace_id = workspace_id,
                definition_id = record.definition_id, restore_instance_id = record.instance_id,
                restore_view_id = record.id, resume_schema = record.resume_schema, resume_state = record.resume_state})
        else
            restoring = ""
            ready = true
            deliver("bee.host.ready", {version = 1, workspace_id = workspace_id, saved = snapshot})
        end
    end
    local function replace_record(record: recovery.Record?, removed: string?): (boolean, string?)
        local records: {recovery.Record} = {}
        local found = false
        for _, previous in ipairs(snapshot.applications) do
            if record and previous.instance_id == record.instance_id and previous.id ~= record.id then
                return false, "Checkpoint duplicates a saved application instance"
            end
            if record and previous.id == record.id then
                record.window = previous.window
                records[#records + 1] = record
                found = true
            elseif previous.id ~= removed then records[#records + 1] = previous end
        end
        if record and not found then records[#records + 1] = record end
        if #records > 16 then return false, "Workspace checkpoint capacity reached" end
        local next: recovery.Snapshot = {version = 1, desktop = snapshot.desktop, applications = records}
        local committed, err = database:write(next)
        if committed then snapshot = next end
        return committed, err
    end
    local function run()
        while true do
            local selected = channel.select({requests:case_receive(), replies:case_receive(), catalogs:case_receive(),
                checkpoints:case_receive(), questions:case_receive(), answers:case_receive(), preferences:case_receive(), shutdown_requests:case_receive(), client_requests:case_receive(), events:case_receive()})
            if not selected.ok then break end
            if selected.channel == events then
                local event = selected.value
                if event.kind == process.event.CANCEL then break end
                if event.kind == process.event.EXIT and tostring(event.from) == broker then fatal = "Workspace broker exited"; break end
                if event.kind == process.event.EXIT and tostring(event.from) == owner then break end
                if event.kind == process.event.EXIT then
                    local client = admitted[tostring(event.from)]
                    if client then begin_detach(client, "") end
                end
            else
                local message = selected.value
                local data: unknown = message:payload():data()
                if selected.channel == catalogs and message:from() == broker then
                    deliver("bee.application.catalog", data)
                    restore_next()
                elseif selected.channel == client_requests and message:from() == owner then
                    local control = clients.control(data)
                    if control then
                        local client = admitted[control.recipient]
                        local code, failure = "", ""
                        if control.workspace_id ~= workspace_id then code, failure = "workspace_mismatch", "Foreign workspace"
                        elseif not ready or stopping then code, failure = "busy", "Host is not accepting clients"
                        elseif control.recipient == owner or control.recipient == self or control.recipient == broker then
                            code, failure = "invalid_argument", "Core owners cannot be desktop clients"
                        elseif control.op == "detach" then
                            if client then begin_detach(client, control.request_id)
                            else code, failure = "not_found", "Client is not admitted" end
                        elseif control.permissions then
                            if client and (client.detaching or not clients.same_permissions(client.permissions, control.permissions)) then
                                code, failure = "busy", "Detach the current admission before replacing its permissions"
                            elseif not client and client_count >= 8 then code, failure = "busy", "Client capacity reached"
                            else
                                if not client then
                                    local monitored, monitor_error = process.monitor(control.recipient)
                                    if not monitored then code, failure = "unavailable", tostring(monitor_error)
                                    else
                                        local joined: clients.Client = {recipient = control.recipient, connection_id = uuid.v7(), permissions = control.permissions, detaching = false}
                                        client = joined
                                        admitted[control.recipient] = joined
                                        client_count = client_count + 1
                                    end
                                end
                                if client and code == "" then
                                    local sent, send_error = process.send(client.recipient, "bee.host.admitted", {version = 1,
                                        workspace_id = workspace_id, connection_id = client.connection_id, permissions = client.permissions})
                                    if not sent then
                                        code, failure = "delivery_failed", tostring(send_error)
                                        begin_detach(client, "")
                                    end
                                end
                            end
                        end
                        if control.op ~= "detach" or code ~= "" then
                            client_result(control.request_id, control.op, control.recipient, client and client.connection_id or "", code, failure)
                        end
                    end
                elseif selected.channel == requests then
                    local request = contract.request(data)
                    local caller = tostring(message:from())
                    local client = admitted[caller]
                    if request and client then client_request(client, request, data)
                    elseif request and caller == owner then
                        if request.workspace_id ~= workspace_id or not ready or stopping then
                            local reply = contract.reply(request.request_id, request.op,
                                request.workspace_id ~= workspace_id and "workspace_mismatch" or "busy", "Workspace request unavailable")
                            reply.workspace_id = workspace_id
                            deliver("bee.app.reply", reply)
                        else
                            if request.op == "shutdown" then stopping = true end
                            send("bee.app.request", data)
                        end
                    end
                elseif selected.channel == checkpoints and message:from() == broker then
                    local record = recovery.record(data)
                    if type(data) == "table" and data.version == 1 and data.workspace_id == workspace_id
                        and contract.text(data.request_id, 80) and record then
                        local committed, err = replace_record(record)
                        send("bee.application.persisted", {version = 1, request_id = data.request_id,
                            error_code = committed and "" or "persistence_failed", error = err or ""})
                        if committed then deliver("bee.host.checkpoint", {version = 1, workspace_id = workspace_id, record = record}) end
                    end
                elseif selected.channel == replies and message:from() == broker then
                    local reply = decode.reply(data)
                    if reply and decode.belongs(reply, workspace_id) then
                        if not stopping and ((reply.op == "close" and reply.error == "") or reply.op == "closed") then
                            local committed, err = replace_record(nil, reply.id)
                            if not committed then error("Workspace save failed: " .. tostring(err)) end
                        end
                        local detached = detaches[reply.request_id]
                        local route = routes[reply.request_id]
                        if detached and reply.op == "unbind" then
                            detaches[reply.request_id] = nil
                            local client = admitted[detached.recipient]
                            if client and client.connection_id == detached.connection_id then
                                if reply.error_code == "" then
                                    local unmonitored, unmonitor_error = process.unmonitor(client.recipient)
                                    if not unmonitored then reply.error_code, reply.error = "unmonitor_failed", tostring(unmonitor_error)
                                    else
                                        forget_routes(client.connection_id)
                                        admitted[client.recipient] = nil
                                        client_count = client_count - 1
                                        process.send(client.recipient, "bee.host.detached", {version = 1, workspace_id = workspace_id, connection_id = client.connection_id})
                                    end
                                end
                                client_result(detached.request_id, "detach", client.recipient, client.connection_id, reply.error_code, reply.error)
                            end
                        elseif route then
                            if not route.completed and (reply.op == route.op or (route.op == "open" and reply.op == "focus")
                                or (reply.error_code ~= "" and reply.op ~= "attached" and reply.op ~= "closing")) then
                                route.completed = true
                                completed_routes[#completed_routes + 1] = reply.request_id
                            end
                            local client = admitted[route.recipient]
                            if client and not client.detaching and client.connection_id == route.connection_id then
                                reply.request_id = route.request_id
                                reply.resume_state = ""
                                if reply.op ~= "attached" then reply.mount = "" end
                                local sent = process.send(client.recipient, "bee.app.reply", reply)
                                if not sent then begin_detach(client, "") end
                            end
                        elseif restoring ~= "" and reply.request_id == restoring and reply.op == "open" then
                            deliver("bee.host.restore_result", reply)
                            restore_next()
                        else deliver("bee.app.reply", reply) end
                        if stopping and reply.op == "shutdown" then break end
                    end
                elseif selected.channel == questions and message:from() == broker then
                    deliver("bee.interaction.state", data)
                elseif selected.channel == answers and message:from() == owner then
                    local response = interaction.response(data)
                    if response then send("bee.interaction.response", data) end
                elseif selected.channel == shutdown_requests and message:from() == owner then
                    if ready and not stopping and type(data) == "table" and data.version == 1 and data.op == "prepare" then
                        send("bee.application.shutdown", {version = 1, op = "prepare"})
                    end
                elseif selected.channel == preferences and message:from() == broker then
                    local next_preferences = appearance.decode(data)
                    if type(data) == "table" and data.version == 1 and contract.text(data.request_id, 80) and next_preferences then
                        local next: recovery.Snapshot = {version = 1, desktop = {scene = snapshot.desktop.scene,
                            tabs = snapshot.desktop.tabs, preferences = next_preferences}, applications = snapshot.applications}
                        local committed, err = database:write(next)
                        if committed then snapshot = next end
                        send("bee.appearance.state", {version = 1, request_id = data.request_id,
                            theme = snapshot.desktop.preferences.theme, background = snapshot.desktop.preferences.background,
                            taskbar = snapshot.desktop.preferences.taskbar, error_code = committed and "" or "persistence_failed", error = err or ""})
                    end
                end
            end
        end
    end
    local completed, run_error = pcall(run)
    database:close()
    process.terminate(broker)
    for _, subscription in ipairs({requests, replies, catalogs, checkpoints, questions, answers, preferences, shutdown_requests, client_requests}) do
        process.unlisten(subscription)
    end
    if not completed then error(run_error) end
    if fatal then error(fatal) end
end

return {main = main}
