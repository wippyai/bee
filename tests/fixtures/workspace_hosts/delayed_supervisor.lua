-- MIT. Focused regression for an open that finishes after the host's
-- uncertainty deadline. The test seeds one settled origin assignment, then
-- verifies the late success claims the new view without a second dispatch.
local process = require("process")
local channel = require("channel")
local security = require("security")
local time = require("time")
local logger = require("logger")
local contract = require("contract")
local decode = require("decode")
local persistence = require("persistence")

local function spawn_host(owner: string): string
    local host_policy = assert(security.policy("bee:host_policy"))
    local spawn_policy = assert(security.policy("bee:host_spawn_policy"))
    local storage_policy = assert(security.policy("bee.workspace_hosts:first_storage_policy"))
    local scope = security.new_scope({host_policy, spawn_policy, storage_policy})
    return tostring(assert(process.with_options({}):with_context({["bee.host_owner"] = owner})
        :with_scope(scope):spawn_monitored("bee.host:main", "bee:workers", owner, "bee.workspace.db:first")))
end

local function main()
    local owner = tostring(process.pid())
    local ready = assert(process.listen("bee.host.ready", {message = true}))
    local replies = assert(process.listen("bee.app.reply", {message = true}))
    local application_replies = assert(process.listen("bee.host.application.reply", {message = true}))
    local host = spawn_host(owner)
    local workspace_id = ""
    local deadline = time.after("10s")
    while workspace_id == "" do
        local selected = channel.select({ready:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then error("delayed host did not become ready") end
        local data: unknown = selected.value:payload():data()
        if tostring(selected.value:from()) == host and type(data) == "table" and data.version == 1 then
            workspace_id = contract.workspace_id(data.workspace_id) or ""
        end
    end

    assert(process.send(host, "bee.app.request", {version = 1, request_id = "origin-open", op = "open",
        workspace_id = workspace_id, definition_id = "bee.workspace_hosts:delayed"}))
    local origin_id, origin_instance = "", ""
    deadline = time.after("10s")
    while origin_id == "" do
        local selected = channel.select({replies:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then error("origin open did not reply") end
        if tostring(selected.value:from()) == host then
            local result = decode.reply(selected.value:payload():data())
            if result and result.request_id == "origin-open" then
                if result.error_code ~= "" then error("origin open failed: " .. result.error) end
                origin_id, origin_instance = result.id, result.instance_id
            end
        end
    end

    local database = assert(persistence.open("bee.workspace.db:first"))
    local claimed = assert(database.assignments:claim({view_id = origin_id, instance_id = origin_instance, display_id = "display-late"}))
    assert(claimed.display_id == "display-late")

    local token = "bee.application.open/00000000-0000-7000-8000-000000000001"
    assert(process.registry.register(token))
    -- Runtime opens carry the gateway's approved-trait provenance; this
    -- regression's stub broker records none of it.
    local provenance = {thread_id = "delayed-thread", subject = "workspace_hosts.delayed_supervisor",
        initiating_owner = "workspace_hosts.delayed_supervisor", binding_id = "delayed-binding",
        access_approval_id = "delayed-approval", access_proposal_digest = string.rep("a", 64),
        surface_revision = 1, surface_digest = string.rep("b", 64)}
    local request = {version = 1, workspace_id = workspace_id, request_id = "late-open",
        definition_id = "bee.workspace_hosts:delayed", arguments = {}, caller_token = token,
        origin_view = {view_id = origin_id, instance_id = origin_instance}, provenance = provenance}
    assert(process.send(host, "bee.host.application", request))
    local uncertain = false
    deadline = time.after("35s")
    while not uncertain do
        local selected = channel.select({application_replies:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then error("open did not become uncertain") end
        if tostring(selected.value:from()) == host then
            local data: unknown = selected.value:payload():data()
            if type(data) == "table" and data.request_id == "late-open" then
                local nested = type(data.reply) == "table" and data.reply or nil
                if nested and nested.error_code == "uncertain" then uncertain = true end
            end
        end
    end

    -- A retry after uncertainty must not dispatch a second broker request.
    assert(process.send(host, "bee.host.application", request))
    deadline = time.after("2s")
    local selected = channel.select({application_replies:case_receive(), deadline:case_receive()})
    assert(selected.ok and selected.channel ~= deadline, "expired retry did not answer")
    local data: unknown = selected.value:payload():data()
    assert(tostring(selected.value:from()) == host)
    if type(data) ~= "table" or data.request_id ~= "late-open" then error("invalid retry reply") end
    local nested = type(data.reply) == "table" and data.reply or nil
    assert(nested and nested.error_code == "uncertain", "retry redispatched unresolved open")

    deadline = time.after("5s")
    while true do
        local current = database.assignments:get({view_id = "late-view", instance_id = "late-instance"})
        if current then
            assert(current.assignment.display_id == "display-late", "late success lost originating display assignment")
            break
        end
        local tick = assert(time.timer("100ms"))
        local waited = channel.select({tick:channel():case_receive(), deadline:case_receive()})
        tick:stop()
        if not waited.ok or waited.channel == deadline then error("late success lost originating display assignment") end
    end

    -- A duplicate broker reply would be routed to the owner after settlement.
    deadline = time.after("500ms")
    local duplicate = channel.select({replies:case_receive(), deadline:case_receive()})
    if duplicate.ok and duplicate.channel ~= deadline then
        local result = decode.reply(duplicate.value:payload():data())
        assert(not result or result.request_id ~= "late-open", "late open was dispatched twice")
    end

    process.terminate(host)
    database:close()
    process.registry.unregister(token)
    process.unlisten(ready); process.unlisten(replies); process.unlisten(application_replies)
    logger:info("ACCEPTANCE VERIFIED: late open retained display assignment without redispatch")
end

local function run()
    local ok, failure = pcall(main)
    if not ok then
        logger:error("Delayed open regression: " .. tostring(failure))
        error(failure)
    end
end

return {main = run}
