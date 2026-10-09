-- MIT. The node's Hive supervisor: holds the node's mesh-wide supervisor name
-- and hands every operation to the node-local service its prefix routes to,
-- with the caller's authenticated PID. It reaches each service by the PID the
-- service announced when it became ready (or, for services already running
-- when the supervisor starts, the PID their name resolves to then) and
-- monitors it; a service that exits is forgotten until it announces again.
-- A request for a service that is not running (starting or restarting)
-- waits, up to PARKED per service, until the service tells the supervisor it
-- is ready. A request the caller stopped waiting for is dropped, never
-- delivered. Routes are registry entries of type protocol.ROUTE, so any
-- installed module can expose operations on the Hive.
local process = require("process")
local channel = require("channel")
local system = require("system")
local registry = require("registry")
local logger = require("logger")
local protocol = require("protocol")
local eventbus = require("events")
local time = require("time")
local receiver = require("receiver")
local bounds = require("bounds")
local remote = require("remote")
local cdc = require("cdc")
local demand = require("demand")
local demand_owner = require("demand_owner")

type Completion = {request: protocol.Forwarded, reply: protocol.Reply?, complete: boolean}

-- routes maps each route prefix to the node-local service name that serves it.
local function routes(): {[string]: string}
    local found: {[string]: string} = {}
    for _, entry in ipairs(registry.find({["meta.type"] = protocol.ROUTE}) or {}) do
        local data: unknown = entry.data
        if type(data) == "table" and type(data.prefix) == "string" and type(data.name) == "string" then found[data.prefix] = data.name end
    end
    return found
end

local PARKED = 64

local function main()
    local node = assert(system.node.id())
    local registered, register_error = process.registry.register(protocol.SUPERVISOR)
    if not registered then error("register supervisor: " .. tostring(register_error)) end
    if protocol.clustered() then
        local published, publish_error = process.registry.register(protocol.supervisor_name(node), process.pid(), process.registry.EVENTUAL)
        if not published then error("publish supervisor: " .. tostring(publish_error)) end
    end
    logger:info("Hive supervisor ready", {node = node})
    local calls = assert(process.listen(protocol.CALL, {message = true}))
    local readiness = assert(process.listen(protocol.READY, {message = true}))
    local events = assert(process.events())
    local parked: {[string]: {protocol.Forwarded}} = {}
    local applications: {protocol.Forwarded} = {}
    local active = 0
    local completions = channel.new(receiver.MAX_ACTIVE * 2)
    -- services holds the PID serving each routed service name, and names the
    -- service name each monitored PID serves.
    local services: {[string]: string} = {}
    local names: {[string]: string} = {}
    -- The routes, read again when a registry change commits.
    local registry_changes = assert(eventbus.subscribe("registry", "registry.commit")):channel()
    local routing = routes()
    local demanded = demand_owner.discover(nil)
    local demands = assert(process.listen(demand.TOPIC, {message = true}))
    local supervised = assert(eventbus.subscribe("supervisor", "service.update")):channel()

    local function expired(request: protocol.Forwarded): boolean
        return request.expires <= time.now():unix_nano()
    end

    local function application_call(request: protocol.Forwarded)
        if expired(request) then return end
        if request.op ~= receiver.CALL then
            if active >= receiver.MAX_ACTIVE then
                if #applications >= receiver.MAX_QUEUED then process.send(request.caller, request.reply_topic, protocol.fail("application queue is full"))
                else applications[#applications + 1] = request end
                return
            end
            active = active + 1
            local output = channel.new(1)
            coroutine.spawn(function()
                local handler = request.op == "application.discover" and remote.discover or remote.tests
                local ok, reply = pcall(handler, request.args, request.caller, node)
                output:send(ok and reply or protocol.fail(tostring(reply)))
            end)
            coroutine.spawn(function()
                local deadline = assert(time.after(tostring(math.max(1, math.floor(request.expires - time.now():unix_nano()))) .. "ns"))
                local selected = channel.select({output:case_receive(), deadline:case_receive()})
                if selected.channel == deadline then
                    completions:send({request = request, reply = protocol.fail("application deadline reached; outcome unknown"), complete = false})
                    output:receive()
                    completions:send({request = request, reply = nil, complete = true})
                else
                    completions:send({request = request, reply = selected.value, complete = true})
                end
            end)
            return
        end
        local invocation, admission_error = receiver.authorize(request.args, request.caller, node)
        if not invocation then
            process.send(request.caller, request.reply_topic, protocol.fail(tostring(admission_error)))
            return
        end
        if active >= receiver.MAX_ACTIVE then
            if #applications >= receiver.MAX_QUEUED then
                process.send(request.caller, request.reply_topic, protocol.fail("application queue is full"))
            else
                applications[#applications + 1] = request
            end
            return
        end
        local fresh, replay, claim_error = receiver.claim(invocation)
        if not fresh then
            process.send(request.caller, request.reply_topic, replay or protocol.fail(tostring(claim_error)))
            return
        end
        local future, call_error = receiver.start(invocation)
        if not future then
            process.send(request.caller, request.reply_topic, receiver.save(invocation, protocol.fail(tostring(call_error))))
            return
        end
        local remaining = math.floor(request.expires - time.now():unix_nano())
        local deadline = assert(time.after(tostring(math.max(1, remaining)) .. "ns"))
        active = active + 1
        local response = future:response()
        coroutine.spawn(function()
            local selected = channel.select({response:case_receive(), deadline:case_receive()})
            if selected.channel == deadline then
                completions:send({request = request, reply = protocol.fail("application deadline reached; outcome unknown"), complete = false})
                response:receive()
                receiver.save(invocation, receiver.finish(invocation, future))
                completions:send({request = request, reply = nil, complete = true})
            else
                completions:send({request = request, reply = receiver.save(invocation, receiver.finish(invocation, future)), complete = true})
            end
        end)
    end

    local function serve(name: string, pid: string)
        local previous = services[name]
        if previous == pid then return end
        if previous then
            names[previous] = nil
            process.unmonitor(previous)
        end
        services[name] = pid
        names[pid] = name
        process.monitor(pid)
    end

    local function forget(pid: string)
        local name = names[pid]
        if not name then return end
        names[pid] = nil
        if services[name] == pid then services[name] = nil end
    end

    -- adopt records the routed services already running, by their node-local
    -- names; it runs when the supervisor starts and when routes change.
    local function adopt()
        for _, name in pairs(routing) do
            if not services[name] then
                local pid = process.registry.lookup(name, process.registry.LOCAL)
                if pid then serve(name, tostring(pid)) end
            end
        end
    end

    local function deliver(name: string, request: protocol.Forwarded)
        if expired(request) then return end
        local pid = services[name]
        if demanded[name] and demand_owner.available(demanded, name) then
            demand_owner.wake(demanded, name, {caller = request.caller, data = {hive = request}})
            return
        end
        if pid and not demanded[name] then
            if protocol.forward(pid, request) then return end
            -- The service exited before its exit event reached the supervisor.
            forget(pid)
        end
        local waiting: {protocol.Forwarded} = {}
        for _, held in ipairs(parked[name] or {}) do
            if not expired(held) then waiting[#waiting + 1] = held end
        end
        if #waiting >= PARKED then
            process.send(request.caller, request.reply_topic, protocol.fail(name .. " is not running"))
            return
        end
        waiting[#waiting + 1] = request
        parked[name] = waiting
        demand_owner.wake(demanded, name, nil)
    end

    -- ready records the process that announced it serves name; only the
    -- process holding name on this node may announce it.
    local function ready(from: string, data: unknown)
        if type(data) ~= "table" or type(data.name) ~= "string" then return end
        local holder = process.registry.lookup(data.name, process.registry.LOCAL)
        if not holder or tostring(holder) ~= from then return end
        serve(data.name, from)
        demand_owner.ready(demanded, data.name, from)
        local waiting = parked[data.name]
        parked[data.name] = nil
        for _, request in ipairs(waiting or {}) do deliver(data.name, request) end
    end

    adopt()
    local backlog_stream = assert(cdc.stream("bee:changes", {tables = demand_owner.tables(demanded), ops = {"insert", "update", "delete"}}))
    local backlog = backlog_stream:channel()
    demand_owner.recover(demanded, nil)
    while true do
        local selected = channel.select({calls:case_receive(), readiness:case_receive(), events:case_receive(),
            registry_changes:case_receive(), completions:case_receive(), demands:case_receive(), supervised:case_receive(), backlog:case_receive()})
        if not selected.ok then return end
        if selected.channel == backlog then
            local change: unknown = selected.value
            if type(change) == "table" and type(change.table) == "string" then
                demand_owner.recover(demanded, change.table)
            end
        elseif selected.channel == demands then
            local message = selected.value
            demand_owner.receive(demanded, tostring(message:from()), message:payload():data())
        elseif selected.channel == supervised then
            demand_owner.update(demanded)
        elseif selected.channel == registry_changes then
            demanded = demand_owner.discover(demanded)
            backlog_stream:close()
            backlog_stream = assert(cdc.stream("bee:changes", {tables = demand_owner.tables(demanded), ops = {"insert", "update", "delete"}}))
            backlog = backlog_stream:channel()
            routing = routes()
            adopt()
        elseif selected.channel == events then
            local event = selected.value
            if event.kind == process.event.CANCEL then return end
            if event.kind == process.event.EXIT or event.kind == process.event.MONITOR_DOWN then
                forget(tostring(event.from))
                demand_owner.exit(demanded, tostring(event.from))
            end
        elseif selected.channel == readiness then
            local message = selected.value
            ready(tostring(message:from()), message:payload():data())
        elseif selected.channel == calls then
            local message = selected.value
            local caller = tostring(message:from())
            local data: unknown = message:payload():data()
            if type(data) == "table" and type(data.op) == "string" and type(data.reply_topic) == "string"
                and type(data.ttl) == "number" then
                local args: {[string]: unknown} = {}
                if type(data.args) == "table" then args = data.args end
                local expires, deadline_error = protocol.deadline(math.floor(time.now():unix_nano()), data.ttl, data.deadline_ns)
                if not expires then
                    process.send(caller, data.reply_topic, protocol.fail(deadline_error or "invalid Hive deadline"))
                elseif data.op == receiver.CALL or data.op == "application.discover" or data.op == "application.tests" then
                    local extra = bounds.fields(data, {"op", "args", "reply_topic", "ttl", "deadline_ns"})
                    if extra or data.ttl ~= data.ttl or data.ttl <= 0 or data.ttl > receiver.MAX_TTL then
                        process.send(caller, data.reply_topic, protocol.fail(extra or "application deadline exceeds its bound"))
                    else
                        application_call({op = data.op, args = args, caller = caller, reply_topic = data.reply_topic,
                            expires = expires})
                    end
                else
                    local prefix, op = data.op:match("^([^.]+)%.(.+)$")
                    local name = prefix and routing[prefix]
                    if not name or not op then
                        process.send(caller, data.reply_topic, protocol.fail("unknown operation " .. data.op))
                    else
                        deliver(name, {op = op, args = args, caller = caller, reply_topic = data.reply_topic, expires = expires})
                    end
                end
            end
        else
            local completed = selected.value :: Completion
            if completed.reply then
                process.send(completed.request.caller, completed.request.reply_topic, completed.reply)
            end
            if completed.complete then
                active = active - 1
                while active < receiver.MAX_ACTIVE and #applications > 0 do
                    application_call(assert(table.remove(applications, 1)))
                end
            end
        end
    end
end

return {main = main}
