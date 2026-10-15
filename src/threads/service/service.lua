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
local time = require("time")
local pump_config = require("pump_config")
local outbox = require("outbox")
local worker = require("worker")
local alias_retirements = require("alias_retirements")

local CHANGES = "bee:changes"
local NAME = "bee.threads"
local PEER_ACTOR = "bee.threads.peer."
local PEER_POLICY = "bee.threads.security:peer"
local OPERATION = "bee.threads.binding:"
-- MAX_FORWARDED bounds the forwarded operations in flight; a watch holds one
-- for up to its wait.
local MAX_FORWARDED = 32
local PEER_OPERATIONS: {[string]: boolean} = {send = true, send_status = true, notify = true, watch = true, inbox_send = true, inbox_reply = true, inbox_resolve = true, inbox_describe = true}

-- changes opens the capture of records committed to thread stores.
local function changes()
    local stream, err = cdc.stream(CHANGES, {tables = {"bee_thread_records", "bee_thread_inbox_outbox", "bee_thread_app_alias_retirements"}, ops = {"insert", "update"}})
    if not stream then error("capture thread commits: " .. tostring(err)) end
    return stream
end

local function with_store(action: (sql.DB) -> ())
    local db, err = database.open()
    if not db then
        logger:warn("Threads store unavailable", {error = err})
        return
    end
    local handled, problem = pcall(action, db)
    db:release()
    if not handled then error(problem) end
end

local function retire_aliases()
    with_store(function(db: sql.DB)
        local err = alias_retirements.drain(db)
        if err then logger:error("Application alias retirement pending", {error = err}) end
    end)
end

local function settle(thread_id: string?)
    with_store(function(db: sql.DB)
        local err = notices.fire(db, thread_id)
        if err then logger:warn("Threads notices not settled", {thread = thread_id, error = err}) end
    end)
end

-- CDC is a bounded live feed. Reopening it precedes this durable scan so
-- commits during the scan remain observable. Each captured head is announced
-- only after its notices settle, including records lost with an old stream.
local function recover_commits(active: () -> boolean): boolean
    if not active() then return false end
    with_store(function(db: sql.DB)
        local cursor = ""
        while active() do
            local heads, read_error = db:query([[SELECT thread_id, head_sequence FROM bee_thread_heads
                WHERE thread_id > ? ORDER BY thread_id LIMIT 128]], {cursor})
            if not active() then return end
            if not heads then error("read committed thread heads: " .. tostring(read_error)) end
            for _, head in ipairs(heads) do
                if not active() then return end
                local thread_id = tostring(head.thread_id)
                local problem = notices.fire(db, thread_id)
                if not active() then return end
                if problem then error("settle recovered thread commits: " .. problem) end
                local sequence = assert(tonumber(head.head_sequence))
                if sequence > 0 then
                    assert(eventbus.send(commits.system(thread_id), commits.KIND, thread_id, {sequence = sequence}))
                end
                cursor = thread_id
            end
            if #heads < 128 then return end
        end
    end)
    return active()
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
local idle = worker.idle

local function run(active: () -> boolean, stopped: channel.Channel<boolean>)
    local node = assert(system.node.id())
    local registered, register_error = process.registry.register(NAME)
    if not registered then error("register threads service: " .. tostring(register_error)) end
    local db, open_error = database.open()
    if not db then error(open_error) end
    local incarnation, establish_error = owner.establish(db)
    db:release()
    if not incarnation then error(establish_error) end
    local requests = assert(process.listen(protocol.FORWARD, {message = true}))
    local capture = changes()
    local committed = capture:channel()
    local function serve()
        local pumping, pumping_error = pump_config.enabled()
        if pumping == nil then error(pumping_error) end
        local pump_executor = funcs.new():with_actor(security.new_actor("bee.threads.pump"))
            :with_scope(assert(security.named_scope("bee.threads.security:pump_scope")))
        local pumping_round: funcs.Future? = nil
        local pump_due: integer? = nil
        local pump_retry = worker.RETRY_FIRST_MS
        local function schedule_pump()
            if not pumping then return end
            local store, problem = database.open()
            local due: integer? = nil
            if store then due, problem = outbox.next_deadline(store); store:release() end
            if problem then
                logger:error("Forwarding schedule unreadable", {cause = tostring(problem)})
                pump_due = math.floor(time.now():unix_nano() / 1000000) + pump_retry
                pump_retry = math.min(pump_retry * 2, worker.RETRY_LAST_MS)
            else pump_due = due end
        end
        schedule_pump()
        local inflight = 0
        if not recover_commits(active) then return end
        retire_aliases()
        local announced, announce_error = protocol.ready(NAME)
        if not announced then logger:warn("Hive supervisor not told the threads service is ready", {error = announce_error}) end
        logger:info("Threads ready", {node = node, incarnation = incarnation})
        while active() do
            if not pumping_round and pump_due and pump_due <= math.floor(time.now():unix_nano() / 1000000) then
                pumping_round = assert(pump_executor:async("bee.threads.service:pump_worker"))
            end
            local cases = {stopped:case_receive(), requests:case_receive(), committed:case_receive()}
            local pumped = pumping_round and pumping_round:response() or nil
            if pumped then cases[#cases + 1] = pumped:case_receive()
            elseif pump_due then
                cases[#cases + 1] = time.after(tostring(math.max(1, pump_due - math.floor(time.now():unix_nano() / 1000000))) .. "ms"):case_receive()
            end
            local selected = channel.select(cases)
            if selected.channel == pumped and pumping_round then
                local _, problem = pumping_round:result()
                pumping_round = nil
                if problem then
                    logger:error("Forwarding pump round failed", {cause = tostring(problem)})
                    pump_due = math.floor(time.now():unix_nano() / 1000000) + pump_retry
                    pump_retry = math.min(pump_retry * 2, worker.RETRY_LAST_MS)
                else pump_retry = worker.RETRY_FIRST_MS; schedule_pump() end
            elseif selected.channel == stopped then
                return
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
            elseif selected.channel == committed then
                schedule_pump()
                if not selected.ok then
                    if not active() then return end
                    capture:close()
                    capture = changes()
                    committed = capture:channel()
                    if not recover_commits(active) then return end
                    retire_aliases()
                else
                    if selected.value.table == "bee_thread_app_alias_retirements" then retire_aliases() end
                    local after: unknown = selected.value.after
                    if selected.value.table == "bee_thread_records" and selected.value.op == "insert" and type(after) == "table" and type(after.thread_id) == "string" then
                        settle(after.thread_id)
                        eventbus.send(commits.system(after.thread_id), commits.KIND, after.thread_id, {sequence = after.sequence})
                    end
                end
            end
        end
    end
    local handled, problem = pcall(serve)
    capture:close()
    if not handled then error(problem) end
end

local function main()
    if env.get("bee:role") == "client" then return idle() end
    local lifecycle = assert(process.events())
    local stopped: channel.Channel<boolean> = channel.new(1)
    local cancelled = false
    local function active(): boolean return not cancelled end
    coroutine.spawn(function()
        while true do
            local selected = channel.select({lifecycle:case_receive()})
            if not selected.ok or selected.value.kind == process.event.CANCEL then
                cancelled = true
                stopped:send(true)
                return
            end
        end
    end)
    local handled, problem = pcall(run, active, stopped)
    lifecycle:close()
    if not handled then error(problem) end
end

return {main = main}
