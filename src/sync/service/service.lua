-- MIT. The Sync service: one process per node that receives immutable
-- replicas other nodes deliver and distributes this node's exported feeds.
--
-- Receipt: operations arrive only from this node's Hive supervisor with the
-- caller's authenticated PID. The caller's node becomes the actor of the
-- replica receive operation, and the peer policy lets that actor deliver only
-- replicas its own node owns. Receipt writes into an inert cache only.
--
-- Distribution runs one worker per destination. A worker runs when something
-- can move its destination forward: an event committed to an exported feed of
-- this node (the feeds' change capture), a node joining or leaving the hive, a
-- registry change to exports or receiver routes, and the service's own start.
-- A request to a receiver that is restarting waits at its node's supervisor
-- until the receiver is ready. Another node is a destination while its
-- receiver holds its hive-wide name; until it does, the worker waits for that
-- name. Each run is announced on the event bus as DISTRIBUTED with the cursor
-- the destination reached.
local worker = require("worker")
local process = require("process")
local channel = require("channel")
local system = require("system")
local env = require("env")
local funcs = require("funcs")
local security = require("security")
local logger = require("logger")
local eventbus = require("events")
local cdc = require("cdc")
local protocol = require("protocol")
local distributor = require("distributor")
local replica_protocol = require("replica_protocol")

type Worker = {destination: distributor.Destination, name: string, wake: channel.Channel, stopped: boolean}

local CHANGES = "bee:changes"
local DISTRIBUTED = "distributed"
-- WAIT_SLICE bounds one wait for a receiver's name; the worker waits again
-- until the name is bound or the destination is gone.
local WAIT_SLICE = "60s"

-- changes opens the capture of events committed to Sync feeds.
local function changes()
    local stream, err = cdc.stream(CHANGES, {tables = {"bee_sync_events"}, ops = {"insert"}})
    if not stream then error("capture sync feed changes: " .. tostring(err)) end
    return stream
end

local function load(): ({[string]: distributor.Export}?, string?)
    local listed, err = distributor.exports()
    if not listed then return nil, err end
    local exports: {[string]: distributor.Export} = {}
    for _, export in ipairs(listed) do exports[export.feed] = export end
    return exports, nil
end

local OPERATION = "bee.sync.binding:replica_receive"
local PEER_POLICY = "bee.sync.security:replica_peer"

local function receive(request: protocol.Forwarded, node: string): protocol.Reply
    if request.op ~= "receive" then return protocol.fail("unknown sync operation " .. request.op) end
    local peer = protocol.node_of(request.caller, node)
    local policy, policy_error = security.policy(PEER_POLICY)
    if not policy then return protocol.fail("replica receipt policy unavailable: " .. tostring(policy_error)) end
    local caller = funcs.new():with_actor(security.new_actor("bee.sync.peer." .. peer, {node = peer}))
        :with_scope(security.new_scope({policy}))
    local reply, call_error = caller:call(OPERATION, request.args)
    if call_error or type(reply) ~= "table" then
        return protocol.fail("replica owner outcome is unknown; read durable status before retrying")
    end
    local arguments = request.args
    if reply.ok == true and type(arguments) == "table" and arguments.action == "finish" and type(arguments.feed) == "string" then
        eventbus.send("bee.sync", "feed.changed", arguments.feed, {source_owner = arguments.source_owner, version_key = arguments.version_key})
    end
    return protocol.ok(reply)
end

-- idle keeps an in-memory client's Sync service without serving: a client keeps
-- no feeds and no store of its own.
local idle = worker.idle

local function main()
    if env.get("bee:role") == "client" then return idle() end
    local node = assert(system.node.id())
    local name = replica_protocol.RECEIVER
    local registered, register_error = process.registry.register(name)
    if not registered then error("register sync receiver: " .. tostring(register_error)) end
    if protocol.clustered() then
        local published, publish_error = process.registry.register(name .. "/" .. node, process.pid(), process.registry.EVENTUAL)
        if not published then error("publish sync receiver: " .. tostring(publish_error)) end
    end
    local requests = assert(process.listen(protocol.FORWARD, {message = true}))
    local lifecycle = assert(process.events())
    local committed_stream = changes()
    local committed = assert(committed_stream:channel())
    local joins = assert(eventbus.subscribe("cluster", "node.joined")):channel()
    local departures = assert(eventbus.subscribe("cluster", "node.left")):channel()
    local registry_changes = assert(eventbus.subscribe("registry", "registry.commit")):channel()
    local exports = assert(load())
    local workers: {[string]: Worker} = {}

    -- reachable waits until a remote worker's receiver holds its hive-wide
    -- name, and reports false when the worker stops first.
    local function reachable(worker: Worker): boolean
        if worker.destination.node == node then return true end
        local name = worker.name .. "/" .. worker.destination.node
        while not worker.stopped do
            if process.registry.lookup(name, process.registry.EVENTUAL, {timeout = WAIT_SLICE}) then return true end
        end
        return false
    end

    local function run(worker: Worker)
        while true do
            local _, ok = worker.wake:receive()
            if not ok or worker.stopped then return end
            if reachable(worker) then
                for feed, export in pairs(exports) do
                    local result = distributor.distribute(node, worker.destination, export)
                    if result.ok then
                        local value: unknown = result.value
                        eventbus.send("bee.sync", DISTRIBUTED, feed, {node = worker.destination.node,
                            route = worker.destination.route, cursor = type(value) == "table" and value.cursor or nil})
                    else
                        logger:warn("Sync distribution stopped", {feed = feed, node = worker.destination.node,
                            route = worker.destination.route, code = result.code, error = result.message})
                    end
                end
            end
        end
    end

    local function wake(worker: Worker)
        channel.select({worker.wake:case_send(true), default = true})
    end

    -- destinations lists every receiver route on every other node, and the
    -- receiver routes on this node other than its own store.
    local function destinations(): ({[string]: Worker}?, string?)
        local nodes: {string} = {node}
        if protocol.clustered() then
            for _, member in ipairs(system.cluster.members() or {}) do
                if type(member.id) == "string" and member.id ~= node then nodes[#nodes + 1] = member.id end
            end
        end
        local found: {[string]: Worker} = {}
        local receivers, receivers_error = distributor.receivers()
        if not receivers then return nil, receivers_error end
        for _, receiver in ipairs(receivers) do
            for _, target in ipairs(nodes) do
                if target ~= node or receiver.name ~= replica_protocol.RECEIVER then
                    local destination = {node = target, route = receiver.prefix}
                    found[distributor.key(destination)] = {destination = destination, name = receiver.name,
                        wake = channel.new(1), stopped = false}
                end
            end
        end
        return found, nil
    end

    -- refresh starts workers for new destinations, stops those of removed
    -- ones and wakes every worker.
    local function refresh(): string?
        local found, found_error = destinations()
        if not found then return found_error end
        for key, worker in pairs(workers) do
            if not found[key] then
                worker.stopped = true
                worker.wake:close()
                workers[key] = nil
            end
        end
        for key, candidate in pairs(found) do
            local worker = workers[key]
            if not worker then
                worker = candidate
                workers[key] = worker
                coroutine.spawn(function() run(worker) end)
            end
            wake(worker)
        end
        return nil
    end

    local refreshed = refresh()
    if refreshed then error("Sync destinations are unavailable: " .. refreshed) end
    local announced, announce_error = protocol.ready(name)
    if not announced then logger:warn("Hive supervisor not told the sync receiver is ready", {error = announce_error}) end
    logger:info("Sync ready", {node = node})
    while true do
        local selected = channel.select({lifecycle:case_receive(), requests:case_receive(), committed:case_receive(),
            joins:case_receive(), departures:case_receive(), registry_changes:case_receive()})
        if selected.channel == lifecycle then
            if not selected.ok or selected.value.kind == process.event.CANCEL then return end
        elseif selected.channel == requests then
            if not selected.ok then return end
            local message = selected.value
            local request = protocol.forwarded(tostring(message:from()), message:payload():data())
            if request then
                local handled, outcome = pcall(receive, request, node)
                if not handled then
                    logger:error("Sync replica receipt failed", {error = tostring(outcome)})
                    outcome = protocol.fail("receive failed: " .. tostring(outcome))
                end
                process.send(request.caller, request.reply_topic, outcome)
            end
        elseif selected.channel == committed then
            if not selected.ok then
                committed_stream:close()
                committed_stream = changes()
                committed = assert(committed_stream:channel())
                local failed = refresh()
                if failed then logger:warn("Sync kept its destinations after failed discovery", {error = failed}) end
            else
                local after: unknown = selected.value.after
                if type(after) == "table" and after.owner_id == node and type(after.feed) == "string" and exports[after.feed] then
                    for _, worker in pairs(workers) do wake(worker) end
                end
            end
        elseif selected.channel == joins or selected.channel == departures then
            if not selected.ok then return end
            local failed = refresh()
            if failed then logger:warn("Sync kept its destinations after failed discovery", {error = failed}) end
        elseif selected.channel == registry_changes then
            if not selected.ok then return end
            local loaded, load_error = load()
            if loaded then
                exports = loaded
                local failed = refresh()
                if failed then logger:warn("Sync kept its destinations after failed discovery", {error = failed}) end
            else
                logger:warn("Sync kept its exports after failed discovery", {error = load_error})
            end
        end
    end
end

return {main = main}
