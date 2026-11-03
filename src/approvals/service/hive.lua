-- MIT
local worker = require("worker")
local process = require("process")
local channel = require("channel")
local system = require("system")
local env = require("env")
local funcs = require("funcs")
local security = require("security")
local logger = require("logger")
local events = require("events")
local bounds = require("bounds")
local protocol = require("protocol")

local NAME = "bee.approvals"
local PEER_ACTOR = "bee.approvals.peer."
local PEER_POLICIES = {"bee.security.approvals:approval_hive_peer", "bee.security.approvals:approval_hive_peer_decide"}
local OPERATIONS: {[string]: string} = {
    feed_snapshot = "bee.approvals.binding:feed_snapshot",
    feed_read_after = "bee.approvals.binding:feed_read_after",
    read = "bee.approvals.binding:read",
    decide = "bee.approvals.binding:decide",
    decide_batch = "bee.approvals.binding:decide_batch",
    withdraw = "bee.approvals.binding:withdraw",
    grant_window = "bee.approvals.binding:grant_window",
}

-- CHANGED is the topic a watching inbox hears when an approval of the
-- workspace it watches changes on this owner; the message names only the
-- workspace, and the watcher reads what changed through the feed.
local CHANGED = "bee.approvals.changed"
local ATTENTION = "bee.attention"
local DECIDE = "bee.approvals.decide"
local MAX_WATCHERS = 64
type Watcher = {pid: string, workspace_id: string}

local function peer(request: protocol.Forwarded, node: string): (security.Actor?, security.Scope?, string?)
    local name = protocol.node_of(request.caller, node)
    local scope: {security.Policy} = {}
    for _, policy_name in ipairs(PEER_POLICIES) do
        local policy, policy_error = security.policy(policy_name)
        if not policy then return nil, nil, "peer policy unavailable: " .. tostring(policy_error) end
        scope[#scope + 1] = policy
    end
    return security.new_actor(PEER_ACTOR .. name, {node = name}), security.new_scope(scope), nil
end

local function serve(request: protocol.Forwarded, node: string): protocol.Reply
    local target = OPERATIONS[request.op]
    if not target then return protocol.fail("unknown approvals operation " .. request.op) end
    local actor, scope, peer_error = peer(request, node)
    if not actor or not scope then return protocol.fail(tostring(peer_error)) end
    local caller = funcs.new():with_actor(actor):with_scope(scope)
    local reply, call_error = caller:call(target, request.args)
    if call_error or type(reply) ~= "table" then
        return protocol.fail("approval owner outcome is unknown; read durable state before retrying")
    end
    return protocol.ok(reply)
end

local idle = worker.idle

local function main()
    if env.get("bee:role") == "client" then return idle() end
    local node = assert(system.node.id())
    local registered, register_error = process.registry.register(NAME)
    if not registered then error("register approvals service: " .. tostring(register_error)) end
    local requests = assert(process.listen(protocol.FORWARD, {message = true}))
    local lifecycle = assert(process.events())
    local attention = assert(events.subscribe(ATTENTION))
    local announced_changes = attention:channel()
    local watchers: {[string]: Watcher} = {}
    local count = 0
    -- watch: a peer's inbox hears each change of a workspace whose requests
    -- the peer may read and decide, for as long as its process lives.
    local function watch(request: protocol.Forwarded): protocol.Reply
        local workspace = bounds.id(request.args.workspace_id)
        if not workspace then return protocol.fail("watch names a workspace") end
        local actor, scope, peer_error = peer(request, node)
        if not actor or not scope then return protocol.fail(tostring(peer_error)) end
        if scope:evaluate(actor, DECIDE, workspace) ~= "allow" then return protocol.fail("peer may not read this workspace inbox") end
        local key = request.caller .. "\n" .. workspace
        if not watchers[key] then
            if count >= MAX_WATCHERS then return protocol.fail("approval watchers are full") end
            local monitored, monitor_error = process.monitor(request.caller)
            if not monitored then return protocol.fail("watcher cannot be monitored: " .. tostring(monitor_error)) end
            watchers[key] = {pid = request.caller, workspace_id = workspace}
            count = count + 1
        end
        return protocol.ok({owner = process.pid(), workspace_id = workspace})
    end
    local function forget(pid: string)
        for key, watcher in pairs(watchers) do
            if watcher.pid == pid then watchers[key] = nil; count = count - 1 end
        end
        process.unmonitor(pid)
    end
    local announced, announce_error = protocol.ready(NAME)
    if not announced then logger:warn("Hive supervisor not told the approvals service is ready", {error = announce_error}) end
    logger:info("Approvals hive ready", {node = node})
    while true do
        local selected = channel.select({lifecycle:case_receive(), requests:case_receive(), announced_changes:case_receive()})
        if selected.channel == lifecycle then
            if not selected.ok or selected.value.kind == process.event.CANCEL then attention:close(); return end
            if selected.value.kind == process.event.EXIT or selected.value.kind == process.event.MONITOR_DOWN then forget(tostring(selected.value.from)) end
        elseif selected.channel == announced_changes then
            if not selected.ok then return end
            local workspace = bounds.id(selected.value.path)
            for _, watcher in pairs(watchers) do
                if watcher.workspace_id == workspace then process.send(watcher.pid, CHANGED, {node = node, workspace_id = workspace}) end
            end
        elseif selected.channel == requests then
            if not selected.ok then return end
            local message = selected.value
            local request = protocol.forwarded(tostring(message:from()), message:payload():data())
            if request and request.op == "watch" then
                local handled, outcome = pcall(watch, request)
                if not handled then outcome = protocol.fail("watch failed: " .. tostring(outcome)) end
                process.send(request.caller, request.reply_topic, outcome)
            elseif request then
                local handled, outcome = pcall(serve, request, node)
                if not handled then
                    logger:error("Approvals forwarded operation failed", {error = tostring(outcome)})
                    outcome = protocol.fail("forward failed: " .. tostring(outcome))
                end
                process.send(request.caller, request.reply_topic, outcome)
            end
        end
    end
end

return {main = main}
