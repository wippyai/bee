-- MIT. Hive-supervisor-local bridge to the retained desktop supervisors of the
-- node's workspaces. Native sender identity is native; only this local owner
-- requests core grants. The owner's folder workspace keeps its supervisor for
-- the bridge's lifetime; any other workspace gets one when a client attaches
-- to it, and that supervisor holds a lease on the workspace's host until the
-- workspace's last session ends.
local process = require("process")
local security = require("security")
local channel = require("channel")
local time = require("time")
local uuid = require("uuid")
local funcs = require("funcs")
local types = require("types")
local protocol = require("protocol")
local retained = require("retained")
local catalog = require("catalog")
local workspaces = require("workspaces")
local M = {}
type Channel = channel.Channel
type Session = {id: string, mount: string, mode: "control" | "observe"}
-- waiting: the request waits for its workspace's supervisor to be ready.
type Pending = {id: string, op: "attach" | "detach" | "copy" | "launch", call: types.Call?, cache_key: string?, digest: string?, due: integer,
    activating: boolean?, waiting: boolean?}
type Client = {recipient: string, workspace_id: string, desktop_id: string, session: Session?, pending: Pending?, closing: boolean, dirty: boolean}
type Receipt = {session_id: string?, digest: string, reply: types.Reply, expires: integer}
-- One retained desktop supervisor. The folder workspace learns its identity
-- from readiness; a leased workspace is selected by identity.
type Served = {supervisor: string, workspace_id: string, desktop_id: string, folder: boolean, ready: boolean,
    catalog_readers: {[string]: boolean}, pending_catalog_readers: retained.CatalogReaders?}
type State = {
    config: protocol.Configuration, node: string, bridge_name: string, owner_name: string,
    ready: Channel<process.Message>, results: Channel<process.Message>, copies: Channel<process.Message>, launches: Channel<process.Message>,
    activations: Channel<process.Message>, reader_updates: Channel<process.Message>,
    observers: Channel<process.Message>, catalog: catalog.State, spawn_scope: security.Scope, executor: funcs.Executor,
    folder: Served?, served: {[string]: Served}, workspaces: {[string]: Served}, served_count: integer,
    allowed: {[string]: boolean}, enrolled: {[string]: boolean},
    clients: {[string]: Client}, receipts: {[string]: Receipt}, client_count: integer, receipt_count: integer,
    expires_at: time.Time, stopped: boolean,
}
local FORMAT = "2006-01-02T15:04:05.000Z07:00"
-- Leased workspaces one bridge serves at once, besides the folder workspace.
M.MAX_SERVED = 32
M.READER_OPERATION = "bee.desktop:catalog"
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
local function scope_of(names: {string}): (security.Scope?, string?)
    local policies: {security.Policy} = {}
    for _, name in ipairs(names) do
        local policy, err = security.policy(name)
        if not policy then return nil, tostring(err) end
        policies[#policies + 1] = policy
    end
    return security.new_scope(policies), nil
end
local SPAWN_POLICIES = {"bee:host_policy", "bee:desktop_policy", "bee:retained_supervisor_spawn_policy", "bee:desktop_catalog_policy",
    "bee:desktop_catalog_resource_policy", "bee:workspace_host_lease_policy"}
local CATALOG_POLICIES = {"bee:desktop_catalog_policy", "bee:desktop_catalog_resource_policy", "bee:workspace_catalog_read_policy",
    "bee.hive.desktop:catalog_call_policy"}
local function spawn(state: State, selection: unknown): (string?, string?)
    local self = tostring(process.pid())
    local pid, err = process.with_options({}):with_context({["bee.retained_owner"] = self})
        :with_scope(state.spawn_scope):spawn_monitored("bee.launch:retained", "bee:workers", self, selection, state.config.application)
    if not pid then return nil, tostring(err) end
    return tostring(pid), nil
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
    local activations = listen("bee.retained.activated")
    local reader_updates = listen("bee.retained.catalog_readers")
    local observers = listen(retained.TOPIC_OBSERVE)
    local named = false
    -- The bridge composes the owner's folder workspace.
    local folder = workspaces.classic()
    local key = workspaces.key(folder)
    local bridge_name = key and retained.bridge_name(key) or ""
    local owner_name = key and retained.owner_name(key) or ""
    local function abandon(cause: unknown)
        for _, topic in ipairs({ready, results, copies, launches, activations, reader_updates, observers}) do process.unlisten(topic) end
        if named then process.registry.unregister(bridge_name) end
        error(tostring(cause))
    end
    if bridge_name == "" or owner_name == "" then abandon("Invalid retained workspace selection") end
    local spawn_scope, spawn_error = scope_of(SPAWN_POLICIES)
    if not spawn_scope then abandon(spawn_error) end
    local catalog_scope, catalog_error = scope_of(CATALOG_POLICIES)
    if not catalog_scope then abandon(catalog_error) end
    local executor, executor_error = funcs.new():with_scope(catalog_scope)
    if not executor then abandon(executor_error) end
    -- The owner route authenticates forwarded readiness by this name, so it is
    -- registered before the retained supervisor can announce anything.
    local registered, name_error = process.registry.register(bridge_name)
    if not registered then abandon(name_error) end
    named = true
    local state: State = {config = config, node = node, bridge_name = bridge_name, owner_name = owner_name, ready = ready, results = results,
        copies = copies, launches = launches, activations = activations, reader_updates = reader_updates, observers = observers,
        catalog = catalog.new(), spawn_scope = spawn_scope, executor = executor, folder = nil, served = {}, workspaces = {}, served_count = 0,
        allowed = allowed, enrolled = {}, clients = {}, receipts = {}, client_count = 0, receipt_count = 0, expires_at = expiry, stopped = false}
    local supervisor, err = spawn(state, folder)
    if not supervisor then abandon(err) end
    local served: Served = {supervisor = supervisor, workspace_id = "", desktop_id = "", folder = true, ready = false, catalog_readers = {}}
    state.folder = served
    state.served[supervisor] = served
    return state
end
local function forget(state: State, recipient: string)
    local client = state.clients[recipient]
    if not client then return end
    process.unmonitor(recipient)
    state.clients[recipient] = nil
    state.client_count = state.client_count - 1
    -- A leased workspace whose last session ended releases its host lease.
    local served = state.workspaces[client.workspace_id]
    if not served or served.folder then return end
    for _, other in pairs(state.clients) do
        if other.workspace_id == client.workspace_id then return end
    end
    state.workspaces[client.workspace_id] = nil
    state.served[served.supervisor] = nil
    state.served_count = state.served_count - 1
    -- Its exit event arrives for a supervisor no longer served and is ignored.
    process.terminate(served.supervisor)
end
local function request_core(state: State, client: Client, pending: Pending, mode: string?): boolean
    local served = state.workspaces[client.workspace_id]
    if not served then return false end
    if not served.ready then
        pending.waiting = true
        pending.activating = pending.activating
        return true
    end
    pending.waiting = false
    if pending.activating then
        return send(served.supervisor, "bee.retained.activate", {version = 1, workspace_id = served.workspace_id,
            desktop_id = client.desktop_id, request_id = pending.id})
    end
    if pending.op == "launch" then
        local input = pending.call and protocol.input(protocol.LAUNCH, pending.call.input) or nil
        if not input or not input.name or not input.arguments then return false end
        return send(served.supervisor, "bee.retained.launch", {version = 1, workspace_id = served.workspace_id,
            desktop_id = client.desktop_id, request_id = pending.id, recipient = client.recipient,
            name = input.name, arguments = input.arguments})
    end
    return send(served.supervisor, "bee.retained.request", {version = 1, workspace_id = served.workspace_id,
        desktop_id = client.desktop_id, request_id = pending.id, recipient = client.recipient, op = pending.op, mode = mode})
end
local function revoke(state: State, client: Client, now: integer)
    client.closing = true
    if client.pending then return end
    if not client.dirty then forget(state, client.recipient); return end
    local pending: Pending = {id = uuid.v7(), op = "detach", due = now + 1000}
    client.pending = pending
    if not request_core(state, client, pending, nil) then forget(state, client.recipient) end
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

-- A refused first attachment has no session to reconcile. Keeping a receipt
-- for every fresh controller refusal would let a waiting client consume the
-- bounded receipt cache without acquiring anything. Such a refusal is a
-- definite no-effect result, so it is deliberately not retained.
local function forget_refusal(state: State, pending: Pending)
    if pending.cache_key and state.receipts[pending.cache_key] then
        state.receipts[pending.cache_key] = nil
        state.receipt_count = state.receipt_count - 1
    end
end
local function install_catalog_readers(served: Served, snapshot: retained.CatalogReaders)
    if snapshot.workspace_id ~= served.workspace_id then error("Catalog reader workspace changed") end
    -- `state.node` is the Hive routing identity. A local-only supervisor maps
    -- its node-less native PID to "local", so it cannot establish transport
    -- locality. Compare against the exact retained supervisor's native node;
    -- this also does not conflate a real native node named "local" with the
    -- local-only marker.
    local supervisor_node = types.pid_parts(served.supervisor)
    if supervisor_node == nil then error("Retained catalog reader supervisor has no native PID") end
    local readers: {[string]: boolean} = {}
    for _, reader in ipairs(snapshot.readers) do
        local reader_node = types.pid_parts(reader)
        if reader_node ~= supervisor_node then error("Catalog reader is not local to this owner") end
        readers[reader] = true
    end
    served.catalog_readers = readers
    served.pending_catalog_readers = nil
end
-- announce forwards the folder workspace's readiness to the owner route
-- registered under its retained owner name. With a recipient, it answers only
-- when that recipient is the registered owner route. Either side may register
-- first: the bridge announces when readiness arrives and the owner route
-- observes once its name exists, so one of the two always finds the other.
local function announce(state: State, recipient: string?)
    local folder = state.folder
    if state.stopped or not folder or not folder.ready then return end
    local route = process.registry.lookup(state.owner_name)
    if not route then return end
    local owner_route = tostring(route)
    if recipient and recipient ~= owner_route then return end
    send(owner_route, "bee.retained.ready", {version = 1, workspace_id = folder.workspace_id, desktop_id = folder.desktop_id})
end
-- The folder workspace's identity once its supervisor is ready.
function M.folder_workspace(state: State): string?
    local folder = state.folder
    if folder and folder.ready then return folder.workspace_id end
    return nil
end
-- Whether a retained desktop supervisor serves the workspace now.
function M.serves(state: State, workspace_id: string): boolean
    local served = state.workspaces[workspace_id]
    return served ~= nil and served.ready
end
function M.ready(state: State, message: process.Message, now: integer)
    local served = state.served[tostring(message:from())]
    if not served or state.stopped then return end
    local value = retained.ready(message:payload():data())
    if not value then error("Invalid retained desktop readiness") end
    if served.ready then
        if served.workspace_id ~= value.workspace_id or served.desktop_id ~= value.desktop_id then
            error("Retained desktop identity changed within an execution")
        end
        return
    end
    if not served.folder and value.workspace_id ~= served.workspace_id then error("Leased desktop supervisor announced another workspace") end
    if served.folder then
        if state.workspaces[value.workspace_id] then error("The folder workspace is already served") end
        state.workspaces[value.workspace_id] = served
    end
    served.workspace_id, served.desktop_id, served.ready = value.workspace_id, value.desktop_id, true
    if served.pending_catalog_readers then install_catalog_readers(served, served.pending_catalog_readers) end
    if served.folder then announce(state, nil) end
    -- Requests that waited for this workspace's supervisor proceed now.
    for _, client in pairs(state.clients) do
        local pending = client.pending
        if client.workspace_id == served.workspace_id and pending and pending.waiting then
            local mode: string? = nil
            if pending.op == "attach" and pending.call then
                local input = protocol.input(protocol.ATTACH, pending.call.input)
                mode = input and input.mode or nil
            end
            if not request_core(state, client, pending, mode) then
                if pending.call then
                    remember(state, client, pending, types.reply_error(pending.call.request_id,
                        types.fault("UNAVAILABLE", "Retained owner did not accept the request")), now)
                end
                client.pending = nil
                if not client.session then forget(state, client.recipient) end
            end
        end
    end
end
-- observe answers an owner route that registered after readiness arrived.
function M.observe(state: State, message: process.Message)
    announce(state, tostring(message:from()))
end
-- This query is for the separate catalog-read bridge only. It deliberately does
-- not widen the native desktop-client admission route below.
function M.catalog_reader(state: State, sender: string): boolean
    if state.stopped then return false end
    for _, served in pairs(state.served) do
        if served.catalog_readers[sender] then return true end
    end
    return false
end
function M.catalog_readers(state: State, message: process.Message)
    local served = state.served[tostring(message:from())]
    if not served or state.stopped then return end
    local snapshot = retained.catalog_readers(message:payload():data(), served.ready and served.workspace_id or nil)
    if not snapshot then error("Invalid retained catalog reader snapshot") end
    if not served.ready then served.pending_catalog_readers = snapshot
    else install_catalog_readers(served, snapshot) end
end
-- Only a native sender from an explicitly admitted client node enters
-- this route: a node the host grant names, or, when the host selected local
-- clients, a node the host currently enrolls. Unknown clients continue to the
-- ordinary supervisor refusal path.
function M.admits(state: State, sender: string): boolean
    local node, host = types.pid_parts(sender)
    if not node or host ~= protocol.CLIENT_HOST then return false end
    if state.allowed[node] == true then return true end
    return state.config.local_clients == true and state.enrolled[node] == true
end
-- client_host reports whether a sender speaks from the native desktop client
-- host, whose admission depends on the host enrollment.
function M.client_host(message: process.Message): boolean
    local _, host = types.pid_parts(tostring(message:from()))
    return host == protocol.CLIENT_HOST
end
function M.handles(state: State, message: process.Message): boolean
    return M.admits(state, tostring(message:from()))
end
-- enroll installs the host's current local client enrollment and revokes the
-- attachments of every node that left it.
function M.enroll(state: State, nodes: {[string]: boolean}, now: integer)
    local enrolled: {[string]: boolean} = {}
    for node, present in pairs(nodes) do
        if present then enrolled[node] = true end
    end
    state.enrolled = enrolled
    for recipient, client in pairs(state.clients) do
        if not M.admits(state, recipient) then revoke(state, client, now) end
    end
end
-- The listing a catalog reply describes.
function M.listing(state: State): catalog.Listing
    return {execution = state.config.execution, default_workspace = M.folder_workspace(state),
        served = function(workspace_id: string): boolean return M.serves(state, workspace_id) end}
end
-- The channels of pending catalog work the owning loop selects on.
function M.catalog_channels(state: State): {Channel<unknown>}
    return catalog.channels(state.catalog)
end
function M.catalog_result(state: State, selected: unknown, now: integer): boolean
    if not catalog.handles(state.catalog, selected) then return false end
    -- A catalog read started for an authorized local app is rechecked against
    -- the exact current reader PID before its result can leave this owner.
    local recipient = catalog.reader_recipient(state.catalog, M.READER_OPERATION)
    if recipient and not M.catalog_reader(state, recipient) then
        catalog.revoke(state.catalog, "Catalog reader authorization was revoked")
        return true
    end
    catalog.result(state.catalog, selected, M.listing(state), now)
    return true
end
-- A leased workspace's supervisor, started when a client first attaches to it.
local function serve(state: State, workspace_id: string): (Served?, string?, string?)
    local served = state.workspaces[workspace_id]
    if served then return served, nil, nil end
    if state.served_count >= M.MAX_SERVED then return nil, "BUSY", "Served workspace capacity reached" end
    local supervisor, err = spawn(state, {workspace_id = workspace_id})
    if not supervisor then return nil, "UNAVAILABLE", "Workspace desktop could not start: " .. tostring(err) end
    local started: Served = {supervisor = supervisor, workspace_id = workspace_id, desktop_id = "", folder = false, ready = false, catalog_readers = {}}
    state.served[supervisor] = started
    state.workspaces[workspace_id] = started
    state.served_count = state.served_count + 1
    return started, nil, nil
end
function M.request(state: State, message: process.Message, now: integer)
    local sender = tostring(message:from())
    if not M.admits(state, sender) then return end
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
    if state.folder and not state.folder.ready then failure(sender, call.request_id, "UNAVAILABLE", "Desktop is starting"); return end
    if operation == protocol.LIST then
        catalog.list(state.catalog, state.executor, sender, call, input.query or {limit = protocol.MAX_PAGE}, now + remaining)
        return
    end
    if operation == protocol.CREATE then
        if not input.desktop_id or call.idempotency_key ~= input.desktop_id then
            failure(sender, call.request_id, "INVALID_ARGUMENT", "Desktop creation requires its identity as the idempotency key"); return
        end
        catalog.allocate(state.catalog, state.executor, sender, call, input.desktop_id, now + remaining)
        return
    end
    if not input.workspace_id or not input.desktop_id then failure(sender, call.request_id, "INVALID_ARGUMENT", "Invalid desktop operation input"); return end
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
    if client and (client.desktop_id ~= input.desktop_id or client.workspace_id ~= input.workspace_id) then
        failure(sender, call.request_id, "CONFLICT", "Detach the current desktop before selecting another"); return
    end
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
        local _, code, message = serve(state, input.workspace_id)
        if code then failure(sender, call.request_id, code, message or "Workspace desktop is unavailable"); return end
        local monitored, monitor_error = process.monitor(sender)
        if not monitored or monitor_error then
            failure(sender, call.request_id, "UNAVAILABLE", "Desktop client lifetime could not be monitored"); return
        end
        client = {recipient = sender, workspace_id = input.workspace_id, desktop_id = input.desktop_id, closing = false, dirty = false}
        state.clients[sender] = client; state.client_count = state.client_count + 1
    end
    if operation ~= protocol.ATTACH and (not client.session or client.session.id ~= input.session_id) then
        failure(sender, call.request_id, "DENIED", "Desktop session does not match"); return
    end
    if (operation == protocol.COPY or operation == protocol.LAUNCH) and (not client.session or client.session.mode ~= "control") then
        failure(sender, call.request_id, "DENIED", "Operation requires the active desktop controller"); return
    end
    local pending: Pending = {id = uuid.v7(), op = operation == protocol.ATTACH and "attach" or (operation == protocol.COPY and "copy" or (operation == protocol.LAUNCH and "launch" or "detach")),
        call = call, cache_key = key, digest = digest, due = now + remaining,
        activating = operation == protocol.ATTACH and input.mode == "control" and not client.session}
    state.receipt_count = state.receipt_count + 1
    client.pending = pending
    if operation == protocol.ATTACH and client.session then
        if client.session.mode ~= input.mode then
            local reply = types.reply_error(call.request_id, types.fault("CONFLICT", "Detach before changing session mode"))
            remember(state, client, pending, reply, now)
        else
            remember(state, client, pending, types.reply_ok(call.request_id, {owner_execution = state.config.execution,
                workspace_id = client.workspace_id, desktop_id = client.desktop_id, session_id = client.session.id,
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
-- The supervisor a message came from, with the clients of its workspace.
local function source(state: State, message: process.Message): Served?
    local served = state.served[tostring(message:from())]
    if not served or not served.ready or state.stopped then return nil end
    return served
end
function M.launched(state: State, message: process.Message, now: integer)
    local served = source(state, message)
    if not served then return end
    for _, client in pairs(state.clients) do
        local pending = client.pending
        local result = client.workspace_id == served.workspace_id
            and retained.launch_result(message:payload():data(), served.workspace_id, client.desktop_id) or nil
        if result and pending and pending.op == "launch" and pending.id == result.request_id and pending.call then
            local session = client.session
            if not session then return end
            local reply: types.Reply
            if result.error_code == "UNCERTAIN" then
                reply = types.reply_error(pending.call.request_id, types.uncertain(result.error,
                    {operation_ref = protocol.LAUNCH, idempotency_key = pending.call.idempotency_key}))
            elseif result.error_code ~= "" then
                local code = "UNAVAILABLE"
                if result.error_code == "DENIED" or result.error_code == "BUSY" or result.error_code == "INVALID_ARGUMENT" then code = result.error_code end
                reply = types.reply_error(pending.call.request_id, types.fault(code, result.error))
            else
                reply = types.reply_ok(pending.call.request_id, {owner_execution = state.config.execution,
                    workspace_id = client.workspace_id, desktop_id = client.desktop_id, session_id = session.id,
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
    local served = source(state, message)
    if not served then return end
    local result = retained.copy_result(message:payload():data())
    if not result then return end
    for _, client in pairs(state.clients) do
        local pending = client.pending
        if client.workspace_id == served.workspace_id and pending and pending.op == "copy" and pending.id == result.request_id and pending.call then
            local session = client.session
            if not session or client.closing then return end
            local reply: types.Reply
            if result.error ~= "" then reply = types.reply_error(pending.call.request_id, types.fault(result.selected and "INVALID_STATE" or "UNAVAILABLE", result.error))
            else reply = types.reply_ok(pending.call.request_id, {owner_execution = state.config.execution,
                workspace_id = client.workspace_id, desktop_id = client.desktop_id, session_id = session.id,
                selected = result.selected, text = result.text}) end
            remember(state, client, pending, reply, now)
            client.pending = nil
            return
        end
    end
end
function M.result(state: State, message: process.Message, now: integer)
    local served = source(state, message)
    if not served then return end
    for _, client in pairs(state.clients) do
        local pending = client.pending
        local result = client.workspace_id == served.workspace_id
            and retained.result(message:payload():data(), served.workspace_id, client.desktop_id) or nil
        if result and pending and not pending.activating and pending.id == result.request_id then
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
                if result.error_code ~= "" then
                    local code = "UNAVAILABLE"
                    if result.error_code == "busy" then code = "DESKTOP_CONTROLLED"
                    elseif result.error_code == "not_found" then code = "NOT_FOUND"
                    elseif result.error_code == "mode_conflict" then code = "CONFLICT"
                    elseif result.error_code == "invalid_argument" then code = "INVALID_ARGUMENT" end
                    reply = types.reply_error(pending.call.request_id, types.fault(code, result.error))
                elseif client.session then
                    reply = types.reply_ok(pending.call.request_id, {owner_execution = state.config.execution,
                        workspace_id = client.workspace_id, desktop_id = client.desktop_id, session_id = client.session.id,
                        recipient = client.recipient, mode = client.session.mode, mount_ref = client.session.mount, expires_at = state.config.expires_at})
                else reply = types.reply_ok(pending.call.request_id, {owner_execution = state.config.execution,
                    workspace_id = client.workspace_id, desktop_id = client.desktop_id, detached = true}) end
                remember(state, client, pending, reply, now)
            end
            client.pending = nil
            if result.error_code ~= "" then
                -- These attachment refusals happened before granting a mount.
                -- Do not retain a phantom target while a client selects another.
                if pending.op == "attach" and not client.session and (result.error_code == "busy"
                    or result.error_code == "not_found" or result.error_code == "mode_conflict"
                    or result.error_code == "invalid_argument") then
                    forget_refusal(state, pending)
                    forget(state, client.recipient)
                    return
                end
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
function M.activated(state: State, message: process.Message, now: integer)
    local served = source(state, message)
    if not served then return end
    local value = message:payload():data()
    for _, client in pairs(state.clients) do
        local pending = client.pending
        if client.workspace_id == served.workspace_id and pending and pending.activating then
            local result = retained.activation_result(value, served.workspace_id, client.desktop_id)
            if result and result.request_id == pending.id and pending.call then
                if result.error_code ~= "" or now >= pending.due or client.closing then
                    local reply = types.reply_error(pending.call.request_id, types.fault(
                        result.error_code == "BUSY" and "BUSY" or "UNAVAILABLE",
                        result.error ~= "" and result.error or "Desktop attachment canceled before admission"))
                    remember(state, client, pending, reply, now)
                    client.pending = nil
                    forget(state, client.recipient)
                    return
                end
                local attachment: Pending = {id = pending.id, op = "attach", call = pending.call,
                    cache_key = pending.cache_key, digest = pending.digest, due = pending.due, activating = false}
                client.pending = attachment
                local input = protocol.input(protocol.ATTACH, pending.call.input)
                if not input or not request_core(state, client, attachment, input.mode) then
                    remember(state, client, pending, types.reply_error(pending.call.request_id,
                        types.fault("UNAVAILABLE", "Desktop attachment request was not accepted")), now)
                    client.pending = nil
                    forget(state, client.recipient)
                end
                return
            end
        end
    end
end
function M.tick(state: State, now: integer)
    catalog.tick(state.catalog, now)
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
            if not request_core(state, client, cleanup, nil) then forget(state, client.recipient) end
        end
    end
end
-- A leased workspace's supervisor ended: its displays and every session on
-- them ended with it, and the host lease it held is released.
local function served_exited(state: State, served: Served, cause: string, now: integer)
    state.served[served.supervisor] = nil
    if state.workspaces[served.workspace_id] == served then state.workspaces[served.workspace_id] = nil end
    state.served_count = state.served_count - 1
    local ended: {string} = {}
    for recipient, client in pairs(state.clients) do
        if client.workspace_id == served.workspace_id then
            local pending = client.pending
            if pending and pending.call then
                remember(state, client, pending, types.reply_error(pending.call.request_id,
                    types.fault("UNAVAILABLE", "Workspace desktop ended: " .. cause)), now)
            end
            ended[#ended + 1] = recipient
        end
    end
    for _, recipient in ipairs(ended) do
        local client = state.clients[recipient]
        if client then
            process.unmonitor(recipient)
            state.clients[recipient] = nil
            state.client_count = state.client_count - 1
        end
    end
end
function M.event(state: State, event: process.Event, now: integer)
    if event.kind ~= process.event.EXIT and event.kind ~= process.event.LINK_DOWN then return end
    local sender = tostring(event.from)
    local served = state.served[sender]
    if served and event.kind == process.event.EXIT then
        local result: unknown = event.result
        local cause = type(result) == "table" and result.error ~= nil and tostring(result.error) or "without an error result"
        if served.folder then
            state.stopped = true
            for _, entry in pairs(state.served) do entry.catalog_readers = {}; entry.pending_catalog_readers = nil end
            error("Retained desktop owner exited: " .. cause)
        end
        served_exited(state, served, cause, now)
        return
    end
    -- Revoking this attachment is our authority, even when the remote actor's
    -- outcome is unknown. This does not declare that actor or its apps exited.
    local client = state.clients[sender]
    if client then revoke(state, client, now) end
end
function M.close(state: State)
    state.stopped = true
    process.unlisten(state.ready); process.unlisten(state.results); process.unlisten(state.copies); process.unlisten(state.launches)
    process.unlisten(state.activations); process.unlisten(state.reader_updates); process.unlisten(state.observers)
    process.registry.unregister(state.bridge_name)
    catalog.revoke(state.catalog, "Desktop owner stopped")
    for recipient in pairs(state.clients) do process.unmonitor(recipient) end
    for supervisor, served in pairs(state.served) do
        served.catalog_readers = {}; served.pending_catalog_readers = nil
        process.terminate(supervisor)
    end
end
return M
