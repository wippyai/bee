-- MIT. The node host manager: starts a workspace host when a lease first asks
-- for its workspace, stops it once it has stayed unleased for the idle period
-- and its shutdown checkpointed the workspace, and keeps at most a capped
-- number of hosts live, stopping the least recently used idle host first. A
-- workspace some other composition already serves (classic folder mode) is
-- reported as served and never managed here. As every managed host's owner it
-- admits desktops for the lease holders attached to it: it relays their
-- desktop admission requests to the host and the host's answers back.
local process = require("process")
local channel = require("channel")
local security = require("security")
local time = require("time")
local uuid = require("uuid")
local logger = require("logger")
local hosts = require("hosts")
local leases = require("leases")
local protocol = require("protocol")
local decode = require("decode")
local contract = require("contract")

type Config = {cap: integer, idle: number, database: string?}
type Channel = channel.Channel
type Waiter = {sender: string, request: leases.Acquire}

local HOST_PREFIX = "bee.workspace.host/"
local DEFAULT_CAP = 64
local DEFAULT_IDLE_MS = 900000
-- Topics a host delivers to its owner. The manager drains those it does not
-- act on, so no message waits in its queue for a listener that never comes.
local DRAINED = {"bee.application.catalog", "bee.host.checkpoint", "bee.host.restore_result", "bee.interaction.state"}

local function config(value: unknown): Config?
    if value == nil then return {cap = DEFAULT_CAP, idle = DEFAULT_IDLE_MS / 1000, database = nil} end
    if type(value) ~= "table" then return nil end
    for key in pairs(value) do
        if key ~= "cap" and key ~= "idle_ms" and key ~= "database" then return nil end
    end
    local cap, idle_ms = value.cap or DEFAULT_CAP, value.idle_ms or DEFAULT_IDLE_MS
    if type(cap) ~= "number" or cap ~= math.floor(cap) or cap < 1 or cap > hosts.MAX_CAP then return nil end
    if type(idle_ms) ~= "number" or idle_ms ~= math.floor(idle_ms) or idle_ms < 1 or idle_ms > 86400000 then return nil end
    local database: string? = nil
    if value.database ~= nil then
        if type(value.database) ~= "string" or not value.database:match("^bee%.workspace%.db:[%w_%-]+$") then return nil end
        database = value.database
    end
    return {cap = math.floor(cap), idle = idle_ms / 1000, database = database}
end

local function now(): number return time.now():unix_nano() / 1000000000 end

local function main(value: unknown)
    local settings = config(value)
    if not settings then error("Invalid host manager configuration") end
    local self = tostring(process.pid())
    local registered, register_error = process.registry.register(leases.MANAGER)
    if not registered then error("Register host manager: " .. tostring(register_error)) end
    local acquires = assert(process.listen(leases.ACQUIRE, {message = true}))
    local releases = assert(process.listen(leases.RELEASE, {message = true}))
    local ready = assert(process.listen("bee.host.ready", {message = true}))
    local replies = assert(process.listen("bee.app.reply", {message = true}))
    local attaches = assert(process.listen(leases.ATTACH, {message = true}))
    local client_requests = assert(process.listen("bee.host.client", {message = true}))
    local client_results = assert(process.listen("bee.host.client_result", {message = true}))
    local drained: {Channel<process.Message>} = {}
    for _, topic in ipairs(DRAINED) do drained[#drained + 1] = assert(process.listen(topic, {message = true})) end
    local events = assert(process.events())
    local policies: {security.Policy} = {}
    for _, name in ipairs({"bee.security.desktop:host_policy", "bee.security.desktop:host_spawn_policy", "bee.security.storage:workspace_storage_policy"}) do
        local policy, policy_error = security.policy(name)
        if not policy then error(tostring(policy_error)) end
        policies[#policies + 1] = policy
    end
    local host_scope = security.new_scope(policies)
    local state = hosts.new(settings.cap, settings.idle)
    local pids: {[string]: string} = {}
    local waiters: {[string]: {Waiter}} = {}
    -- Requests that wait for a stop to free a slot or finish a restart.
    local queued: {Waiter} = {}
    local stops: {[string]: string} = {}
    local monitored: {[string]: boolean} = {}
    -- Each ready host's announcement, as the host sent it, for the holders
    -- that attach to it.
    local announcements: {[string]: unknown} = {}

    local function answer(waiter: Waiter, host: string, managed: boolean, code: string, message: string)
        process.send(waiter.sender, leases.RESULT, {version = 1, request_id = waiter.request.request_id,
            workspace_id = waiter.request.workspace_id, host = host, managed = managed, error_code = code, error = message})
    end
    local resume_queue: () -> ()
    local function stop(workspace_id: string)
        local host = hosts.host(state, workspace_id)
        if not host or host.pid == "" then return end
        local request_id = "idle-stop-" .. tostring(uuid.v7())
        stops[workspace_id] = request_id
        local sent = process.send(host.pid, "bee.app.request", {version = 1, request_id = request_id, op = "shutdown", workspace_id = workspace_id})
        if not sent then
            stops[workspace_id] = nil
            hosts.stop_refused(state, workspace_id)
            resume_queue()
        end
    end
    local function start(workspace_id: string)
        local pid, spawn_error = process.with_options({}):with_context({["bee.host_owner"] = self}):with_scope(host_scope)
            :spawn_monitored("bee.host:main", "bee:workers", self, {workspace_id = workspace_id}, settings.database)
        if not pid then
            local failed: {Waiter} = waiters[workspace_id] or {}
            waiters[workspace_id] = nil
            hosts.gone(state, workspace_id)
            for _, waiter in ipairs(failed) do answer(waiter, "", false, "unavailable", "start workspace host: " .. tostring(spawn_error)) end
            return
        end
        pids[tostring(pid)] = workspace_id
        hosts.started(state, workspace_id, tostring(pid))
    end
    local admit: (Waiter) -> ()
    admit = function(waiter: Waiter)
        local request = waiter.request
        if not hosts.host(state, request.workspace_id) then
            -- Another composition may already serve this workspace; the
            -- manager never starts a second host for it.
            local served = process.registry.lookup(HOST_PREFIX .. request.workspace_id)
            if served then answer(waiter, tostring(served), false, "", ""); return end
        end
        local decision = hosts.acquire(state, request.workspace_id, request.lease, waiter.sender)
        if decision.kind == "ready" then
            local host = hosts.host(state, request.workspace_id)
            answer(waiter, host and host.pid or "", true, "", "")
        elseif decision.kind == "wait" or decision.kind == "start" then
            local list: {Waiter} = waiters[request.workspace_id] or {}
            list[#list + 1] = waiter
            waiters[request.workspace_id] = list
            if decision.kind == "start" then start(request.workspace_id) end
        elseif decision.kind == "stopping" then
            queued[#queued + 1] = waiter
        elseif decision.kind == "evict" then
            queued[#queued + 1] = waiter
            stop(decision.evict or "")
        else
            answer(waiter, "", false, "busy", "every live workspace host is leased; the node allows " .. tostring(settings.cap))
        end
    end
    resume_queue = function()
        local pending = queued
        queued = {}
        for _, waiter in ipairs(pending) do
            if process.registry.lookup(waiter.request.lease) then admit(waiter) end
        end
    end
    local function exited(pid: string, result: unknown)
        local workspace_id = pids[pid]
        if not workspace_id then
            if monitored[pid] then
                monitored[pid] = nil
                hosts.holder_exited(state, pid, now())
            end
            return
        end
        pids[pid] = nil
        stops[workspace_id] = nil
        announcements[workspace_id] = nil
        local host = hosts.host(state, workspace_id)
        local failure = decode.exit_error(result)
        if host and host.phase == "starting" then
            local failed: {Waiter} = waiters[workspace_id] or {}
            waiters[workspace_id] = nil
            hosts.gone(state, workspace_id)
            local served = process.registry.lookup(HOST_PREFIX .. workspace_id)
            for _, waiter in ipairs(failed) do
                if served then answer(waiter, tostring(served), false, "", "")
                else answer(waiter, "", false, "unavailable", "workspace host did not start: " .. tostring(failure or "exited")) end
            end
        else
            if failure and host and host.phase ~= "stopping" then
                logger:warn("Workspace host exited", {workspace_id = workspace_id, error = failure})
            end
            hosts.gone(state, workspace_id)
        end
        resume_queue()
    end

    local function run()
        while true do
            local cases = {acquires:case_receive(), releases:case_receive(), ready:case_receive(), replies:case_receive(), events:case_receive(),
                attaches:case_receive(), client_requests:case_receive(), client_results:case_receive()}
            for _, subscription in ipairs(drained) do cases[#cases + 1] = subscription:case_receive() end
            local timer: time.Timer? = nil
            local deadline = hosts.next_deadline(state)
            if deadline then
                local delay = math.max(1, math.ceil((deadline - now()) * 1000))
                timer = assert(time.timer(tostring(delay) .. "ms"))
                cases[#cases + 1] = timer:channel():case_receive()
            end
            local selected = channel.select(cases)
            local expired = timer and selected.channel == timer:channel()
            if timer then timer:stop() end
            if not selected.ok then break end
            if expired then
                for _, workspace_id in ipairs(hosts.due(state, now())) do stop(workspace_id) end
            elseif selected.channel == events then
                local event = selected.value
                if event.kind == process.event.CANCEL then break end
                if event.kind == process.event.EXIT then exited(tostring(event.from), event.result) end
            elseif selected.channel == acquires then
                local message = selected.value
                local sender = tostring(message:from())
                local request = leases.acquire_request(message:payload():data())
                local holder = request and process.registry.lookup(request.lease)
                if request and holder and tostring(holder) == sender and hosts.held(state, request.lease) then
                    answer({sender = sender, request = request}, "", false, "request_conflict", "the lease already holds a workspace")
                elseif request and holder and tostring(holder) == sender then
                    if not monitored[sender] then
                        monitored[sender] = true
                        process.monitor(sender)
                    end
                    admit({sender = sender, request = request})
                elseif request then
                    answer({sender = sender, request = request}, "", false, "permission_denied", "the sender does not hold the lease it names")
                end
            elseif selected.channel == releases then
                local message = selected.value
                local lease = leases.release_request(message:payload():data())
                if lease and hosts.holder(state, lease) == tostring(message:from()) then hosts.release(state, lease, now()) end
            elseif selected.channel == ready then
                local message = selected.value
                local pid = tostring(message:from())
                local workspace_id = pids[pid]
                local announced = protocol.host(message:payload():data())
                if workspace_id and announced and announced.workspace_id == workspace_id then
                    announcements[workspace_id] = message:payload():data()
                    hosts.ready(state, workspace_id, now())
                    local list: {Waiter} = waiters[workspace_id] or {}
                    waiters[workspace_id] = nil
                    for _, waiter in ipairs(list) do answer(waiter, pid, true, "", "") end
                end
            elseif selected.channel == attaches then
                local message = selected.value
                local sender = tostring(message:from())
                local request = leases.attach_request(message:payload():data())
                local workspace_id = request and hosts.held(state, request.lease)
                if request and workspace_id and hosts.holder(state, request.lease) == sender then
                    local announcement = announcements[workspace_id]
                    if announcement ~= nil and hosts.attach(state, workspace_id, sender) then
                        process.send(sender, leases.ATTACHED, {version = 1, request_id = request.request_id, workspace_id = workspace_id,
                            error_code = "", error = "", ready = announcement})
                    else
                        process.send(sender, leases.ATTACHED, {version = 1, request_id = request.request_id, workspace_id = workspace_id,
                            error_code = "unavailable", error = "the workspace host is not ready"})
                    end
                end
            elseif selected.channel == client_requests then
                -- A desktop admission request from an attached holder, in the
                -- host's own format; the host answers its owner, this manager.
                local message = selected.value
                local sender = tostring(message:from())
                local data = message:payload():data()
                local workspace_id = type(data) == "table" and contract.workspace_id(data.workspace_id) or nil
                local request_id = type(data) == "table" and contract.text(data.request_id, 80) or nil
                local op = type(data) == "table" and contract.text(data.op, 40) or nil
                local recipient = type(data) == "table" and contract.text(data.recipient, 160) or nil
                local host = workspace_id and request_id and op and recipient
                    and hosts.relay(state, workspace_id, sender, request_id, op, recipient) or nil
                if host then
                    process.send(host, "bee.host.client", data)
                elseif workspace_id and request_id and op and recipient then
                    process.send(sender, "bee.host.client_result", {version = 1, workspace_id = workspace_id, request_id = request_id,
                        op = op, recipient = recipient, connection_id = "", error_code = "permission_denied",
                        error = "the sender is not attached to this workspace's host"})
                end
            elseif selected.channel == client_results then
                local message = selected.value
                local workspace_id = pids[tostring(message:from())]
                local data = message:payload():data()
                local result = workspace_id and protocol.client_result(data, workspace_id) or nil
                if workspace_id and result then
                    local released = result.error_code == "" or result.error_code == "not_found"
                    local holder = hosts.route(state, workspace_id, result.request_id, result.op, result.recipient, released)
                    if holder then process.send(holder, "bee.host.client_result", data) end
                end
            elseif selected.channel == replies then
                local message = selected.value
                local workspace_id = pids[tostring(message:from())]
                local reply = decode.reply(message:payload():data())
                if workspace_id and reply and reply.op == "shutdown" and stops[workspace_id] == reply.request_id
                    and reply.error_code ~= "" then
                    -- The host refused to stop, so its state may not be
                    -- checkpointed; it keeps serving.
                    stops[workspace_id] = nil
                    hosts.stop_refused(state, workspace_id)
                    resume_queue()
                    logger:warn("Workspace host refused an idle stop", {workspace_id = workspace_id, error = reply.error})
                end
            end
        end
    end
    local ok, err = pcall(run)
    -- Each host monitors this manager and runs its own shutdown when it exits.
    process.registry.unregister(leases.MANAGER)
    for _, subscription in ipairs({acquires, releases, ready, replies, attaches, client_requests, client_results}) do
        process.unlisten(subscription)
    end
    for _, subscription in ipairs(drained) do process.unlisten(subscription) end
    if not ok then error(err) end
end

return {main = main}
