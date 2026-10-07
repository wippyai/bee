-- MIT
local process = require("process")
local channel = require("channel")
local system = require("system")
local env = require("env")
local funcs = require("funcs")
local security = require("security")
local logger = require("logger")
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

local function serve(request: protocol.Forwarded, node: string): protocol.Reply
    local target = OPERATIONS[request.op]
    if not target then return protocol.fail("unknown approvals operation " .. request.op) end
    local peer = protocol.node_of(request.caller, node)
    local scope: {security.Policy} = {}
    for _, name in ipairs(PEER_POLICIES) do
        local policy, policy_error = security.policy(name)
        if not policy then return protocol.fail("peer policy unavailable: " .. tostring(policy_error)) end
        scope[#scope + 1] = policy
    end
    local caller = funcs.new():with_actor(security.new_actor(PEER_ACTOR .. peer, {node = peer}))
        :with_scope(security.new_scope(scope))
    local reply, call_error = caller:call(target, request.args)
    if call_error or type(reply) ~= "table" then
        return protocol.fail("approval owner outcome is unknown; read durable state before retrying")
    end
    return protocol.ok(reply)
end

local function idle()
    local events = assert(process.events())
    while true do
        local selected = channel.select({events:case_receive()})
        if not selected.ok or selected.value.kind == process.event.CANCEL then return end
    end
end

local function main()
    if env.get("bee:role") == "client" then return idle() end
    local node = assert(system.node.id())
    local registered, register_error = process.registry.register(NAME)
    if not registered then error("register approvals service: " .. tostring(register_error)) end
    local requests = assert(process.listen(protocol.FORWARD, {message = true}))
    local lifecycle = assert(process.events())
    local announced, announce_error = protocol.ready(NAME)
    if not announced then logger:warn("Hive supervisor not told the approvals service is ready", {error = announce_error}) end
    logger:info("Approvals hive ready", {node = node})
    while true do
        local selected = channel.select({lifecycle:case_receive(), requests:case_receive()})
        if selected.channel == lifecycle then
            if not selected.ok or selected.value.kind == process.event.CANCEL then return end
        elseif selected.channel == requests then
            if not selected.ok then return end
            local message = selected.value
            local request = protocol.forwarded(tostring(message:from()), message:payload():data())
            if request then
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
