-- MIT. Exercise the actual stable workspace host without a desktop or physical TTY.
local process = require("process")
local security = require("security")
local tty = require("tty")
local contract = require("contract")
local decode = require("decode")
local recovery = require("recovery")
local persistence = require("persistence")
local model = require("model")
local appearance = require("appearance")
local M = {}
function M.guest(owner: string, host: string, workspace_id: string)
    assert(process.send(host, "bee.app.request", {version = 1, request_id = "forged", op = "open",
        workspace_id = workspace_id, definition_id = "bee.attachment_probe:app"}))
    assert(process.send(owner, "bee.host.guest_sent", {}))
end
function M.main()
    local owner = tostring(process.pid())
    local ready = assert(process.listen("bee.host.ready", {message = true}))
    local replies = assert(process.listen("bee.app.reply", {message = true}))
    local checkpoints = assert(process.listen("bee.host.checkpoint", {message = true}))
    local restores = assert(process.listen("bee.host.restore_result", {message = true}))
    local events = assert(process.events())
    local guest_sent = assert(process.listen("bee.host.guest_sent", {message = true}))
    local policies: {security.Policy} = {}
    for _, name in ipairs({"bee:host_policy", "bee:host_spawn_policy", "bee:workspace_storage_policy"}) do
        local policy, err = security.policy(name)
        if not policy then error(tostring(err)) end
        policies[#policies + 1] = policy
    end
    local scope = security.new_scope(policies)
    local function start(expected_records: integer): (string, string)
        local host = tostring(assert(process.with_options({}):with_scope(scope):with_context({["bee.host_owner"] = owner})
            :spawn_monitored("bee.host:main", "bee:workers", owner, {root_ref = "bee:workspace_root", subpath = ""})))
        local message = assert(ready:receive())
        assert(message:from() == host)
        local data: unknown = message:payload():data()
        if type(data) ~= "table" or data.version ~= 1 then error("Invalid host readiness") end
        local saved: unknown = data.saved
        if type(saved) ~= "table" or type(saved.applications) ~= "table" then error("Missing saved application snapshot") end
        assert(#saved.applications == expected_records, "Unexpected persisted application membership")
        local workspace_id = contract.workspace_id(data.workspace_id)
        if not workspace_id then error("Missing host workspace identity") end
        return host, workspace_id
    end
    local host, workspace_id = start(0)
    local function reply(id: string, op: string): decode.Reply
        while true do
            local message = assert(replies:receive())
            assert(message:from() == host)
            local result = decode.reply(message:payload():data())
            if not result then error("Invalid host reply") end
            assert(result.request_id ~= "forged", "Host accepted a non-supervisor request")
            assert(decode.belongs(result, workspace_id))
            if result.request_id == id and result.op == op then return result end
        end
        error("Host reply channel closed")
    end
    local function request(id: string, op: string, recipient: string?)
        assert(process.send(host, "bee.app.request", {version = 1, request_id = id, op = op,
            workspace_id = workspace_id, definition_id = op == "open" and "bee.attachment_probe:app" or "",
            recipient = recipient or ""}))
    end
    local function stop(id: string)
        request(id, "shutdown")
        assert(reply(id, "shutdown").error_code == "")
        while true do
            local event = assert(events:receive())
            if event.kind == process.event.EXIT and tostring(event.from) == host then break end
        end
    end
    local guest = tostring(assert(process.with_options({}):spawn_monitored(
        "bee.attachment_probe:host_guest", "bee:workers", owner, host, workspace_id)))
    assert(guest_sent:receive():from() == guest)
    request("open", "open")
    local opened = reply("open", "open")
    assert(opened.error_code == "" and opened.mount == "")
    local committed = assert(checkpoints:receive())
    assert(committed:from() == host)
    local data: unknown = committed:payload():data()
    if type(data) ~= "table" or data.workspace_id ~= workspace_id then error("Foreign checkpoint") end
    local record = recovery.record(data.record)
    assert(record and record.instance_id == opened.instance_id)
    request("attach", "bind", owner)
    local mounted = reply("attach", "attached")
    local view, view_error = tty.attach(mounted.mount)
    if not view then error(tostring(view_error)) end
    assert(reply("attach", "bind").error_code == "")
    local frame = assert(view:snapshot())
    assert(table.concat(frame.rows):find("SAVED ", 1, true), "Host did not acknowledge committed checkpoint")
    request("detach", "bind")
    assert(reply("detach", "bind").error_code == "")
    local stale, denied = view:snapshot()
    assert(not stale and denied)
    view:close()
    stop("stop-first")
    local previous_workspace = workspace_id
    host, workspace_id = start(1)
    assert(workspace_id == previous_workspace)
    local restored_message = assert(restores:receive())
    assert(restored_message:from() == host)
    local restored = decode.reply(restored_message:payload():data())
    assert(restored and restored.error_code == "" and restored.id == opened.id and restored.instance_id == opened.instance_id)
    stop("stop-second")
    for _, subscription in ipairs({ready, replies, checkpoints, restores, guest_sent}) do process.unlisten(subscription) end
end

-- Restart with a manual checkpoint whose transfer was prepared by the prior
-- host. The second client restores the exact identity through its ordinary
-- open route, so its initial assignment-fenced bind proves settlement happened
-- before the reply became usable. A separate checkpoint-absent assignment
-- verifies startup does not retain dead rows forever.
function M.manual()
    local owner = tostring(process.pid())
    local ready = assert(process.listen("bee.host.ready", {message = true}))
    local replies = assert(process.listen("bee.app.reply", {message = true}))
    local checkpoints = assert(process.listen("bee.host.checkpoint", {message = true}))
    local results = assert(process.listen("bee.host.client_result", {message = true}))
    local statuses = assert(process.listen("bee.client.status", {message = true}))
    local events = assert(process.events())
    local policies: {security.Policy} = {}
    for _, name in ipairs({"bee:host_policy", "bee:host_spawn_policy", "bee:workspace_storage_policy"}) do
        local policy, err = security.policy(name)
        if not policy then error(tostring(err)) end
        policies[#policies + 1] = policy
    end
    local host_scope = security.new_scope(policies)
    local function start(expected_records: integer): (string, string)
        local host = tostring(assert(process.with_options({}):with_scope(host_scope):with_context({["bee.host_owner"] = owner})
            :spawn_monitored("bee.host:main", "bee:workers", owner, {root_ref = "bee:workspace_root", subpath = ""})))
        local message = assert(ready:receive())
        assert(message:from() == host)
        local data: unknown = message:payload():data()
        if type(data) ~= "table" or type(data.saved) ~= "table" or type(data.saved.applications) ~= "table"
            or #data.saved.applications ~= expected_records then error("Invalid manual host readiness") end
        local workspace_id = contract.workspace_id(data.workspace_id)
        if not workspace_id then error("Missing manual workspace identity") end
        return host, workspace_id
    end
    local host, workspace_id = start(0)
    local function reply(id: string, op: string): decode.Reply
        while true do
            local message = assert(replies:receive())
            assert(message:from() == host)
            local value = decode.reply(message:payload():data())
            if not value then error("Invalid manual host reply") end
            if value.request_id == id and value.op == op then return value end
        end
        error("Manual reply channel closed")
    end
    local function stop(id: string)
        assert(process.send(host, "bee.app.request", {version = 1, request_id = id, op = "shutdown", workspace_id = workspace_id}))
        assert(reply(id, "shutdown").error_code == "")
        while true do
            local event = assert(events:receive())
            if event.kind == process.event.EXIT and tostring(event.from) == host then return end
        end
    end
    assert(process.send(host, "bee.app.request", {version = 1, request_id = "manual-open", op = "open", workspace_id = workspace_id,
        definition_id = "bee.attachment_probe:app"}))
    local opened = reply("manual-open", "open")
    assert(opened.error_code == "")
    local checkpoint = assert(checkpoints:receive())
    assert(checkpoint:from() == host)
    local checkpoint_data: unknown = checkpoint:payload():data()
    if type(checkpoint_data) ~= "table" then error("Invalid manual checkpoint") end
    local record = recovery.record(checkpoint_data.record)
    if not record or record.id ~= opened.id or record.instance_id ~= opened.instance_id then error("Manual checkpoint identity changed") end
    stop("manual-stop-first")

    local database = assert(persistence.open(nil, {root_ref = "bee:workspace_root", subpath = ""}))
    local manual_record: recovery.Record = {id = record.id, instance_id = record.instance_id, definition_id = record.definition_id,
        thread_id = record.thread_id, resume_schema = record.resume_schema, restart_policy = "manual", resume_state = record.resume_state,
        window = record.window}
    assert(database:write({version = 1, desktop = {scene = model.new(80, 24), tabs = {}, preferences = appearance.defaults()},
        applications = {manual_record}}))
    assert(database.assignments:claim({view_id = opened.id, instance_id = opened.instance_id, display_id = string.rep("a", 32)}))
    assert(database.assignments:prepare({request_id = "manual-recovered-transfer", view_id = opened.id, instance_id = opened.instance_id,
        source_display_id = string.rep("a", 32), target_display_id = string.rep("b", 32), expected_revision = 1}))
    assert(database.assignments:claim({view_id = "lost-view", instance_id = "lost-instance", display_id = string.rep("a", 32)}))
    assert(database:close())

    host, workspace_id = start(1)
    database = assert(persistence.open(nil, {root_ref = "bee:workspace_root", subpath = ""}))
    local fenced = assert(database.assignments:get({view_id = opened.id, instance_id = opened.instance_id}))
    assert(fenced.intent and fenced.intent.request_id == "manual-recovered-transfer", "Manual checkpoint settled before restore")
    assert(database.assignments:get({view_id = "lost-view", instance_id = "lost-instance"}) == nil,
        "Checkpoint-absent assignment survived host restart")
    assert(database:close())

    local client_policy = assert(security.policy("bee.attachment_probe:client_policy"))
    local source = tostring(assert(process.with_options({}):with_scope(security.new_scope({client_policy}))
        :spawn_monitored("bee.attachment_probe:client", "bee:workers", owner, host, workspace_id, "A", false, "bee.attachment_probe:app", true)))
    local source_ready = assert(statuses:receive())
    local source_ready_data: unknown = source_ready:payload():data()
    assert(source_ready:from() == source and type(source_ready_data) == "table" and source_ready_data.phase == "ready")
    assert(process.send(host, "bee.host.client", {version = 1, request_id = "manual-source-admit", op = "admit", workspace_id = workspace_id,
        recipient = source, display_id = string.rep("a", 32), permissions = {open = true, close = false, control = true}}))
    local source_admitted = assert(results:receive())
    local source_admitted_data: unknown = source_admitted:payload():data()
    assert(source_admitted:from() == host and type(source_admitted_data) == "table" and source_admitted_data.request_id == "manual-source-admit"
        and source_admitted_data.error_code == "")
    local preflight = assert(statuses:receive())
    local preflight_data: unknown = preflight:payload():data()
    assert(preflight:from() == source and type(preflight_data) == "table" and preflight_data.phase == "preflight")
    assert(process.send(source, "bee.client.command", {id = opened.id, instance_id = opened.instance_id}))
    local fenced_bind = assert(statuses:receive())
    local fenced_bind_data: unknown = fenced_bind:payload():data()
    assert(fenced_bind:from() == source and type(fenced_bind_data) == "table" and fenced_bind_data.phase == "prepared-bind")
    assert(process.send(source, "bee.client.command", "exit"))
    local client = tostring(assert(process.with_options({}):with_scope(security.new_scope({client_policy}))
        :spawn_monitored("bee.attachment_probe:client", "bee:workers", owner, host, workspace_id, "B", false, "bee.attachment_probe:app")))
    local ready_client = assert(statuses:receive())
    local ready_data: unknown = ready_client:payload():data()
    assert(ready_client:from() == client and type(ready_data) == "table" and ready_data.phase == "ready")
    assert(process.send(host, "bee.host.client", {version = 1, request_id = "manual-admit", op = "admit", workspace_id = workspace_id,
        recipient = client, display_id = string.rep("b", 32), permissions = {open = true, close = false, control = true}}))
    while true do
        local admitted = assert(results:receive())
        local admitted_data: unknown = admitted:payload():data()
        assert(admitted:from() == host and type(admitted_data) == "table")
        if admitted_data.request_id == "manual-admit" then
            assert(admitted_data.error_code == "")
            break
        end
    end
    local restored = assert(statuses:receive())
    assert(restored:from() == client)
    local restored_data: unknown = restored:payload():data()
    if type(restored_data) ~= "table" or restored_data.phase ~= "opened" or type(restored_data.view) ~= "table"
        or restored_data.view.id ~= opened.id or restored_data.view.instance_id ~= opened.instance_id then
        error("Manual restore did not bind the exact prepared identity on its target display")
    end
    database = assert(persistence.open(nil, {root_ref = "bee:workspace_root", subpath = ""}))
    local settled = assert(database.assignments:get({view_id = opened.id, instance_id = opened.instance_id}))
    local receipt = assert(database.assignments:receipt("manual-recovered-transfer"))
    assert(settled.assignment.display_id == string.rep("b", 32) and settled.assignment.revision == 2 and not settled.intent
        and receipt.phase == "committed", "Manual restore did not commit its target assignment")
    assert(database:close())
    assert(process.send(client, "bee.client.command", "exit"))
    stop("manual-stop-second")
    for _, subscription in ipairs({ready, replies, checkpoints, results, statuses}) do process.unlisten(subscription) end
end
return M
