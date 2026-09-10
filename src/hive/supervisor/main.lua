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
local admission = require("admission")
local thread_admission = require("thread_admission")
local catalog = require("catalog")
local desktop_owner = require("desktop_owner")
local desktop_protocol = require("desktop_protocol")
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
    if not config or bounds.fields(config, {"configured_nodes", "desktop"}) then error("Invalid Hive supervisor configuration") end
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
    local started = time.now()
    local function elapsed(): integer return math.floor(time.now():sub(started):milliseconds()) end
    local log = logger:named("bee.hive.supervisor")
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
    local events, events_error = process.events()
    if not events then error(tostring(events_error)) end
    local tick = time.ticker("1s")
    local ticks = tick:channel()
    local routes: {[string]: Route} = {}
    local origins: {[string]: string} = {}
    local caller_routes: {[string]: integer} = {}
    local retries: {[string]: Retry} = {}
    local route_count, execution_count = 0, 0
    local last_discovery = -5000
    local distributed_name = types.SUPERVISOR_NAME .. "/" .. node
    local advertised = false
    local registered = false
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
    local function discover(now_ms: integer)
        for _, remote in ipairs(nodes) do
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
    local function admit(message: process.Message)
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
            if resolved.operation.mode ~= "open" then failed(sender, id, "UNSUPPORTED_CAPABILITY", "only open telemetry is enabled"); return end
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
            local worker = "bee.hive.supervisor:execute"
            if sender_node ~= native_node and thread_admission.OPERATIONS[request.operation_ref] then worker = "bee.hive.supervisor:admit_thread" end
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
        if native_node ~= "" and (#nodes > 0 or desktop ~= nil) then
            local named, name_error = process.registry.register(distributed_name, self, process.registry.EVENTUAL)
            if not named then error("Publish supervisor name: " .. tostring(name_error)) end
            advertised = true
        end
        local named, name_error = process.registry.register(types.SUPERVISOR_NAME)
        if not named then error("Register local supervisor: " .. tostring(name_error)) end
        registered = true
        local desktop_ready = desktop and desktop.ready
        local desktop_results = desktop and desktop.results
        local desktop_copies = desktop and desktop.copies
        local desktop_launches = desktop and desktop.launches
        local desktop_catalogs = desktop and desktop.catalogs
        local desktop_activations = desktop and desktop.activations
        while true do
            local cases = {requests:case_receive(), replies:case_receive(), hellos:case_receive(), events:case_receive(), ticks:case_receive()}
            if desktop_catalogs then cases[#cases + 1] = desktop_catalogs:case_receive() end
            if desktop_activations then cases[#cases + 1] = desktop_activations:case_receive() end
            if desktop_copies then cases[#cases + 1] = desktop_copies:case_receive() end
            if desktop_launches then cases[#cases + 1] = desktop_launches:case_receive() end
            if desktop_ready and desktop_results then
                cases[#cases + 1] = desktop_ready:case_receive()
                cases[#cases + 1] = desktop_results:case_receive()
            end
            for _, route in pairs(routes) do
                if route.response then cases[#cases + 1] = route.response:case_receive() end
            end
            local selected = channel.select(cases)
            if not selected.ok then error("Hive supervisor channel closed") end
            local now_ms = elapsed()
            if selected.channel == events then
                if selected.value.kind == process.event.CANCEL then return end
                if desktop then desktop_owner.event(desktop, selected.value, now_ms) end
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
                if now_ms - last_discovery >= 5000 then discover(now_ms); last_discovery = now_ms end
            elseif desktop_catalogs and selected.channel == desktop_catalogs and desktop then
                desktop_owner.catalog_result(desktop, selected.value, now_ms)
            elseif desktop_activations and selected.channel == desktop_activations and desktop then
                desktop_owner.activated(desktop, selected.value, now_ms)
            elseif desktop_ready and selected.channel == desktop_ready and desktop then
                desktop_owner.ready(desktop, selected.value)
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
    for _, route in pairs(routes) do
        if route.future then route.future:cancel() end
        if not route.abandoned then expire_route(route, "UNAVAILABLE", "supervisor is stopping; outcome may be unknown") end
    end
    if advertised then process.registry.unregister(distributed_name, process.registry.EVENTUAL) end
    if registered then process.registry.unregister(types.SUPERVISOR_NAME) end
    process.unlisten(requests); process.unlisten(replies); process.unlisten(hellos)
    if not ok then error(tostring(err)) end
end
return {main = main}
