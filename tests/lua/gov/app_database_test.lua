-- MIT. An application with its own database, end to end through delivery: an
-- agent authors and delivers a pack declaring app.database, a migration and
-- an agent tool; the person approves the installation in Needs you, reading
-- the migration it runs; Bee installs the database, runs the migration and
-- exposes the application. The application and the agent tool then share
-- the table. A later version appends a migration that runs forward only.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local json = require("json")
local time = require("time")
local env = require("env")
local system = require("system")
local client = require("client")
local principal = require("principal")
local application = require("application")

-- The suite delivers the guide's example under an overlay of its own, so no
-- other suite's copy of the example shares its owner.
local OVERLAY = "countdb"
local NAMESPACE = "app." .. OVERLAY
local APP = NAMESPACE .. ":app"
type Object = {[string]: unknown}

-- The guide's own example: the counter with its counts database, first
-- migration and agent tools, exactly as an agent reads it.
local function first_version(): {Object}
    local entries: {Object} = {}
    for _, entry in ipairs(guide.example()) do entries[#entries + 1] = entry end
    for _, entry in ipairs(guide.database_example()) do entries[#entries + 1] = entry end
    local encoded = assert(json.encode(entries))
    local renamed = encoded:gsub(guide.NAMESPACE:gsub("%p", "%%%0"), NAMESPACE)
    return assert(json.decode(renamed)) :: {Object}
end

-- A later version appends ordinal 2 and lists the column it adds.
local NOTE = {id = NAMESPACE .. ":add_note", kind = "function.lua",
    meta = {type = "migration", target_db = guide.DATABASE_NAME, ordinal = 2},
    data = {source = (guide.MIGRATION_SOURCE:gsub("CREATE TABLE counts %(value INTEGER NOT NULL%)",
        "ALTER TABLE counts ADD COLUMN note TEXT NOT NULL DEFAULT 'kept'"):gsub("DROP TABLE IF EXISTS counts", "SELECT 1")),
        method = "run", imports = {migration = "wippy.migration:migration"}}}
local function second_version(): {Object}
    local entries: {Object} = {}
    for _, raw in ipairs(first_version()) do
        local entry: Object = {}
        for key, value in pairs(raw) do entry[key] = value end
        if entry.id == NAMESPACE .. ":count_list" then
            local data: Object = {}
            for key, value in pairs(assert(bounds.object(entry.data))) do data[key] = value end
            data.source = (guide.COUNTS_SOURCE:gsub("SELECT value FROM counts", "SELECT value, note FROM counts")
                :gsub("values%[index%] = row.value", "values[index] = tostring(row.value) .. \":\" .. tostring(row.note)"))
            entry.data = data
        end
        if entry.id == APP then
            local meta: Object = {}
            for key, value in pairs(assert(bounds.object(entry.meta))) do meta[key] = value end
            local application: Object = {}
            for key, value in pairs(assert(bounds.object(meta.application))) do application[key] = value end
            application.revision = "2"
            meta.application = application
            entry.meta = meta
        end
        entries[#entries + 1] = entry
    end
    entries[#entries + 1] = NOTE
    return entries
end

-- A workspace on the machine home folder no display watches, so the
-- approvals this suite raises present the Inbox on no desktop.
local function isolated(): string
    local path = assert(env.get("bee.env:machine_home"))
    local added, err = client.call(assert(system.node.id()), "workspace_add", {path = path, label = "notesdb"})
    if not added then error("workspace_add: " .. tostring(err)) end
    return tostring(added.workspace)
end

local function author(workspace: string): funcs.Executor
    local actor = assert(security.new_actor("bee.tests.notesdb_author", {workspace_id = workspace}))
    local scope = security.new_scope({assert(security.policy("bee.security.gateway:gateway_tool_overlay_policy")),
        assert(security.policy("bee.security.gateway:gateway_tool_delivery_policy"))})
    return funcs.new():with_actor(actor):with_scope(scope)
end

local function reply(raw: unknown, err: unknown): Object
    if err then error(tostring(err)) end
    return assert(bounds.object(raw))
end

local function value(answer: Object): Object
    if answer.ok ~= true then
        local fault = bounds.object(answer.error) or {}
        error(tostring(fault.code or answer.code) .. ": " .. tostring(fault.message or answer.message))
    end
    return assert(bounds.object(answer.value))
end

-- deliver writes the pack into the agent's overlay, freezes it and requests
-- delivery of the frozen snapshot.
local function deliver(writer: funcs.Executor, workspace: string, entries: {Object}, version: string): Object
    local listed = value(reply(writer:call("bee.gov.binding:overlay_call", {operation = "list"})))
    local revision = 0
    for _, raw in ipairs((listed.overlays or {}) :: {unknown}) do
        local row = assert(bounds.object(raw))
        if row.overlay_id == OVERLAY then revision = math.floor(tonumber(row.revision) or 0) end
    end
    if revision == 0 then
        revision = math.floor(tonumber(value(reply(writer:call("bee.gov.binding:overlay_call", {operation = "create",
            overlay_id = OVERLAY, expected_revision = 0, idempotency_key = OVERLAY .. "-create"}))).revision) or 0)
    end
    local put = value(reply(writer:call("bee.gov.binding:overlay_call", {operation = "put", overlay_id = OVERLAY,
        expected_revision = revision, idempotency_key = OVERLAY .. "-put-" .. version, path = "entries.json",
        content = assert(json.encode(entries))})))
    local frozen = value(reply(writer:call("bee.gov.binding:overlay_call", {operation = "freeze", overlay_id = OVERLAY,
        expected_revision = put.revision, idempotency_key = OVERLAY .. "-freeze-" .. version})))
    return reply(writer:call("bee.gov.binding:delivery_call", {operation = "request", workspace_id = workspace,
        source_overlay_id = OVERLAY, version = version, snapshot_digest = frozen.digest}))
end

local function inbox(workspace: string): funcs.Executor
    local identity = assert(principal.value(workspace, "notesdb-inbox", "bee.approvals.inbox.app:app", "1", 1))
    return funcs.new():with_actor(assert(security.new_actor(identity.id, identity.metadata)))
end

-- approve reads what Needs you shows for the installation and approves it.
local function approve(workspace: string, approval_id: unknown): Object
    local person = inbox(workspace)
    local read = value(reply(person:call("bee.approvals.binding:read", {approval_id = approval_id})))
    value(reply(person:call("bee.approvals.binding:decide", {approval_id = approval_id,
        expected_revision = read.revision, decision = "approved", proposal_digest = read.proposal_digest})))
    return read
end

-- installed runs the activation worker's pass the suites run themselves and
-- reads the delivery status until the activation settles.
local function installed(writer: funcs.Executor, workspace: string, version: string, intent_id: unknown): Object
    local worker = funcs.new():with_actor(assert(security.new_actor("bee.gov.activation")))
    local drained, drain_error = worker:call("bee.tests.gov:activation_drain_probe", {})
    if drain_error then error(tostring(drain_error)) end
    local last: Object? = nil
    for _ = 1, 8 do
        local status = value(reply(writer:call("bee.gov.binding:delivery_call", {operation = "status",
            workspace_id = workspace, source_overlay_id = OVERLAY, version = version, intent_id = intent_id})))
        local activation = bounds.object(status.activation)
        if activation and activation.phase == "settled" then
            if activation.outcome ~= "applied" then
                error("activation of " .. version .. " settled " .. tostring(activation.outcome) .. ": " .. tostring(json.encode(drained)))
            end
            return activation
        end
        last = activation
        time.sleep("250ms")
    end
    error("activation of " .. version .. " did not settle: " .. tostring(json.encode(last)) .. " after " .. tostring(json.encode(drained)))
end

local function as_application(workspace: string, target: string, arguments: Object): Object
    local definition = assert(application.definition(APP))
    local actor = assert(application.actor(workspace, "notesdb-test", definition, 1))
    local scope = assert(application.scope(definition, workspace))
    return value(reply(funcs.new():with_actor(actor):with_scope(scope):call(target, arguments)))
end

local function as_agent(workspace: string, tool: string, arguments: Object): Object
    local actor = assert(security.new_actor("bee.tests.notesdb_agent", {workspace_id = workspace}))
    local scope = security.new_scope({assert(security.policy("bee.security.gateway:gateway_tool_app_tools_policy"))})
    return value(reply(funcs.new():with_actor(actor):with_scope(scope):call("bee.node.binding:app_tool_call",
        {tool = tool, arguments = arguments})))
end

local function counts(listed: Object): string
    local found: {string} = {}
    for _, value in ipairs(listed.counts :: {unknown}) do found[#found + 1] = tostring(value) end
    return table.concat(found, ",")
end

local function define_tests()
    test.describe("application database through delivery", function()
        test.it("installs the database, runs its migrations forward only and shares the table with agents", function()
            local workspace = isolated()
            local writer = author(workspace)

            local first = value(deliver(writer, workspace, first_version(), "1.0.0"))
            test.eq(first.pending_migrations, 1)
            test.eq(first.activation_phase, "approval_bound")
            local shown = approve(workspace, first.approval_id)
            local proposal = assert(bounds.object((assert(bounds.object(shown.proposal))).payload))
            local migrations = assert(bounds.array(proposal.migrations, 8))
            test.eq((assert(bounds.object(migrations[1]))).id, NAMESPACE .. ":create_counts")
            test.eq((assert(bounds.object(migrations[1]))).target_db, guide.DATABASE_NAME)
            local prompt = tostring((assert(bounds.object(shown.prompt))).text)
            test.eq(prompt:sub(1, #("Install " .. guide.TITLE .. " 1.0.0?")), "Install " .. guide.TITLE .. " 1.0.0?")
            test.is_true(prompt:find("It runs 1 database migration: " .. NAMESPACE .. ":create_counts on counts.", 1, true) ~= nil)
            test.eq(installed(writer, workspace, "1.0.0", first.intent_id).outcome, "applied")

            as_application(workspace, NAMESPACE .. ":count_record", {value = 1})
            test.eq(as_agent(workspace, "counter_record", {value = 2}).recorded, 2)
            test.eq(counts(as_application(workspace, NAMESPACE .. ":count_list", {})), "1,2")

            local second = value(deliver(writer, workspace, second_version(), "1.0.1"))
            test.eq(second.pending_migrations, 1)
            test.eq(second.activation_phase, "approval_bound")
            local upgrade = approve(workspace, second.approval_id)
            local upgrade_payload = assert(bounds.object((assert(bounds.object(upgrade.proposal))).payload))
            local upgrade_migrations = assert(bounds.array(upgrade_payload.migrations, 8))
            test.eq(#upgrade_migrations, 1)
            test.eq((assert(bounds.object(upgrade_migrations[1]))).id, NAMESPACE .. ":add_note")
            test.eq(installed(writer, workspace, "1.0.1", second.intent_id).outcome, "applied")
            test.eq(counts(as_agent(workspace, "counter_list", {})), "1:kept,2:kept")
        end)
    end)
end
return test.run_cases(define_tests)
