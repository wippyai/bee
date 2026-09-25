-- MIT. Bounded supervisor request routing. Execution stays in function workers;
-- the event loop owns validated supervisor identities, deadlines and reply correlation.
-- Native Wippy authenticates message:from(); Lua checks the established peer.
local process = require("process")
local channel = require("channel")
local time = require("time")
local uuid = require("uuid")
local funcs = require("funcs")
local logger = require("logger")
local types = require("types")
local bounds = require("bounds")
local peers = require("peers")
local enrollment = require("enrollment")
local invites = require("invites")
local owner_stop = require("owner_stop")
local security = require("security")
local crypto = require("crypto")
local hash = require("hash")
local registration = require("registration")
local registry = require("registry")
local admission = require("admission")
local thread_admission = require("thread_admission")
local policy_admission = require("policy_admission")
local replica_admission = require("replica_admission")
local catalog = require("catalog")
local desktop_owner = require("desktop_owner")
local desktop_protocol = require("desktop_protocol")
local workspace_commands = require("workspace_commands")
local MAX_ROUTES = 64
local MAX_EXECUTIONS = 8
local MAX_CALLER_ROUTES = 8
local FORMAT = "2006-01-02T15:04:05.000Z07:00"
type Channel = channel.Channel
-- Receiver-local shapes; no remote type identity is trusted. Domain decoders
-- still enforce exact fields, protocol revisions, bounds and authorization.
type IncomingRequest = types.Call | types.Request
type IncomingReply = types.Reply
type IncomingHello = types.Hello
type Retry = {hello: types.Hello, sent_at: integer}
type LifetimeTarget = {node: string, pid: string}
type Route = {
    id: string, original_id: string, recipient: string, origin: string, fingerprint: string,
    operation_ref: string, idempotency_key: string,
    peer_pid: string?, peer_incarnation: string?, source_incarnation: string?,
    expires_at: integer, abandoned: boolean, future: funcs.Future?, response: Channel<unknown>?,
}
local function nonce(): string
    local value, err = uuid.v4()
    if not value or err then error("Cannot allocate Hive exchange identity") end
    return value
end
local function main(configuration: unknown)
    -- Native node loss reports LINK_DOWN to remote monitors too. The supervisor
    -- owns attachment revocation; losing a client must not kill this service.
    local trapping, trap_error = process.set_options({trap_links = true})
    if not trapping then error("Cannot handle Hive link loss: " .. tostring(trap_error)) end
    local config = bounds.object(configuration)
    if not config or bounds.fields(config, {"configured_nodes", "desktop", "enrollment"}) then error("Invalid Hive supervisor configuration") end
    local nodes, config_error = bounds.ids(config.configured_nodes)
    if not nodes then error("Invalid configured Hive nodes: " .. tostring(config_error)) end
    local desktop_config: desktop_protocol.Configuration? = nil
    if config.desktop ~= nil then
        local decoded, desktop_error = desktop_protocol.configuration(config.desktop)
        if not decoded then error("Invalid host desktop configuration: " .. tostring(desktop_error)) end
        desktop_config = decoded
    end
    local desktop: desktop_owner.State? = nil
    local self = tostring(process.pid())
    local native_node, host = types.pid_parts(self)
    if not native_node or host ~= types.SUPERVISOR_HOST then error("Hive supervisor requires its protected host") end
    if native_node == "" and #nodes > 0 then error("Configured peers require a native relay node identity") end
    -- The local-only runtime has no node component in its PIDs. This address
    -- marker never crosses the mesh and is not a durable machine identity.
    local node = native_node == "" and "local" or native_node
    local incarnation = nonce()
    local state, state_error = peers.new({local_node = node, local_incarnation = incarnation, configured_nodes = nodes, ttl_ms = 10000})
    if not state then error(tostring(state_error)) end
    -- The boot set stays authoritative; enrollment only adds and retires local
    -- client nodes the host names in its own registry entry.
    local boot: {[string]: boolean} = {}
    for _, configured in ipairs(nodes) do boot[configured] = true end
    -- The host enrollment names two roles: local clients of this owner and
    -- peers of this node's hive. Both are configured; only peers are discovered.
    local local_clients: {[string]: boolean} = {}
    local hive_peers: {[string]: boolean} = {}
    local invitations = invites.new()
    local started = time.now()
    local function elapsed(): integer return math.floor(time.now():sub(started):milliseconds()) end
    local log = logger:named("bee.hive_host.supervisor")
    local function send(recipient: string, topic: string, value: unknown): boolean
        local sent, err = process.send(recipient, topic, value)
        if not sent or err then log:warn("Hive delivery rejected", {topic = topic}) end
        return sent == true and err == nil
    end
    local function failed(recipient: string, id: string, code: string, message: string)
        send(recipient, types.TOPIC_REPLY, types.reply_error(id, types.fault(code, message:sub(1, 4096))))
    end
    local requests, request_error = process.listen(types.TOPIC_REQUEST, {message = true, type = IncomingRequest})
    if not requests then error(tostring(request_error)) end
    local replies, reply_error = process.listen(types.TOPIC_REPLY, {message = true, type = IncomingReply})
    if not replies then error(tostring(reply_error)) end
    local hellos, hello_error = process.listen(types.TOPIC_HELLO, {message = true, type = IncomingHello})
    if not hellos then error(tostring(hello_error)) end
    local lifetimes, lifetime_error = process.listen(desktop_protocol.LIFETIME, {message = true})
    if not lifetimes then error(tostring(lifetime_error)) end
    local lifetime_exits, exit_error = process.listen(desktop_protocol.LIFETIME_EXIT, {message = true})
    if not lifetime_exits then error(tostring(exit_error)) end
    local events, events_error = process.events()
    if not events then error(tostring(events_error)) end
    local tick = time.ticker("1s")
    local ticks = tick:channel()
    local routes: {[string]: Route} = {}
    local origins: {[string]: string} = {}
    local caller_routes: {[string]: integer} = {}
    -- A local display's direct remote attach is covered by a local monitor.
    -- Remote monitors report node loss, but not an individual remote EXIT.
    local display_lifetimes: {[string]: {[string]: LifetimeTarget}} = {}
    local lifetime_count = 0
    local retries: {[string]: Retry} = {}
    local route_count, execution_count = 0, 0
    local distributed_name = types.SUPERVISOR_NAME .. "/" .. node
    local advertised = false
    local advertising: funcs.Future? = nil
    local advertising_response: Channel<unknown>? = nil
    local last_advertisement = -5000
    local registered = false
    -- The name is published whenever this node has a native identity, even with
    -- no boot-configured peers: a local client must be able to discover the
    -- supervisor to ask for admission. Admission itself still requires an
    -- established peer or a host enrollment, so publication grants nothing.
    local function advertise(now_ms: integer)
        if native_node == "" or advertised or advertising then return end
        local future, future_error = funcs.async("bee.hive_host.supervisor:advertise", {name = distributed_name, pid = self})
        if not future or future_error then
            log:warn("Hive name publication unavailable")
            last_advertisement = now_ms
            return
        end
        advertising = future
        advertising_response = future:response()
        last_advertisement = now_ms
    end
    local function release(route: Route)
        routes[route.id] = nil
        origins[route.origin] = nil
        route_count = route_count - 1
        local remaining = (caller_routes[route.recipient] or 1) - 1
        if remaining == 0 then caller_routes[route.recipient] = nil else caller_routes[route.recipient] = remaining end
        if route.future then execution_count = execution_count - 1 end
    end
    local function expire_route(route: Route, code: string, message: string)
        if not route.abandoned then
            -- Past its deadline a dispatched request may have committed: the
            -- caller learns uncertainty with the identity to ask about or
            -- replay identically, never a refusal it could mistake for no effect.
            if route.future or route.peer_pid then
                send(route.recipient, types.TOPIC_REPLY, types.reply_error(route.original_id, types.uncertain(message, {operation_ref = route.operation_ref, idempotency_key = route.idempotency_key})))
            else
                failed(route.recipient, route.original_id, code, message)
            end
        end
        route.abandoned = true
        -- A timeout is not proof that the worker stopped. Keep its capacity
        -- charge until its actual completion; the initial operations are reads.
        if not route.future then release(route) end
    end
    local function peer_changed(transition: peers.Transition)
        local old = transition.old_peer
        if not old then return end
        for _, route in pairs(routes) do
            if (route.peer_pid == old.pid and route.peer_incarnation == old.supervisor_incarnation)
                or (route.recipient == old.pid and route.source_incarnation == old.supervisor_incarnation) then
                expire_route(route, "UNAVAILABLE", "peer supervisor was replaced")
            end
        end
    end
    local function lifetime_reply(sender: string, ticket: string, accepted: boolean, reason: string)
        send(sender, desktop_protocol.LIFETIME_REPLY .. ticket, {ticket = ticket, ok = accepted, error = reason})
    end
    local function lifetime_request(message: process.Message)
        local sender = tostring(message:from())
        local source_node, source_host = types.pid_parts(sender)
        if source_node ~= native_node or source_host ~= desktop_protocol.CLIENT_HOST then return end
        local data: unknown = message:payload():data()
        local object = bounds.object(data)
        if not object or bounds.fields(object, {"version", "op", "ticket", "owner_node"}) or object.version ~= 1 then return end
        local ticket = bounds.id(object.ticket)
        if not ticket then return end
        if #ticket ~= 32 or ticket:find("[^0-9a-f]") then return end
        if object.op == "unregister" and object.owner_node == nil then
            local registered = display_lifetimes[sender]
            if registered and registered[ticket] then
                registered[ticket] = nil
                lifetime_count = lifetime_count - 1
                if not next(registered) then display_lifetimes[sender] = nil; process.unmonitor(sender) end
            end
            return
        end
        if object.op ~= "register" then return end
        local owner_node = bounds.id(object.owner_node)
        if not owner_node or owner_node == node or owner_node:find("[/\\]") or owner_node:find("%.%.") then
            lifetime_reply(sender, ticket, false, "destination node is invalid")
            return
        end
        local destination = process.registry.lookup(types.SUPERVISOR_NAME .. "/" .. owner_node)
        if not destination then lifetime_reply(sender, ticket, false, "destination supervisor is not advertised"); return end
        local destination_node, destination_host = types.pid_parts(tostring(destination))
        if destination_node ~= owner_node or destination_host ~= types.SUPERVISOR_HOST then
            lifetime_reply(sender, ticket, false, "destination supervisor name is invalid"); return
        end
        local registered = display_lifetimes[sender]
        if registered and registered[ticket] then
            lifetime_reply(sender, ticket, registered[ticket].node == owner_node and registered[ticket].pid == tostring(destination), "lifetime ticket belongs to another owner")
            return
        end
        if lifetime_count >= 256 then lifetime_reply(sender, ticket, false, "display lifetime capacity reached"); return end
        if not registered then
            local monitored, monitor_error = process.monitor(sender)
            if not monitored or monitor_error then lifetime_reply(sender, ticket, false, "local display cannot be monitored"); return end
            registered = {}
            display_lifetimes[sender] = registered
        end
        registered[ticket] = {node = owner_node, pid = tostring(destination)}
        lifetime_count = lifetime_count + 1
        lifetime_reply(sender, ticket, true, "")
    end
    local function lifetime_exit(message: process.Message, now_ms: integer)
        if not desktop then return end
        local sender = tostring(message:from())
        local source_node, source_host = types.pid_parts(sender)
        if not source_node or source_host ~= types.SUPERVISOR_HOST then return end
        if not desktop_owner.allows_node(desktop, source_node) then return end
        local data: unknown = message:payload():data()
        local object = bounds.object(data)
        if not object or bounds.fields(object, {"version", "recipient"}) or object.version ~= 1 then return end
        local recipient = bounds.id(object.recipient)
        if not recipient then return end
        local recipient_node, recipient_host = types.pid_parts(recipient)
        if recipient_node ~= source_node or recipient_host ~= desktop_protocol.CLIENT_HOST then return end
        desktop_owner.revoke_recipient(desktop, recipient, now_ms)
    end
    local function local_display_exit(event: process.Event)
        if event.kind ~= process.event.EXIT then return end
        local recipient = tostring(event.from)
        local registered = display_lifetimes[recipient]
        if not registered then return end
        display_lifetimes[recipient] = nil
        for _, destination in pairs(registered) do
            lifetime_count = lifetime_count - 1
            send(destination.pid, desktop_protocol.LIFETIME_EXIT, {version = 1, recipient = recipient})
        end
    end
    -- reconcile_enrollment applies the host-selected local client nodes to the
    -- peer set and the desktop bridge. It runs on the tick, because a registry
    -- entry has no change notification here, and before a client-host sender the
    -- bridge does not yet admit is refused, because the host enrolls a node before
    -- that node's first request. Each pass reads one bounded entry and only
    -- enrolls or retires nodes the boot set does not own. A missing or malformed
    -- entry admits and retires nothing.
    local function reconcile_enrollment(now_ms: integer)
        local entry = registry.get(enrollment.ENTRY)
        if not entry or type(entry.data) ~= "table" then return end
        local desired, decode_error = enrollment.decode(entry.data)
        if not desired then
            log:warn("Hive enrollment refused", {cause = tostring(decode_error):sub(1, 256)})
            return
        end
        local enroll, retire = enrollment.diff(enrollment.desired(desired), boot, enrollment.configured_view(state))
        for _, selected in ipairs(retire) do
            local retired, retire_error = peers.retire(state, selected)
            if not retired and retire_error then log:warn("Hive enrollment retire refused", {node = selected, cause = retire_error}) end
        end
        for _, selected in ipairs(enroll) do
            local enrolled, enroll_error = peers.enroll(state, selected)
            if not enrolled and enroll_error then log:warn("Hive enrollment refused", {node = selected, cause = enroll_error}) end
        end
        local configured = enrollment.configured_view(state)
        local_clients = enrollment.set(desired.nodes, boot, configured)
        hive_peers = enrollment.set(desired.peers, boot, configured)
        if desktop then desktop_owner.enroll(desktop, local_clients, hive_peers, now_ms) end
    end
    local function discover(now_ms: integer)
        local remotes: {string} = {}
        for _, remote in ipairs(nodes) do remotes[#remotes + 1] = remote end
        for remote in pairs(hive_peers) do remotes[#remotes + 1] = remote end
        for _, remote in ipairs(remotes) do
            local candidate = process.registry.lookup(types.SUPERVISOR_NAME .. "/" .. remote)
            if candidate then
                local active = peers.current(state, remote)
                if not peers.pending(state, remote) and (not active or active.pid ~= candidate) then
                    local hello = peers.begin(state, remote, candidate, nonce(), now_ms)
                    if hello then
                        retries[remote] = {hello = hello, sent_at = now_ms}
                        send(candidate, types.TOPIC_HELLO, hello)
                    end
                end
            end
        end
    end
    local function session(remote: string): string
        if peers.current(state, remote) then return "established" end
        if peers.pending(state, remote) then return "pending" end
        return "none"
    end
    -- join answers the invite operations of service bee.hive.join. An enrolled
    -- local client mints, lists and revokes invites and reads the peer view;
    -- only the owner's native join listener redeems. The host policy gates every
    -- operation, and invites live only in this execution: after a restart an
    -- earlier invite is unknown and refused.
    local function join(sender: string, call: types.Call, now_ms: integer)
        local sender_node, sender_host = types.pid_parts(sender)
        local operation = call.target.operation_ref
        if not operation or call.owner_ref.node_id ~= node or call.owner_ref.resource_ref then
            failed(sender, call.request_id, "DENIED", "invite operations are served only by their own node"); return
        end
        local input, input_error = invites.decode(operation, call.input)
        if not input then failed(sender, call.request_id, "INVALID_ARGUMENT", input_error or "invalid invite input"); return end
        if operation == invites.REDEEM then
            if native_node == "" or sender_node ~= native_node or sender_host ~= invites.JOIN_HOST then
                failed(sender, call.request_id, "DENIED", "only the native join listener redeems invites"); return
            end
        else
            if sender_host == desktop_protocol.CLIENT_HOST and sender_node and not local_clients[sender_node] then reconcile_enrollment(now_ms) end
            if sender_host ~= desktop_protocol.CLIENT_HOST or not sender_node or not local_clients[sender_node] then
                failed(sender, call.request_id, "DENIED", "invite operations require an enrolled local client"); return
            end
        end
        if not security.can(invites.ACTION, operation) then
            failed(sender, call.request_id, "DENIED", "the host did not grant invite operations"); return
        end
        if operation == invites.INVITE then
            local id, id_error = crypto.random.string(32, "0123456789abcdef")
            local secret, secret_error = crypto.random.string(64, "0123456789abcdef")
            local digest = secret and hash.sha256(secret) or nil
            if not id or id_error or not secret or secret_error or not digest then
                failed(sender, call.request_id, "INTERNAL", "invite secret unavailable"); return
            end
            local expires_at = time.now():add(tostring(invites.LIFETIME_MS) .. "ms"):utc():format(FORMAT)
            local minted, mint_error = invites.mint(invitations, id, digest, now_ms, expires_at)
            if not minted then failed(sender, call.request_id, "LIMIT_EXCEEDED", mint_error or "invite refused"); return end
            send(sender, types.TOPIC_REPLY, types.reply_ok(call.request_id, {invite_id = minted.invite_id, secret = secret, expires_at = minted.expires_at}))
        elseif operation == invites.LIST then
            send(sender, types.TOPIC_REPLY, types.reply_ok(call.request_id, {invites = invites.list(invitations, now_ms)}))
        elseif operation == invites.REVOKE and input.invite_id then
            local revoked, code, message = invites.revoke(invitations, input.invite_id, now_ms)
            if not revoked then failed(sender, call.request_id, code or "INVALID_STATE", message or "invite not revoked"); return end
            send(sender, types.TOPIC_REPLY, types.reply_ok(call.request_id, revoked))
        elseif operation == invites.PEERS then
            local listed: {{node_id: string, session: string}} = {}
            local remotes: {string} = {}
            for _, remote in ipairs(nodes) do remotes[#remotes + 1] = remote end
            for remote in pairs(hive_peers) do remotes[#remotes + 1] = remote end
            table.sort(remotes)
            for _, remote in ipairs(remotes) do listed[#listed + 1] = {node_id = remote, session = session(remote)} end
            send(sender, types.TOPIC_REPLY, types.reply_ok(call.request_id, {node_id = node, peers = listed}))
        elseif operation == invites.REDEEM and input.invite_id and input.secret and input.node_id then
            if input.node_id == node then failed(sender, call.request_id, "DENIED", "a node cannot join its own hive"); return end
            if peers.is_configured(state, input.node_id) then failed(sender, call.request_id, "CONFLICT", "node is already a peer"); return end
            local digest = hash.sha256(input.secret)
            if not digest then failed(sender, call.request_id, "INTERNAL", "invite digest unavailable"); return end
            local redeemed, code, message = invites.redeem(invitations, input.invite_id, digest, input.node_id, now_ms)
            if not redeemed then failed(sender, call.request_id, code or "DENIED", message or "invite refused"); return end
            send(sender, types.TOPIC_REPLY, types.reply_ok(call.request_id, {invite_id = redeemed.invite_id, node_id = input.node_id}))
        end
    end
    -- stop asks this owner's command process to end the run at the request
    -- of an enrolled local client, after answering it; the runtime's shutdown
    -- retires the desktop exactly as a termination signal does.
    local function stop(sender: string, call: types.Call, now_ms: integer)
        local sender_node, sender_host = types.pid_parts(sender)
        local request, refusal = owner_stop.decode(call, node)
        if not request then send(sender, types.TOPIC_REPLY, types.reply_error(call.request_id, refusal :: types.Fault)); return end
        if sender_host == desktop_protocol.CLIENT_HOST and sender_node and not local_clients[sender_node] then reconcile_enrollment(now_ms) end
        if sender_host ~= desktop_protocol.CLIENT_HOST or not sender_node or not local_clients[sender_node] then
            failed(sender, call.request_id, "DENIED", "only an enrolled local client stops its owner"); return
        end
        if not security.can(owner_stop.ACTION, owner_stop.STOP) then
            failed(sender, call.request_id, "DENIED", "the host did not grant owner stop"); return
        end
        local stopping = owner_stop.stops(request, sender_node :: string, local_clients)
        send(sender, types.TOPIC_REPLY, types.reply_ok(call.request_id, {stopping = stopping}))
        if stopping then
            log:info("Owner stop requested by a local client", {node = sender_node})
            local sent, send_error = process.send(owner_stop.COMMAND, owner_stop.TOPIC, {version = 1})
            if not sent then log:error("Owner stop was not delivered", {cause = tostring(send_error)}) end
        end
    end
    -- command runs one bee workspace command of an enrolled local client on
    -- its worker, as a route: the loop owns its deadline and correlation, and
    -- a command past its deadline is answered as an unknown outcome.
    local function command(sender: string, call: types.Call, value: unknown, now_ms: integer)
        local sender_node, sender_host = types.pid_parts(sender)
        if sender_host == desktop_protocol.CLIENT_HOST and sender_node and not local_clients[sender_node] then reconcile_enrollment(now_ms) end
        if sender_host ~= desktop_protocol.CLIENT_HOST or not sender_node or not local_clients[sender_node] then
            failed(sender, call.request_id, "DENIED", "workspace commands require an enrolled local client"); return
        end
        local operation, refusal = workspace_commands.target(call, node)
        if not operation then
            failed(sender, call.request_id, refusal and refusal.code or "INVALID_ARGUMENT", refusal and refusal.message or "invalid workspace command")
            return
        end
        if not security.can(workspace_commands.ACTION, operation) then
            failed(sender, call.request_id, "DENIED", "the host did not grant workspace commands"); return
        end
        local fingerprint = types.digest(value)
        if not fingerprint then failed(sender, call.request_id, "INVALID_ARGUMENT", "request is not measurable"); return end
        local origin = sender .. "\0" .. call.request_id
        local existing_id = origins[origin]
        if existing_id then
            if routes[existing_id].fingerprint ~= fingerprint then
                failed(sender, call.request_id, "CONFLICT", "request id is already pending with different input")
            end
            return
        end
        if route_count >= MAX_ROUTES then failed(sender, call.request_id, "BUSY", "supervisor request capacity reached"); return end
        if (caller_routes[sender] or 0) >= MAX_CALLER_ROUTES then failed(sender, call.request_id, "BUSY", "caller request capacity reached"); return end
        if execution_count >= MAX_EXECUTIONS then failed(sender, call.request_id, "BUSY", "operation capacity reached"); return end
        local deadline = call.deadline and time.parse(FORMAT, call.deadline)
        if not deadline then failed(sender, call.request_id, "INVALID_ARGUMENT", "a workspace command needs a deadline"); return end
        local remaining = math.floor(deadline:sub(time.now()):milliseconds())
        if remaining <= 0 then failed(sender, call.request_id, "DEADLINE_EXCEEDED", "workspace command deadline has passed"); return end
        if remaining > workspace_commands.MAX_MS then remaining = workspace_commands.MAX_MS end
        local exchange_id = nonce()
        local future, err = funcs.async(workspace_commands.WORKER, {request_id = exchange_id, operation = operation,
            idempotency_key = call.idempotency_key, input = call.input})
        if not future or err then failed(sender, call.request_id, "UNAVAILABLE", "workspace command dispatch unavailable"); return end
        local route: Route = {id = exchange_id, original_id = call.request_id, recipient = sender, origin = origin, fingerprint = fingerprint,
            operation_ref = operation, idempotency_key = call.idempotency_key, expires_at = now_ms + remaining, abandoned = false,
            future = future, response = future:response()}
        routes[exchange_id], origins[origin] = route, exchange_id
        route_count = route_count + 1
        execution_count = execution_count + 1
        caller_routes[sender] = (caller_routes[sender] or 0) + 1
    end
    local function admit(message: process.Message)
        if desktop and desktop_owner.client_host(message) and not desktop_owner.handles(desktop, message) then
            reconcile_enrollment(elapsed())
        end
        local join_call = types.decode_call(message:payload():data())
        if join_call and join_call.owner_ref.service_id == invites.SERVICE then
            join(tostring(message:from()), join_call, elapsed())
            return
        end
        if join_call and join_call.owner_ref.service_id == owner_stop.SERVICE then
            stop(tostring(message:from()), join_call, elapsed())
            return
        end
        if join_call and join_call.owner_ref.service_id == workspace_commands.SERVICE then
            command(tostring(message:from()), join_call, message:payload():data(), elapsed())
            return
        end
        if desktop and desktop_owner.handles(desktop, message) then
            desktop_owner.request(desktop, message, elapsed())
            return
        end
        local sender = tostring(message:from())
        local value: unknown = message:payload():data()
        local sender_node = types.pid_parts(sender)
        local id: string? = nil
        local object = bounds.object(value)
        if object then id = bounds.id(object.request_id) end
        if not object or not id or not sender_node then return end
        local origin = sender .. "\0" .. id
        local existing_id = origins[origin]
        if existing_id then
            -- Decode before hashing an untrusted duplicate. An identical retry
            -- keeps the same route and deadline; changed input conflicts.
            if sender_node == native_node then
                if not types.decode_call(value) then failed(sender, id, "INVALID_ARGUMENT", "invalid repeated call"); return end
            else
                local accepted = admission.accept(node, peers.current(state, sender_node), sender, value, time.now())
                if not accepted then failed(sender, id, "DENIED", "repeated request has no valid peer assertion"); return end
            end
            local fingerprint = types.digest(object)
            if not fingerprint or routes[existing_id].fingerprint ~= fingerprint then
                failed(sender, id, "CONFLICT", "request id is already pending with different input")
            end
            return
        end
        if route_count >= MAX_ROUTES then failed(sender, id, "BUSY", "supervisor request capacity reached"); return end
        if (caller_routes[sender] or 0) >= MAX_CALLER_ROUTES then failed(sender, id, "BUSY", "caller request capacity reached"); return end
        local exchange_id = nonce()
        local wall_now = time.now()
        local request: types.Request? = nil
        local source_incarnation: string? = nil
        if sender_node == native_node then
            local call, err = types.decode_call(value)
            if not call then failed(sender, id, "INVALID_ARGUMENT", err or "invalid call"); return end
            if call.owner_ref.node_id ~= node and not peers.is_configured(state, call.owner_ref.node_id) then
                failed(sender, id, "UNAVAILABLE", "destination node is not configured"); return
            end
            local snapshot, snapshot_error = catalog.snapshot()
            if not snapshot then failed(sender, id, "UNAVAILABLE", snapshot_error or "catalog unavailable"); return end
            local resolved: catalog.ResolvedCall? = nil
            local resolution_error: string? = nil
            if call.target.operation_ref then
                resolved, resolution_error = catalog.resolve_call(snapshot, call.target.operation_ref, call.input)
            elseif call.target.interface_ref then
                resolved, resolution_error = catalog.apply_interface(snapshot, call.target.interface_ref, call.input)
            end
            if not resolved then failed(sender, id, "DENIED", resolution_error or "operation unavailable"); return end
            if resolved.operation.mode ~= "open" and not (resolved.operation.mode == "policy" and policy_admission.admits(resolved.operation.operation_ref)) then
                failed(sender, id, "UNSUPPORTED_CAPABILITY", "operation has no admitted forwarding route"); return
            end
            local fault: types.Fault? = nil
            request, fault = admission.forward(node, incarnation, sender, exchange_id, call, resolved, wall_now)
            if not request then
                failed(sender, id, fault and fault.code or "INVALID_ARGUMENT", fault and fault.message or "invalid forwarding request")
                return
            end
        else
            local peer = peers.current(state, sender_node)
            local fault: types.Fault? = nil
            request, fault = admission.accept(node, peer, sender, value, wall_now)
            if not request then
                failed(sender, id, fault and fault.code or "DENIED", fault and fault.message or "request denied")
                return
            end
            source_incarnation = request.caller_incarnation
            request.request_id = exchange_id
        end
        if not request then return end
        local deadline = time.parse(FORMAT, request.deadline)
        if not deadline then failed(sender, id, "INVALID_ARGUMENT", "invalid deadline"); return end
        local fingerprint = types.digest(object)
        if not fingerprint then failed(sender, id, "INVALID_ARGUMENT", "request is not measurable"); return end
        local route: Route = {id = exchange_id, original_id = id, recipient = sender, origin = origin,
            fingerprint = fingerprint, operation_ref = request.operation_ref, idempotency_key = request.idempotency_key, source_incarnation = source_incarnation,
            expires_at = elapsed() + math.floor(deadline:sub(wall_now):milliseconds()), abandoned = false}
        if request.owner_ref.node_id == node then
            if execution_count >= MAX_EXECUTIONS then failed(sender, id, "BUSY", "operation capacity reached"); return end
            -- A forwarded thread operation runs as the actor the host maps
            -- the verified principal to; everything else takes the open
            -- dispatch. A local caller never reaches the thread path here.
            local worker = "bee.hive_host.supervisor:execute"
            if sender_node ~= native_node and request.operation_ref == replica_admission.OPERATION then
                worker = "bee.hive_host.supervisor:admit_replica"
            elseif sender_node ~= native_node and thread_admission.OPERATIONS[request.operation_ref] then
                worker = "bee.hive_host.supervisor:admit_thread"
            elseif policy_admission.admits(request.operation_ref) then
                worker = "bee.hive_host.supervisor:admit_policy"
            end
            local future, err = funcs.async(worker, request)
            if not future or err then failed(sender, id, "UNAVAILABLE", "operation dispatch unavailable"); return end
            route.future = future
            route.response = future:response()
            execution_count = execution_count + 1
        else
            local peer = peers.current(state, request.owner_ref.node_id)
            if not peer then failed(sender, id, "UNAVAILABLE", "destination supervisor is not established"); return end
            route.peer_pid, route.peer_incarnation = peer.pid, peer.supervisor_incarnation
            if not send(peer.pid, types.TOPIC_REQUEST, request) then
                failed(sender, id, "UNAVAILABLE", "destination did not accept the request"); return
            end
        end
        routes[exchange_id], origins[origin] = route, exchange_id
        route_count = route_count + 1
        caller_routes[sender] = (caller_routes[sender] or 0) + 1
    end
    local function run()
        if desktop_config then desktop = desktop_owner.start(desktop_config, node) end
        local named, name_error = process.registry.register(types.SUPERVISOR_NAME)
        if not named then error("Register local supervisor: " .. tostring(name_error)) end
        registered = true
        -- A local client discovers this supervisor only through this eventual
        -- name, so publish it whenever the node has a native identity. The
        -- desktop bridge is not a condition: its failure must not remove the
        -- only discovery path. Publishing grants no admission on its own.
        local decision = registration.decide(native_node, distributed_name)
        if decision.publish then
            local published, publish_error = process.registry.register(decision.name, self, process.registry.EVENTUAL)
            if not published then
                log:error("Hive supervisor name publication failed", {name = decision.name, cause = tostring(publish_error)})
                advertise(elapsed())
            else
                advertised = true
            end
        else
            -- A local-only node publishes no cluster-visible name; the optional
            -- external Hive path still has a chance to advertise.
            advertise(elapsed())
        end
        local desktop_ready = desktop and desktop.ready
        local desktop_results = desktop and desktop.results
        local desktop_copies = desktop and desktop.copies
        local desktop_launches = desktop and desktop.launches
        local desktop_activations = desktop and desktop.activations
        local desktop_switches = desktop and desktop.switches
        local desktop_observers = desktop and desktop.observers
        while true do
            local cases = {requests:case_receive(), replies:case_receive(), hellos:case_receive(), lifetimes:case_receive(), lifetime_exits:case_receive(), events:case_receive(), ticks:case_receive()}
            local catalog_work = 0
            if desktop then
                for _, response in ipairs(desktop_owner.catalog_channels(desktop)) do
                    catalog_work = catalog_work + 1
                    cases[#cases + 1] = response:case_receive()
                end
            end
            if desktop_activations then cases[#cases + 1] = desktop_activations:case_receive() end
            if desktop_switches then cases[#cases + 1] = desktop_switches:case_receive() end
            if desktop_observers then cases[#cases + 1] = desktop_observers:case_receive() end
            if desktop_copies then cases[#cases + 1] = desktop_copies:case_receive() end
            if desktop_launches then cases[#cases + 1] = desktop_launches:case_receive() end
            if desktop_ready and desktop_results then
                cases[#cases + 1] = desktop_ready:case_receive()
                cases[#cases + 1] = desktop_results:case_receive()
            end
            if advertising_response then cases[#cases + 1] = advertising_response:case_receive() end
            for _, route in pairs(routes) do
                if route.response then cases[#cases + 1] = route.response:case_receive() end
            end
            local selected = channel.select(cases)
            if not selected.ok then error("Hive supervisor channel closed") end
            local now_ms = elapsed()
            if selected.channel == events then
                if selected.value.kind == process.event.CANCEL then return end
                local_display_exit(selected.value)
                if desktop then desktop_owner.event(desktop, selected.value, now_ms) end
            elseif selected.channel == lifetimes then
                lifetime_request(selected.value)
            elseif selected.channel == lifetime_exits then
                lifetime_exit(selected.value, now_ms)
            elseif selected.channel == ticks then
                if desktop then desktop_owner.tick(desktop, now_ms) end
                local _, clock_error = peers.expire(state, now_ms)
                if clock_error then error(clock_error) end
                for remote, retry in pairs(retries) do
                    local pending = peers.pending(state, remote)
                    if not pending then retries[remote] = nil
                    elseif now_ms - retry.sent_at >= 1000 then
                        send(pending.pid, types.TOPIC_HELLO, retry.hello)
                        retry.sent_at = now_ms
                    end
                end
                for _, route in pairs(routes) do
                    if now_ms >= route.expires_at then
                        if route.future then expire_route(route, "DEADLINE_EXCEEDED", "request deadline passed after dispatch; the outcome is unknown")
                        else expire_route(route, "DEADLINE_EXCEEDED", "supervisor request deadline passed") end
                    end
                end
                reconcile_enrollment(now_ms)
                -- Discovery reads only this node's name view, so it runs on every
                -- tick: a peer that restarted is greeted as soon as its name arrives.
                discover(now_ms)
                if now_ms - last_advertisement >= 5000 then advertise(now_ms) end
            elseif advertising_response and selected.channel == advertising_response and advertising then
                local value, result_error = advertising:result()
                local data: unknown = value and value:data() or nil
                local result = type(data) == "table" and data :: {ok: boolean, error: string} or nil
                advertised = result_error == nil and result ~= nil and result.ok == true
                if not advertised then
                    log:warn("Hive name publication deferred", {error = result and result.error or tostring(result_error)})
                end
                advertising = nil
                advertising_response = nil
            elseif desktop and catalog_work > 0 and desktop_owner.catalog_result(desktop, selected.channel, now_ms) then
                -- A pending desktop catalog read or allocation completed.
            elseif desktop_activations and selected.channel == desktop_activations and desktop then
                desktop_owner.activated(desktop, selected.value, now_ms)
            elseif desktop_switches and selected.channel == desktop_switches and desktop then
                desktop_owner.switch(desktop, selected.value, now_ms)
            elseif desktop_ready and selected.channel == desktop_ready and desktop then
                desktop_owner.ready(desktop, selected.value, now_ms)
            elseif desktop_observers and selected.channel == desktop_observers and desktop then
                desktop_owner.observe(desktop, selected.value)
            elseif desktop_results and selected.channel == desktop_results and desktop then
                desktop_owner.result(desktop, selected.value, now_ms)
            elseif desktop_launches and selected.channel == desktop_launches and desktop then
                desktop_owner.launched(desktop, selected.value, now_ms)
            elseif desktop_copies and selected.channel == desktop_copies and desktop then
                desktop_owner.copied(desktop, selected.value, now_ms)
            elseif selected.channel == hellos then
                local message = selected.value
                local sender = tostring(message:from())
                local remote, sender_host = types.pid_parts(sender)
                if remote and sender_host == types.SUPERVISOR_HOST and peers.is_configured(state, remote) then
                    local hello, transition = peers.receive(state, sender, message:payload():data(), nonce(), now_ms)
                    if transition then peer_changed(transition) end
                    if hello then
                        if peers.pending(state, remote) then retries[remote] = {hello = hello, sent_at = now_ms} end
                        send(sender, types.TOPIC_HELLO, hello)
                    end
                end
            elseif selected.channel == requests then
                local message = selected.value
                admit(message)
            elseif selected.channel == replies then
                local message = selected.value
                local sender = tostring(message:from())
                local reply = types.decode_reply(message:payload():data())
                local route: Route? = nil
                if reply then route = routes[reply.request_id] end
                if reply and route and route.peer_pid == sender and not route.abandoned then
                    local remote = types.pid_parts(sender)
                    local peer = remote and peers.current(state, remote)
                    if peer and peer.pid == sender and peer.supervisor_incarnation == route.peer_incarnation and now_ms < route.expires_at then
                        reply.request_id = route.original_id
                        send(route.recipient, types.TOPIC_REPLY, reply)
                        release(route)
                    end
                end
            else
                for _, route in pairs(routes) do
                    if route.response == selected.channel and route.future then
                        local value, err = route.future:result()
                        local reply: types.Reply? = nil
                        if not err and value then
                            local data: unknown = value:data()
                            reply = types.decode_reply(data)
                        end
                        if not reply then
                            log:error("Hive worker result refused", {stage = "execution/result", request_id = route.id,
                                cause = err and tostring(err):sub(1, 4096) or "invalid reply envelope"})
                        end
                        if not route.abandoned and now_ms < route.expires_at then
                            if reply and reply.request_id == route.id then
                                reply.request_id = route.original_id
                                send(route.recipient, types.TOPIC_REPLY, reply)
                            else failed(route.recipient, route.original_id, "INTERNAL", "operation returned an invalid reply") end
                        elseif not route.abandoned then
                            expire_route(route, "DEADLINE_EXCEEDED", "operation completed after its deadline; outcome requires reconciliation")
                        end
                        release(route)
                        break
                    end
                end
            end
        end
    end
    local ok, err = pcall(run)
    tick:stop()
    if desktop then desktop_owner.close(desktop) end
    if advertising then advertising:cancel() end
    for _, route in pairs(routes) do
        if route.future then route.future:cancel() end
        if not route.abandoned then expire_route(route, "UNAVAILABLE", "supervisor is stopping; outcome may be unknown") end
    end
    if advertised then
        local _, release_error = process.registry.unregister(distributed_name, process.registry.EVENTUAL)
        if release_error then log:error("Hive name release failed", {name = distributed_name, error = tostring(release_error)}) end
    end
    if registered then process.registry.unregister(types.SUPERVISOR_NAME) end
    process.unlisten(requests); process.unlisten(replies); process.unlisten(hellos)
    if not ok then error(tostring(err)) end
end
return {main = main}
