-- MIT. The Threads service: one process per node that owns what must outlive
-- a call.
--
-- Incarnation: at start it advances the store's owner incarnation, which every
-- claim and subscription carries; a claim or subscription of an earlier
-- incarnation is fenced out.
--
-- Commits: it follows the records the store commits (the store's change
-- capture). Each commit settles the one-shot notices that watch its thread,
-- so a notice is delivered whoever committed the ending record, and is then
-- announced on the event bus for the waits blocked on that thread. A notice
-- delivered is a record on its watcher's thread and is announced the same way.
--
-- Peers: the node's Hive supervisor hands it operations other nodes send to
-- the threads route. The caller's node becomes the actor, under a scope that
-- reaches only the forwarded operations; the thread's own membership decides
-- what that actor may do.
local process = require("process")
local sql = require("sql")
local channel = require("channel")
local system = require("system")
local env = require("env")
local funcs = require("funcs")
local security = require("security")
local logger = require("logger")
local eventbus = require("events")
local cdc = require("cdc")
local protocol = require("protocol")
local database = require("database")
local owner = require("owner")
local notices = require("notices")
local commits = require("commits")

local CHANGES = "bee:changes"
local NAME = "bee.threads"
local PEER_ACTOR = "bee.threads.peer."
local PEER_POLICY = "bee.threads.security:peer"
local OPERATION = "bee.threads.binding:"
-- MAX_FORWARDED bounds the forwarded operations in flight; a watch holds one
-- for up to its wait.
local MAX_FORWARDED = 32
local PEER_OPERATIONS: {[string]: boolean} = {send = true, send_status = true, notify = true, watch = true}

-- changes opens the capture of records committed to thread stores.
local function changes()
    local stream, err = cdc.stream(CHANGES, {tables = {"bee_thread_records"}, ops = {"insert"}})
    if not stream then error("capture thread commits: " .. tostring(err)) end
    return stream:channel()
end

local function with_store(action: (sql.DB) -> ())
    local db, err = database.open()
    if not db then
        logger:warn("Threads store unavailable", {error = err})
        return
    end
    action(db)
    db:release()
end

local function settle(thread_id: string?)
    with_store(function(db: sql.DB)
        local err = notices.fire(db, thread_id)
        if err then logger:warn("Threads notices not settled", {thread = thread_id, error = err}) end
    end)
end

local function forward(request: protocol.Forwarded, node: string): protocol.Reply
    if not PEER_OPERATIONS[request.op] then return protocol.fail("unknown threads operation " .. request.op) end
    local peer = protocol.node_of(request.caller, node)
    local args: {[string]: unknown} = {}
    for name, value in pairs(request.args) do args[name] = value end
    if args.caller_node_id ~= nil and args.caller_node_id ~= peer then
        return protocol.fail("caller_node_id does not match the authenticated caller node")
    end
    args.caller_node_id = peer
    local policy, policy_error = security.policy(PEER_POLICY)
    if not policy then return protocol.fail("peer policy unavailable: " .. tostring(policy_error)) end
    local caller = funcs.new():with_actor(security.new_actor(PEER_ACTOR .. peer, {node = peer}))
        :with_scope(security.new_scope({policy}))
    local reply, call_error = caller:call(OPERATION .. request.op, args)
    if call_error or type(reply) ~= "table" then
        return protocol.fail("thread owner outcome is unknown; read durable status before retrying")
    end
    return protocol.ok(reply)
end

-- idle keeps a client's Threads service without serving: a client keeps no
-- thread store of its own.
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
    if not registered then error("register threads service: " .. tostring(register_error)) end
    local db, open_error = database.open()
    if not db then error(open_error) end
    local incarnation, establish_error = owner.establish(db)
    db:release()
    if not incarnation then error(establish_error) end
    local requests = assert(process.listen(protocol.FORWARD, {message = true}))
    local lifecycle = assert(process.events())
    local committed = changes()
    local inflight = 0
    settle(nil)
    local announced, announce_error = protocol.ready(NAME)
    if not announced then logger:warn("Hive supervisor not told the threads service is ready", {error = announce_error}) end
    logger:info("Threads ready", {node = node, incarnation = incarnation})
    while true do
        local selected = channel.select({lifecycle:case_receive(), requests:case_receive(), committed:case_receive()})
        if selected.channel == lifecycle then
            if not selected.ok or selected.value.kind == process.event.CANCEL then return end
        elseif selected.channel == requests then
            if not selected.ok then return end
            local message = selected.value
            local request = protocol.forwarded(tostring(message:from()), message:payload():data())
            if request then
                if inflight >= MAX_FORWARDED then
                    process.send(request.caller, request.reply_topic, protocol.fail("threads service is busy"))
                else
                    inflight = inflight + 1
                    coroutine.spawn(function()
                        local handled, outcome = pcall(forward, request, node)
                        if not handled then
                            logger:error("Threads forwarded operation failed", {error = tostring(outcome)})
                            outcome = protocol.fail("forward failed: " .. tostring(outcome))
                        end
                        inflight = inflight - 1
                        process.send(request.caller, request.reply_topic, outcome)
                    end)
                end
            end
        else
            if not selected.ok then
                committed = changes()
                settle(nil)
            else
                local after: unknown = selected.value.after
                if type(after) == "table" and type(after.thread_id) == "string" then
                    settle(after.thread_id)
                    eventbus.send(commits.system(after.thread_id), commits.KIND, after.thread_id, {sequence = after.sequence})
                end
            end
        end
    end
end

return {main = main}
