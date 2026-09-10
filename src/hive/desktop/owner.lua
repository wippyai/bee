-- MIT. Hive-supervisor-local bridge to the retained desktop owner. Native
-- sender identity is native; only this local owner requests core grants.
local process = require("process")
local security = require("security")
local channel = require("channel")
local time = require("time")
local uuid = require("uuid")
local types = require("types")
local protocol = require("protocol")
local retained = require("retained")
local M = {}
type Channel = channel.Channel
type Session = {id: string, mount: string, mode: "control" | "observe"}
type Pending = {id: string, op: "attach" | "detach" | "copy" | "launch", call: types.Call?, cache_key: string?, digest: string?, due: integer}
type Client = {recipient: string, session: Session?, pending: Pending?, closing: boolean, dirty: boolean}
type Receipt = {session_id: string?, digest: string, reply: types.Reply, expires: integer}
type State = {
    config: protocol.Configuration, node: string, supervisor: string,
    ready: Channel<process.Message>, results: Channel<process.Message>, copies: Channel<process.Message>, launches: Channel<process.Message>,
    workspace_id: string, desktop_id: string, allowed: {[string]: boolean},
    clients: {[string]: Client}, receipts: {[string]: Receipt}, client_count: integer, receipt_count: integer,
    expires_at: time.Time, stopped: boolean,
}
local FORMAT = "2006-01-02T15:04:05.000Z07:00"
local function listen(topic: string): Channel<process.Message>
    local value, err = process.listen(topic, {message = true})
    if not value then error(tostring(err)) end
    return value
end
local function send(recipient: string, topic: string, value: unknown): boolean
    local sent, err = process.send(recipient, topic, value)
    return sent == true and err == nil
end
local function failure(recipient: string, id: string, code: string, message: string)
    send(recipient, types.TOPIC_REPLY, types.reply_error(id, types.fault(code, message)))
end
-- Configuration is an explicit host grant to selected native nodes, not an
-- inference from transport authentication, discovery, metadata or a PID prefix.
function M.start(config: protocol.Configuration, node: string): State
    if not security.can("bee.desktop.host", "bee.desktop") then error("Host did not authorize desktop admission") end
    local expiry = time.parse(FORMAT, config.expires_at)
    if not expiry or not time.now():before(expiry) then error("Desktop owner execution expired") end
    local allowed: {[string]: boolean} = {}
    for _, peer in ipairs(config.allowed_nodes) do
        if peer == node then error("Native desktop client must have its own node identity") end
        allowed[peer] = true
    end
    local ready = listen("bee.retained.ready")
    local results = listen("bee.retained.result")
    local copies = listen("bee.retained.copied")
    local launches = listen("bee.retained.launched")
    local policies: {security.Policy} = {}
    for _, name in ipairs({"bee:host_policy", "bee:desktop_policy", "bee:retained_supervisor_spawn_policy"}) do
        local policy, err = security.policy(name)
        if not policy then process.unlisten(ready); process.unlisten(results); process.unlisten(copies); process.unlisten(launches); error(tostring(err)) end
        policies[#policies + 1] = policy
    end
    local self = tostring(process.pid())
    local owner, err = process.with_options({}):with_context({["bee.retained_owner"] = self})
        :with_scope(security.new_scope(policies)):spawn_monitored("bee.launch:retained", "bee:workers", self, config.application)
    if not owner then process.unlisten(ready); process.unlisten(results); process.unlisten(copies); process.unlisten(launches); error(tostring(err)) end
    local clients: {[string]: Client} = {}
    local receipts: {[string]: Receipt} = {}
    return {config = config, node = node, supervisor = tostring(owner), ready = ready, results = results, copies = copies, launches = launches,
        workspace_id = "", desktop_id = "", allowed = allowed, clients = clients, receipts = receipts,
        client_count = 0, receipt_count = 0, expires_at = expiry, stopped = false}
end
local function forget(state: State, recipient: string)
    if state.clients[recipient] then
        process.unmonitor(recipient)
        state.clients[recipient] = nil
        state.client_count = state.client_count - 1
    end
end
local function request_core(state: State, client: Client, pending: Pending, mode: string?): boolean
    if pending.op == "launch" then
        local input = pending.call and protocol.input(protocol.LAUNCH, pending.call.input) or nil
        if not input or not input.name or not input.arguments then return false end
        return send(state.supervisor, "bee.retained.launch", {version = 1, workspace_id = state.workspace_id,
            desktop_id = state.desktop_id, request_id = pending.id, recipient = client.recipient,
            name = input.name, arguments = input.arguments})
    end
    return send(state.supervisor, "bee.retained.request", {version = 1, workspace_id = state.workspace_id,
        desktop_id = state.desktop_id, request_id = pending.id, recipient = client.recipient, op = pending.op, mode = mode})
end
local function revoke(state: State, client: Client, now: integer)
    client.closing = true
    if client.pending then return end
    if not client.dirty then forget(state, client.recipient); return end
    local pending: Pending = {id = uuid.v7(), op = "detach", due = now + 1000}
    client.pending = pending
    request_core(state, client, pending, nil)
end
local function remember(state: State, client: Client, pending: Pending, reply: types.Reply, now: integer)
    if pending.cache_key and pending.digest then
        -- Receipts cover the request's declared deadline. Expired requests are
        -- refused; no durable exactly-once claim is made for native sessions.
        state.receipts[pending.cache_key] = {session_id = client.session and client.session.id or nil, digest = pending.digest, reply = reply, expires = pending.due}
    end
    if not client.closing and now < pending.due then
        send(client.recipient, types.TOPIC_REPLY, reply)
    end
end
function M.ready(state: State, message: process.Message)
    if tostring(message:from()) ~= state.supervisor or state.stopped then return end
    local value = retained.ready(message:payload():data())
    if not value then error("Invalid retained desktop readiness") end
    if state.workspace_id ~= "" and (state.workspace_id ~= value.workspace_id or state.desktop_id ~= value.desktop_id) then
        error("Retained desktop identity changed within an execution")
    end
    state.workspace_id, state.desktop_id = value.workspace_id, value.desktop_id
end
-- Only a native sender from an explicitly admitted client node enters
-- this route. Unknown clients continue to the ordinary supervisor refusal path.
local function allowed_client(state: State, sender: string): boolean
    local node, host = types.pid_parts(sender)
    if not node or host ~= protocol.CLIENT_HOST then return false end
    if state.allowed[node] == true then return true end
    return state.config.local_clients == true and security.can("bee.desktop.local_client", sender)
end
function M.handles(state: State, message: process.Message): boolean
    return allowed_client(state, tostring(message:from()))
end
function M.request(state: State, message: process.Message, now: integer)
    local sender = tostring(message:from())
    if not allowed_client(state, sender) then return end
    local call = types.decode_call(message:payload():data())
    if not call then return end
    if state.stopped or not time.now():before(state.expires_at) then failure(sender, call.request_id, "UNAVAILABLE", "Desktop owner stopped"); return end
    local operation = call.target.operation_ref
    if not operation or call.target.interface_ref or call.owner_ref.node_id ~= state.node
        or call.owner_ref.service_id ~= protocol.SERVICE or call.owner_ref.resource_ref then
        failure(sender, call.request_id, "DENIED", "Native desktop client cannot use this owner or operation"); return
    end
    local input = protocol.input(operation, call.input)
    if not input then failure(sender, call.request_id, "INVALID_ARGUMENT", "Invalid desktop operation input"); return end
    if input.execution ~= state.config.execution then failure(sender, call.request_id, "DENIED", "Owner execution changed"); return end
    local deadline = call.deadline and time.parse(FORMAT, call.deadline)
    local wall = time.now()
    local remaining = deadline and math.floor(deadline:sub(wall):milliseconds()) or 0
    if not deadline then failure(sender, call.request_id, "INVALID_ARGUMENT", "A valid desktop call deadline is required"); return end
    if remaining <= 0 then failure(sender, call.request_id, "DEADLINE_EXCEEDED", "Desktop call deadline has passed"); return end
    -- Bound work on the owner, as ordinary supervisor admission does. A caller's
    -- thirty-second deadline can be slightly ahead of this machine's clock.
    if remaining > 30000 then remaining = 30000 end
    if state.workspace_id == "" then failure(sender, call.request_id, "UNAVAILABLE", "Desktop is starting"); return end
    if operation == protocol.LIST then
        send(sender, types.TOPIC_REPLY, types.reply_ok(call.request_id, {owner_execution = state.config.execution,
            workspaces = {{workspace_id = state.workspace_id, desktops = {{desktop_id = state.desktop_id}}}}}))
        return
    end
    if input.workspace_id ~= state.workspace_id or input.desktop_id ~= state.desktop_id then
        failure(sender, call.request_id, "NOT_FOUND", "Selected desktop does not belong to this owner"); return
    end
    local key = sender .. "\0" .. call.idempotency_key
    local digest = types.digest({operation = operation, input = call.input, deadline = call.deadline})
    if not digest then failure(sender, call.request_id, "INVALID_ARGUMENT", "Unmeasurable desktop request"); return end
    local receipt = state.receipts[key]
    if receipt then
        if receipt.digest ~= digest then
            failure(sender, call.request_id, "CONFLICT", "Idempotency key is already used by another request"); return
        end
        if now >= receipt.expires then failure(sender, call.request_id, "DEADLINE_EXCEEDED", "Request receipt expired"); return end
        if receipt.session_id then
            local current = state.clients[sender]
            if not current or current.closing or not current.session or current.session.id ~= receipt.session_id then
                failure(sender, call.request_id, "NOT_FOUND", "Desktop session was retired"); return
            end
        end
        local reply = receipt.reply.ok and types.reply_ok(call.request_id, receipt.reply.value)
            or types.reply_error(call.request_id, receipt.reply.error or types.fault("INTERNAL", "Missing receipt error"))
        send(sender, types.TOPIC_REPLY, reply); return
    end
    local client = state.clients[sender]
    if client and client.pending then
        local pending = client.pending
        if pending.cache_key == key then
            if pending.digest ~= digest then
                failure(sender, call.request_id, "CONFLICT", "Idempotency key is already used by another request"); return
            end
            -- Only the original correlation receives the eventual completion.
            -- A retry with a fresh correlation must get an explicit answer;
            -- silently dropping it would leave its caller waiting forever.
            if pending.call and pending.call.request_id == call.request_id then return end
        end
        failure(sender, call.request_id, "BUSY", "Desktop request already pending"); return
    end
    if client and client.closing then failure(sender, call.request_id, "UNAVAILABLE", "Desktop session is closing"); return end
    if state.receipt_count >= 256 then failure(sender, call.request_id, "BUSY", "Desktop receipt capacity reached"); return end
    if not client then
        if operation ~= protocol.ATTACH then failure(sender, call.request_id, "NOT_FOUND", "Desktop session not found"); return end
        if state.client_count >= 64 then failure(sender, call.request_id, "BUSY", "Desktop client capacity reached"); return end
        local monitored, monitor_error = process.monitor(sender)
        if not monitored or monitor_error then
            failure(sender, call.request_id, "UNAVAILABLE", "Desktop client lifetime could not be monitored"); return
        end
        client = {recipient = sender, closing = false, dirty = false}
        state.clients[sender] = client; state.client_count = state.client_count + 1
    end
    if operation ~= protocol.ATTACH and (not client.session or client.session.id ~= input.session_id) then
        failure(sender, call.request_id, "DENIED", "Desktop session does not match"); return
    end
    if (operation == protocol.COPY or operation == protocol.LAUNCH) and (not client.session or client.session.mode ~= "control") then
        failure(sender, call.request_id, "DENIED", "Operation requires the active desktop controller"); return
    end
    local pending: Pending = {id = uuid.v7(), op = operation == protocol.ATTACH and "attach" or (operation == protocol.COPY and "copy" or (operation == protocol.LAUNCH and "launch" or "detach")),
        call = call, cache_key = key, digest = digest, due = now + remaining}
    state.receipt_count = state.receipt_count + 1
    client.pending = pending
    if operation == protocol.ATTACH and client.session then
        if client.session.mode ~= input.mode then
            local reply = types.reply_error(call.request_id, types.fault("CONFLICT", "Detach before changing session mode"))
            remember(state, client, pending, reply, now)
        else
            remember(state, client, pending, types.reply_ok(call.request_id, {owner_execution = state.config.execution,
                workspace_id = state.workspace_id, desktop_id = state.desktop_id, session_id = client.session.id,
                recipient = sender, mode = client.session.mode, mount_ref = client.session.mount, expires_at = state.config.expires_at}), now)
        end
        client.pending = nil; return
    end
    if not request_core(state, client, pending, pending.op == "attach" and input.mode or nil) then
        remember(state, client, pending, types.reply_error(call.request_id, types.fault("UNAVAILABLE", "Retained owner did not accept the request")), now)
        client.pending = nil
        if not client.session then forget(state, sender) end
    elseif pending.op == "attach" then client.dirty = true end
end
function M.launched(state: State, message: process.Message, now: integer)
    if tostring(message:from()) ~= state.supervisor or state.stopped then return end
    local result = retained.launch_result(message:payload():data(), state.workspace_id, state.desktop_id)
    if not result then return end
    for _, client in pairs(state.clients) do
        local pending = client.pending
        if pending and pending.op == "launch" and pending.id == result.request_id and pending.call then
            local session = client.session
            if not session then return end
            local reply: types.Reply
            if result.error_code ~= "" then
                local code = "UNAVAILABLE"
                if result.error_code == "DENIED" or result.error_code == "BUSY" or result.error_code == "INVALID_ARGUMENT" then code = result.error_code end
                reply = types.reply_error(pending.call.request_id, types.fault(code, result.error))
            else
                reply = types.reply_ok(pending.call.request_id, {owner_execution = state.config.execution,
                    workspace_id = state.workspace_id, desktop_id = state.desktop_id, session_id = session.id,
                    id = result.id, instance_id = result.instance_id})
            end
            remember(state, client, pending, reply, now)
            client.pending = nil
            if client.closing then revoke(state, client, now) end
            return
        end
    end
end
function M.copied(state: State, message: process.Message, now: integer)
    if tostring(message:from()) ~= state.supervisor or state.stopped then return end
    local result = retained.copy_result(message:payload():data())
    if not result then return end
    for _, client in pairs(state.clients) do
        local pending = client.pending
        if pending and pending.op == "copy" and pending.id == result.request_id and pending.call then
            local session = client.session
            if not session or client.closing then return end
            local reply: types.Reply
            if result.error ~= "" then reply = types.reply_error(pending.call.request_id, types.fault(result.selected and "INVALID_STATE" or "UNAVAILABLE", result.error))
            else reply = types.reply_ok(pending.call.request_id, {owner_execution = state.config.execution,
                workspace_id = state.workspace_id, desktop_id = state.desktop_id, session_id = session.id,
                selected = result.selected, text = result.text}) end
            remember(state, client, pending, reply, now)
            client.pending = nil
            return
        end
    end
end
function M.result(state: State, message: process.Message, now: integer)
    if tostring(message:from()) ~= state.supervisor or state.stopped then return end
    local result = retained.result(message:payload():data(), state.workspace_id, state.desktop_id)
    if not result then error("Invalid retained desktop result") end
    for _, client in pairs(state.clients) do
        local pending = client.pending
        if pending and pending.id == result.request_id then
            if result.error_code == "" then
                if pending.op == "attach" then
                    if result.mount == "" then error("Retained attach returned no mount") end
                    local mode: "control" | "observe" = "observe"
                    if pending.call then
                        local input = protocol.input(protocol.ATTACH, pending.call.input)
                        if not input then error("Invalid admitted desktop input") end
                        mode = input.mode
                    end
                    client.session = {id = uuid.v7(), mount = result.mount, mode = mode}
                else client.session = nil; client.dirty = false end
            end
            if pending.call then
                local reply: types.Reply
                if result.error_code ~= "" then reply = types.reply_error(pending.call.request_id, types.fault("UNAVAILABLE", result.error))
                elseif client.session then
                    reply = types.reply_ok(pending.call.request_id, {owner_execution = state.config.execution,
                        workspace_id = state.workspace_id, desktop_id = state.desktop_id, session_id = client.session.id,
                        recipient = client.recipient, mode = client.session.mode, mount_ref = client.session.mount, expires_at = state.config.expires_at})
                else reply = types.reply_ok(pending.call.request_id, {owner_execution = state.config.execution,
                    workspace_id = state.workspace_id, desktop_id = state.desktop_id, detached = true}) end
                remember(state, client, pending, reply, now)
            end
            client.pending = nil
            if result.error_code ~= "" then
                client.closing = true
                if pending.op == "detach" then
                    -- Retry a failed revocation on the timer, not a tight
                    -- request/reply loop. Its completion remains unknown.
                    client.pending = {id = uuid.v7(), op = "detach", due = now + 1000}
                    return
                end
            end
            if client.closing or now >= pending.due then revoke(state, client, now)
            elseif not client.session then forget(state, client.recipient) end
            return
        end
    end
end
function M.tick(state: State, now: integer)
    if not time.now():before(state.expires_at) then error("Desktop owner execution expired") end
    for key, receipt in pairs(state.receipts) do
        if now >= receipt.expires then
            state.receipts[key] = nil; state.receipt_count = state.receipt_count - 1
        end
    end
    for _, client in pairs(state.clients) do
        local pending = client.pending
        if pending and now >= pending.due then
            if pending.call then
                if not client.closing then
                    send(client.recipient, types.TOPIC_REPLY, types.reply_error(pending.call.request_id,
                        types.uncertain("Desktop operation may have completed", {operation_ref = pending.call.target.operation_ref or "", idempotency_key = pending.call.idempotency_key})))
                end
                pending.call = nil
                client.closing = true
            end
            if pending.cache_key then
                state.receipt_count = state.receipt_count - 1
            end
            -- Every detach attempt has a fresh correlation ID. A late attach
            -- acknowledgement must never be mistaken for completed revocation.
            local cleanup: Pending = {id = uuid.v7(), op = "detach", due = now + 1000}
            client.pending = cleanup
            request_core(state, client, cleanup, nil)
        end
    end
end
function M.event(state: State, event: process.Event, now: integer)
    if event.kind ~= process.event.EXIT and event.kind ~= process.event.LINK_DOWN then return end
    local sender = tostring(event.from)
    if sender == state.supervisor and event.kind == process.event.EXIT then
        state.stopped = true
        error("Retained desktop owner exited")
    end
    -- Revoking this attachment is our authority, even when the remote actor's
    -- outcome is unknown. This does not declare that actor or its apps exited.
    local client = state.clients[sender]
    if client then revoke(state, client, now) end
end
function M.close(state: State)
    state.stopped = true
    process.unlisten(state.ready); process.unlisten(state.results); process.unlisten(state.copies); process.unlisten(state.launches)
    for recipient in pairs(state.clients) do process.unmonitor(recipient) end
    process.terminate(state.supervisor)
end
return M
