-- MIT. Bounded acceptance for desktops attached through the node host
-- manager: a retained desktop supervisor selected by workspace identity takes
-- a lease, so the manager starts the workspace host; the supervisor admits its
-- display and an attached recipient through the manager, which owns the host;
-- ending the supervisor releases the lease and the host stops once idle.
local logger = require("logger")
local process = require("process")
local channel = require("channel")
local security = require("security")
local time = require("time")
local uuid = require("uuid")
local store = require("store")
local catalog = require("catalog")
local leases = require("leases")
local registry = require("registry")

local ROOT = "bee.env:workspace_root"
local IDLE_MS = 600
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

local function await_served(workspace_id: string, expected: boolean, budget: string): string?
    local deadline = time.after(budget)
    while true do
        local pid = served(workspace_id)
        if (pid ~= nil) == expected then return pid end
        local selected = channel.select({time.after("50ms"):case_receive(), deadline:case_receive()})
        if selected.channel == deadline then
            error("workspace " .. workspace_id .. (expected and " was not served" or " was still served") .. " within " .. budget)
        end
    end
end

local function await(subscription: Channel<process.Message>, events: Channel<process.Event>, sender: string, what: string,
    accept: (unknown) -> boolean): unknown
    local deadline = time.after("20s")
    while true do
        local selected = channel.select({subscription:case_receive(), events:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then error(what .. " timed out") end
        if selected.channel == events then
            local event = selected.value
            if event.kind == process.event.EXIT and tostring(event.from) == sender then
                error("desktop supervisor exited during " .. what .. ": " .. tostring(event.result))
            end
        else
            local message = selected.value
            local data = message:payload():data()
            if tostring(message:from()) == sender and accept(data) then return data end
        end
    end
end

local function run(fallback: boolean)
    local events = assert(process.events())
    local self = tostring(process.pid())
    local workspace_id = created("attach", "attach-" .. uuid.v7())
    local ready = assert(process.listen("bee.retained.ready", {message = true}))
    local results = assert(process.listen("bee.retained.result", {message = true}))
    local upgrades = assert(process.listen("bee.retained.host_upgraded", {message = true}))
    local replacements = assert(process.listen("bee.retained.host_replaced", {message = true}))
    local clients = assert(process.listen("bee.retained.replaced", {message = true}))

    local manager = tostring(assert(process.with_options({}):with_scope(scope({"bee.security.desktop:host_policy", "bee.security.desktop:local_supervisor_spawn_policy",
        "bee.security.desktop:workspace_host_manager_policy"})):spawn_monitored("bee.launch:host_manager", "bee:workers", {cap = 2, idle_ms = IDLE_MS})))
    local registered = time.after("5s")
    while not process.registry.lookup(leases.MANAGER) do
        local selected = channel.select({time.after("20ms"):case_receive(), registered:case_receive()})
        if selected.channel == registered then error("host manager did not register") end
    end
    eq(served(workspace_id), nil, "a host before any lease")

    -- The retained desktop supervisor the desktop bridge would start for this
    -- workspace, with the bridge's spawn scope.
    local supervisor = tostring(assert(process.with_options({}):with_context({["bee.retained_owner"] = self})
        :with_scope(scope({"bee.security.desktop:host_policy", "bee.security.desktop:desktop_policy", "bee.security.desktop:retained_supervisor_spawn_policy", "bee.security.desktop:desktop_catalog_policy",
            "bee.security.desktop:desktop_catalog_resource_policy", "bee.security.desktop:workspace_host_lease_policy"}))
        :spawn_monitored("bee.launch:retained", "bee:workers", self, {workspace_id = workspace_id})))
    local announced = await(ready, events, supervisor, "desktop readiness", function(data: unknown): boolean
        return type(data) == "table" and data.workspace_id == workspace_id
    end) :: {[string]: unknown}
    local desktop_id = tostring(announced.desktop_id)

    -- The lease started the host; the manager serves it, not the supervisor.
    local host = await_served(workspace_id, true, "5s")
    local external = assert(leases.acquire(workspace_id, "10s"))
    eq(external.managed, true, "the workspace host is the node's")
    eq(external.host, host, "the leased host")
    leases.release(external)

    -- A recipient attaches to the display through the relayed admission.
    local recipient = tostring(assert(process.spawn("bee.workspace.hosts:attach_recipient", "bee:workers")))
    local attach_id = "attach-" .. uuid.v7()
    assert(process.send(supervisor, "bee.retained.request", {version = 1, workspace_id = workspace_id, desktop_id = desktop_id,
        request_id = attach_id, recipient = recipient, op = "attach", mode = "observe"}))
    local attached = await(results, events, supervisor, "attachment", function(data: unknown): boolean
        return type(data) == "table" and data.request_id == attach_id
    end) :: {[string]: unknown}
    eq(attached.error_code, "", "attachment refusal " .. tostring(attached.error))
    if type(attached.mount) ~= "string" or attached.mount == "" then error("attachment has no mount") end
    local definition = assert(registry.get("bee.host:main"))
    definition.meta.handoff_probe = "leased-host-definition-changed"
    local changes = assert(registry.snapshot()):changes()
    changes:update(definition)
    assert(changes:apply())
    if fallback then
        local replaced = await(replacements, events, supervisor, "leased host replacement", function(data: unknown): boolean
            return type(data) == "table" and data.version == 1 and data.schema == 1
                and data.workspace_id == workspace_id and type(data.host) == "string" and data.host ~= host
        end) :: {[string]: unknown}
        host = tostring(replaced.host)
        eq(served(workspace_id), host, "leased host replacement registration")
        await(clients, events, supervisor, "leased desktop reattachment", function(data: unknown): boolean
            return type(data) == "table" and data.version == 1 and data.schema == 1
                and data.workspace_id == workspace_id and data.display_id == desktop_id
        end)
    else
        await(upgrades, events, supervisor, "leased host upgrade", function(data: unknown): boolean
            return type(data) == "table" and data.version == 1 and data.schema == 1
                and data.workspace_id == workspace_id and data.host == host
        end)
        eq(served(workspace_id), host, "same-PID leased host after definition change")
    end
    local detach_id = "detach-" .. uuid.v7()
    assert(process.send(supervisor, "bee.retained.request", {version = 1, workspace_id = workspace_id, desktop_id = desktop_id,
        request_id = detach_id, recipient = recipient, op = "detach"}))
    local detached = await(results, events, supervisor, "detachment", function(data: unknown): boolean
        return type(data) == "table" and data.request_id == detach_id
    end) :: {[string]: unknown}
    eq(detached.error_code, "", "detachment refusal " .. tostring(detached.error))
    process.terminate(recipient)

    -- The leased host outlives its idle period while the supervisor holds it.
    time.sleep(tostring(IDLE_MS * 2) .. "ms")
    eq(served(workspace_id), host, "host while the desktop supervisor holds its lease")

    -- Ending the desktop supervisor ends its lease; the host stops once idle.
    process.terminate(supervisor)
    local ended = time.after("10s")
    while true do
        local selected = channel.select({events:case_receive(), ended:case_receive()})
        if not selected.ok or selected.channel == ended then error("desktop supervisor did not stop") end
        local event = selected.value
        if event.kind == process.event.EXIT and tostring(event.from) == supervisor then break end
    end
    await_served(workspace_id, false, "10s")

    process.terminate(manager)
    for _, subscription in ipairs({ready, results, upgrades, replacements, clients}) do process.unlisten(subscription) end
    logger:info("ACCEPTANCE VERIFIED: desktops attach through the host manager: a lease starts the host, admission is relayed, the host stops after release")
end

local function main(fallback: boolean?)
    local ok, err = pcall(run, fallback == true)
    if not ok then
        logger:error("ACCEPTANCE FAILED", {error = tostring(err)})
        error(err)
    end
end

return {main = main, fallback = function() main(true) end}
