-- MIT. Bounded acceptance for lazily started workspace hosts: the node host
-- manager starts a host on the first lease for its workspace, keeps it while
-- a lease holds it, stops it once it has been idle and its shutdown
-- checkpointed the workspace, starts it again from that checkpoint, and at
-- its cap stops the least recently used idle host to make room. A workspace
-- another composition serves stays that composition's.
local logger = require("logger")
local process = require("process")
local channel = require("channel")
local security = require("security")
local time = require("time")
local uuid = require("uuid")
local json = require("json")
local store = require("store")
local catalog = require("catalog")
local decode = require("decode")
local recovery = require("recovery")
local leases = require("leases")

local ROOT = "bee:workspace_root"
local IDLE_MS = 600
type Object = {[string]: unknown}
type Channel = channel.Channel

local function eq(actual: unknown, expected: unknown, what: string)
    if actual ~= expected then error(what .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual)) end
end

local function scope(names: {string}): security.Scope
    local policies: {security.Policy} = {}
    for _, name in ipairs(names) do policies[#policies + 1] = assert(security.policy(name)) end
    return security.new_scope(policies)
end

local function created(label: string, subpath: string): string
    local db = assert(store.database(nil))
    local tx = assert(db:begin())
    local row, failure = catalog.insert(tx, {label = label, root_ref = ROOT, subpath = subpath})
    if not row then
        tx:rollback(); db:release()
        error("create workspace: " .. tostring(failure and failure.message))
    end
    assert(tx:commit())
    db:release()
    return row.workspace_id
end

local function served(workspace_id: string): string?
    local pid = process.registry.lookup("bee.workspace.host/" .. workspace_id)
    return pid and tostring(pid) or nil
end

-- Poll the host name until it matches the expectation, bounded.
local function await_served(workspace_id: string, expected: boolean, budget: string): string?
    local deadline = time.after(budget)
    while true do
        local pid = served(workspace_id)
        if (pid ~= nil) == expected then return pid end
        local tick = time.after("50ms")
        local selected = channel.select({tick:case_receive(), deadline:case_receive()})
        if selected.channel == deadline then
            error("workspace " .. workspace_id .. (expected and " was not served" or " was still served") .. " within " .. budget)
        end
    end
end

local function applications(workspace_id: string): {Object}
    local handle = assert(store.open(nil, {workspace_id = workspace_id}))
    local encoded = handle:read()
    assert(handle:close())
    if not encoded then return {} end
    local value: unknown = json.decode(encoded)
    if type(value) ~= "table" or type(value.applications) ~= "table" then error("corrupt workspace state") end
    return value.applications :: {Object}
end

-- The fixture owns one host directly, as classic folder mode does, and opens
-- an automatically restarted application in it so the workspace has a
-- checkpoint to restore.
local function seed(workspace_id: string, events: Channel<process.Event>): (string, string)
    local ready = assert(process.listen("bee.host.ready", {message = true}))
    local replies = assert(process.listen("bee.app.reply", {message = true}))
    local checkpoints = assert(process.listen("bee.host.checkpoint", {message = true}))
    local self = tostring(process.pid())
    local host = tostring(assert(process.with_options({}):with_context({["bee.host_owner"] = self})
        :with_scope(scope({"bee.security.desktop:host_policy", "bee.security.desktop:host_spawn_policy", "bee.security.storage:workspace_storage_policy"}))
        :spawn_monitored("bee.host:main", "bee:workers", self, {workspace_id = workspace_id})))
    local function await(subscription: Channel<process.Message>, what: string, accept: (unknown) -> boolean): unknown
        local deadline = time.after("15s")
        while true do
            local selected = channel.select({subscription:case_receive(), events:case_receive(), deadline:case_receive()})
            if not selected.ok or selected.channel == deadline then error(what .. " timed out") end
            if selected.channel == events then
                local event = selected.value
                if event.kind == process.event.EXIT and tostring(event.from) == host then
                    error("seed host exited during " .. what .. ": " .. tostring(decode.exit_error(event.result)))
                end
            else
                local message = selected.value
                if tostring(message:from()) == host and accept(message:payload():data()) then return message:payload():data() end
            end
        end
    end
    await(ready, "seed readiness", function(_: unknown): boolean return true end)
    local open_id = "open-" .. uuid.v7()
    assert(process.send(host, "bee.app.request", {version = 1, request_id = open_id, op = "open", workspace_id = workspace_id,
        definition_id = "bee.settings:app", thread_id = "lazy-" .. uuid.v7()}))
    local opened = decode.reply(await(replies, "seed open", function(data: unknown): boolean
        local reply = decode.reply(data)
        return reply ~= nil and reply.request_id == open_id
    end))
    if not opened or opened.error_code ~= "" then error("seed open failed") end
    await(checkpoints, "seed checkpoint", function(data: unknown): boolean
        return type(data) == "table" and recovery.record(data.record) ~= nil
    end)
    local stop_id = "stop-" .. uuid.v7()
    assert(process.send(host, "bee.app.request", {version = 1, request_id = stop_id, op = "shutdown", workspace_id = workspace_id}))
    await(replies, "seed shutdown", function(data: unknown): boolean
        local reply = decode.reply(data)
        return reply ~= nil and reply.request_id == stop_id and reply.error_code == ""
    end)
    await_served(workspace_id, false, "10s")
    for _, subscription in ipairs({ready, replies, checkpoints}) do process.unlisten(subscription) end
    return host, opened.instance_id
end

local function main()
    local events = assert(process.events())
    local suffix = uuid.v7()
    local a = created("lazy a", "lazy-a-" .. suffix)
    local b = created("lazy b", "lazy-b-" .. suffix)
    local c = created("lazy c", "lazy-c-" .. suffix)
    local _, instance_id = seed(a, events)
    eq(#applications(a), 1, "seeded applications")

    local manager = tostring(assert(process.with_options({}):with_scope(scope({"bee.security.desktop:host_policy", "bee.security.desktop:local_supervisor_spawn_policy",
        "bee.security.desktop:workspace_host_manager_policy"})):spawn_monitored("bee.launch:host_manager", "bee:workers", {cap = 2, idle_ms = IDLE_MS})))
    local deadline = time.after("5s")
    while not process.registry.lookup(leases.MANAGER) do
        local selected = channel.select({time.after("20ms"):case_receive(), deadline:case_receive()})
        if selected.channel == deadline then error("host manager did not register") end
    end

    -- Start on open: the first lease starts the workspace host, which
    -- restores the checkpointed application.
    local first = assert(leases.acquire(a, "15s"))
    eq(first.managed, true, "first lease is managed")
    eq(served(a), first.host, "first host serves the workspace")

    -- A leased host outlives the idle period.
    time.sleep(tostring(IDLE_MS * 2) .. "ms")
    eq(served(a), first.host, "leased host after the idle period")

    -- Idle stop: released, it stops after the idle period, keeping its checkpoint.
    leases.release(first)
    await_served(a, false, "10s")
    local kept = applications(a)
    eq(#kept, 1, "applications after the idle stop")
    eq(kept[1].instance_id, instance_id, "the checkpointed application")

    -- Restore after stop: a new lease starts a new host from that checkpoint.
    local again = assert(leases.acquire(a, "15s"))
    if again.host == first.host then error("the workspace was served by the stopped host") end
    eq(served(a), again.host, "restarted host serves the workspace")
    eq(#applications(a), 1, "applications after the restart")

    -- Cap eviction: with A leased and B idle, C takes B's place.
    local lease_b = assert(leases.acquire(b, "15s"))
    leases.release(lease_b)
    -- Release is queued at the manager. A definite busy answer can arrive
    -- before it processes that release; retry only busy within the original
    -- 15-second acquire budget. An unknown outcome is never retried.
    local started_ms = time.now():unix_nano() / 1000000
    local lease_c: leases.Lease? = nil
    while true do
        local remaining = 15000 - (time.now():unix_nano() / 1000000 - started_ms)
        if remaining <= 0 then error("C was not admitted after B's release within 15s") end
        local refusal: string?
        lease_c, refusal = leases.acquire(c, tostring(math.ceil(remaining)) .. "ms")
        if lease_c then break end
        if not refusal or not refusal:find("^busy:") then error("C lease refused: " .. tostring(refusal)) end
        local tick = time.after("20ms")
        local deadline = time.after(tostring(math.ceil(remaining)) .. "ms")
        local selected = channel.select({tick:case_receive(), deadline:case_receive()})
        if selected.channel == deadline then error("C was not admitted after B's release within 15s") end
    end
    await_served(b, false, "10s")
    eq(served(c), lease_c.host, "C serves after eviction")
    eq(served(a), again.host, "leased A survives the eviction")

    -- Every live host leased: a third workspace is refused, not forced in.
    local refused, refusal = leases.acquire(b, "15s")
    eq(refused, nil, "lease beyond the cap")
    if not tostring(refusal):find("busy", 1, true) then error("unexpected refusal: " .. tostring(refusal)) end

    -- A workspace another composition serves stays that composition's.
    leases.release(lease_c)
    await_served(c, false, "10s")
    local self = tostring(process.pid())
    local ready = assert(process.listen("bee.host.ready", {message = true}))
    local direct = tostring(assert(process.with_options({}):with_context({["bee.host_owner"] = self})
        :with_scope(scope({"bee.security.desktop:host_policy", "bee.security.desktop:host_spawn_policy", "bee.security.storage:workspace_storage_policy"}))
        :spawn_monitored("bee.host:main", "bee:workers", self, {workspace_id = b})))
    await_served(b, true, "10s")
    local external = assert(leases.acquire(b, "15s"))
    eq(external.managed, false, "externally served lease")
    eq(external.host, direct, "externally served host")
    leases.release(external)
    process.terminate(direct)
    process.unlisten(ready)
    await_served(b, false, "10s")

    leases.release(again)
    await_served(a, false, "10s")
    process.terminate(manager)
    local stopped = time.after("5s")
    while true do
        local selected = channel.select({events:case_receive(), stopped:case_receive()})
        if not selected.ok or selected.channel == stopped then break end
        local event = selected.value
        if event.kind == process.event.EXIT and tostring(event.from) == manager then break end
    end
    logger:info("ACCEPTANCE VERIFIED: lazy workspace hosts start on open, stop when idle, restore and evict at the cap")
end

return {main = function()
    local ok, cause = pcall(main)
    if not ok then
        logger:error("Lazy workspace hosts acceptance failed", {cause = tostring(cause)})
        error(cause)
    end
end}
