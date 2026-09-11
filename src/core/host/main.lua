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
local connections = require("connections")
local inventory = require("inventory")

local function main(owner: string, database_resource: string?)
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
    local selections = assert(process.listen("bee.host.selection", {message = true}))
    local client_answers = assert(process.listen("bee.host.answer", {message = true}))
    local appearance_changes = assert(process.listen("bee.client.appearance.changed", {message = true}))
    local client_appearance = assert(process.listen("bee.client.appearance.result", {message = true}))
    local events = assert(process.events())
    assert(process.monitor(owner))
    local database, database_error = persistence.open(database_resource)
    if not database then error(tostring(database_error)) end
    local fresh_workspace = database.saved == nil
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
    local client_connections = connections.new(owner, broker, workspace_id, database.assignments)
    local live_inventory = inventory.new(workspace_id)
    local catalog_received = false
    local function deliver(topic: string, value: unknown)
        assert(process.send(owner, topic, value))
    end
    local function send(topic: string, value: unknown)
        local sent, err = process.send(broker, topic, value)
        if not sent then error("Core delivery failed: " .. topic .. ": " .. tostring(err)) end
    end
    local function restore_next()
        local record = table.remove(restore_queue, 1)
        if record then
            restoring = uuid.v7()
            send("bee.app.request", {version = 1, request_id = restoring, op = "open", workspace_id = workspace_id,
                definition_id = record.definition_id, thread_id = record.thread_id, restore_instance_id = record.instance_id,
                restore_view_id = record.id, resume_schema = record.resume_schema, resume_state = record.resume_state})
        else
            restoring = ""
            ready = true
            deliver("bee.host.ready", {version = 1, workspace_id = workspace_id, fresh = fresh_workspace, saved = snapshot})
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
                checkpoints:case_receive(), questions:case_receive(), answers:case_receive(), preferences:case_receive(), shutdown_requests:case_receive(), client_requests:case_receive(),
                selections:case_receive(), client_answers:case_receive(), appearance_changes:case_receive(), client_appearance:case_receive(), events:case_receive()})
            if not selected.ok then break end
            if selected.channel == events then
                local event = selected.value
                if event.kind == process.event.CANCEL then break end
                if event.kind == process.event.EXIT and tostring(event.from) == broker then
                    fatal = "Workspace broker exited: " .. (decode.exit_error(event.result) or "without completing cleanup"); break
                end
                if event.kind == process.event.EXIT and tostring(event.from) == owner then break end
                if event.kind == process.event.EXIT then
                    connections.exited(client_connections, tostring(event.from))
                end
            else
                local message = selected.value
                local data: unknown = message:payload():data()
                if selected.channel == catalogs and message:from() == broker then
                    if type(data) == "table" and data.version == 1 then
                        local next_inventory = inventory.set_catalog(live_inventory, data.items)
                        if not next_inventory then error("Invalid broker catalog") end
                        live_inventory = next_inventory
                        deliver("bee.application.catalog", data)
                        if ready then connections.publish(client_connections, live_inventory, "catalog") end
                        if not catalog_received then catalog_received = true; restore_next() end
                    end
                elseif selected.channel == client_requests then
                    local joined = connections.control(client_connections, tostring(message:from()), data, ready and not stopping)
                    if joined then
                        connections.publish(client_connections, live_inventory, "catalog", joined)
                        connections.publish(client_connections, live_inventory, "views", joined)
                    end
                elseif selected.channel == requests then
                    local request = contract.request(data)
                    local caller = tostring(message:from())
                    if request and not connections.request(client_connections, caller, request, data, ready and not stopping, snapshot.applications) and caller == owner then
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
                        local next_inventory = inventory.observe(live_inventory, reply)
                        if not stopping and ((reply.op == "close" and reply.error == "") or reply.op == "closed") then
                            local committed, err = replace_record(nil, reply.id)
                            if not committed then error("Workspace save failed: " .. tostring(err)) end
                        end
                        if next_inventory then
                            live_inventory = next_inventory
                            if ready then connections.publish(client_connections, live_inventory, "views") end
                        end
                        if not connections.reply(client_connections, reply, live_inventory) then
                            if restoring ~= "" and reply.request_id == restoring and reply.op == "open" then
                                deliver("bee.host.restore_result", reply)
                                restore_next()
                            else deliver("bee.app.reply", reply) end
                        end
                        if stopping and reply.op == "shutdown" then break end
                    end
                elseif selected.channel == questions and message:from() == broker then
                    connections.questions(client_connections, data)
                    deliver("bee.interaction.state", data)
                elseif selected.channel == selections then
                    connections.selection(client_connections, tostring(message:from()), data)
                elseif selected.channel == client_answers then
                    connections.answer(client_connections, tostring(message:from()), data)
                elseif selected.channel == appearance_changes then
                    connections.appearance_changed(client_connections, tostring(message:from()), data)
                elseif selected.channel == client_appearance then
                    connections.appearance_result(client_connections, tostring(message:from()), data)
                elseif selected.channel == answers and message:from() == owner then
                    local response = interaction.response(data)
                    if response then send("bee.interaction.response", data) end
                elseif selected.channel == shutdown_requests and message:from() == owner then
                    if ready and not stopping and type(data) == "table" and data.version == 1 and data.op == "prepare" then
                        local sent, err = process.send(broker, "bee.application.shutdown", {version = 1, op = "prepare"})
                        if not sent then
                            local reply = contract.reply("", "quit", "delivery_failed", tostring(err))
                            reply.workspace_id = workspace_id
                            deliver("bee.app.reply", reply)
                        end
                    end
                elseif selected.channel == preferences and message:from() == broker then
                    connections.appearance(client_connections, tostring(message:from()), data, ready and not stopping)
                end
            end
        end
    end
    local completed, run_error = pcall(run)
    database:close()
    process.terminate(broker)
    for _, subscription in ipairs({requests, replies, catalogs, checkpoints, questions, answers, preferences, shutdown_requests, client_requests, selections, client_answers, appearance_changes, client_appearance}) do
        process.unlisten(subscription)
    end
    if not completed then error(run_error) end
    if fatal then error(fatal) end
end

return {main = main}
