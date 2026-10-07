-- MIT. An application with its own database, end to end through delivery: an
-- agent authors and delivers a pack declaring app.database, a migration and
-- an agent tool and a test; the person approves the installation in Needs you, reading
-- the migration it runs; Bee installs the database, runs the migration and
-- exposes the application. The agent lists and runs the pack's test through
-- the tests tool. The application and the agent tool then share
-- the table. A later version appends a migration that runs forward only; going
-- back past it is refused, going back to a version that defines it runs none,
-- and removing the application keeps its data for the next install. A node
-- restart after a contained upgrade, after going back and after removal boots
-- with the application as it was and its data kept.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local json = require("json")
local application = require("application")
local harness = require("harness")
local registry = require("registry")
local time = require("time")
local workspace_applications = require("workspace_applications")
local http_client = require("http_client")
local launch_policy = require("launch_policy")
local principals = require("principals")

-- The suite delivers the guide's example under an overlay of its own, so no
-- other suite's copy of the example shares its owner.
local OVERLAY = "countdb"
local NAMESPACE = "app." .. OVERLAY
local APP = NAMESPACE .. ":app"
-- A menu no display places, so the installed application stays out of the
-- Start panel later display suites read.
local MENU = "bee.tests.gov:unplaced_menu"
type Object = {[string]: unknown}

-- The guide's own example: the counter with its counts database, first
-- migration and agent tools, exactly as an agent reads it.
local function first_version(): {Object}
    local entries: {Object} = {}
    for _, entry in ipairs(guide.example()) do entries[#entries + 1] = entry end
    for _, entry in ipairs(guide.database_example()) do entries[#entries + 1] = entry end
    for _, entry in ipairs(guide.test_example()) do entries[#entries + 1] = entry end
    local encoded = assert(json.encode(entries))
    -- The node's test runner finds application tests by app_test in the
    -- suites' composition, so the suites' own runner leaves them alone.
    local renamed = encoded:gsub(guide.NAMESPACE:gsub("%p", "%%%0"), NAMESPACE)
        :gsub("bee%.shell:apps_menu", MENU):gsub('"type":"test"', '"type":"app_test"')
    return assert(json.decode(renamed)) :: {Object}
end

-- A later version appends ordinal 2 and lists the column it adds.
local NOTE = {id = NAMESPACE .. ":add_note", kind = "function.lua",
    meta = {type = "migration", target_db = guide.DATABASE_NAME, ordinal = 2},
    data = {source = (guide.MIGRATION_SOURCE:gsub("CREATE TABLE counts %(value INTEGER NOT NULL%)",
        "ALTER TABLE counts ADD COLUMN note TEXT NOT NULL DEFAULT 'kept'"):gsub("DROP TABLE IF EXISTS counts", "SELECT 1")),
        method = "run", imports = {migration = "wippy.migration:migration"}}}
local function revised(entries: {Object}, revision: string): {Object}
    for _, entry in ipairs(entries) do
        if entry.id == APP then
            local meta = assert(bounds.object(entry.meta))
            assert(bounds.object(meta.application)).revision = revision
        end
    end
    return entries
end
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

local function as_application(workspace: string, target: string, arguments: Object): Object
    local definition = assert(application.definition(APP))
    local actor = assert(application.actor(workspace, "notesdb-test", definition, 1))
    local scope = assert(application.scope(definition, workspace))
    return harness.value(harness.reply(funcs.new():with_actor(actor):with_scope(scope):call(target, arguments)))
end

local function as_agent(workspace: string, tool: string, arguments: Object): Object
    local actor = assert(security.new_actor("bee.tests.notesdb_agent", {workspace_id = workspace}))
    local scope = security.new_scope({assert(security.policy("bee.security.gateway:gateway_tool_app_tools_policy"))})
    return harness.value(harness.reply(funcs.new():with_actor(actor):with_scope(scope):call("bee.node.binding:app_tool_call",
        {tool = tool, arguments = arguments})))
end

-- as_tester calls the tests tool as the authoring agent, scoped exactly as the
-- gateway's tests tool.
local function as_tester(workspace: string, request: Object): Object
    local actor = assert(security.new_actor("bee.tests.notesdb_author", {workspace_id = workspace}))
    local scope = security.new_scope({assert(security.policy("bee.security.gateway:gateway_tool_tests_policy"))})
    return harness.value(harness.reply(funcs.new():with_actor(actor):with_scope(scope):call("bee.node.binding:tests_call", request)))
end

local function tests_completed(workspace: string, run_id: unknown): Object
    for _ = 1, 80 do
        local value = as_tester(workspace, {operation = "status", run_id = run_id})
        if value.state == "complete" then return value end
        time.sleep("250ms")
    end
    error("test run " .. tostring(run_id) .. " did not complete")
end

-- A stock Claude Code session in the workspace: the shipped window launch
-- policy as a launch without a saved profile decodes it, its gateway binding
-- admitted with that policy's own surface, and an MCP client over the
-- gateway listener with the binding's token.
local STOCK_POLICY = "bee.driver.claude.security:launch_policy_claude_window"
local GATEWAY_SCOPE = {"bee.harness.catalog:carrier_client_policy", "bee.harness.catalog:gateway_client_policy",
    "bee.harness.security:carrier_policy", "bee.threads.security:create", "bee.threads.security:observe",
    "bee.threads.security:lifecycle", "bee.threads.security:carrier",
    "bee.tests.support:gateway_manage_policy", "bee.tests.support:gateway_admit_policy", "bee.security.gateway:gateway_materialize_policy"}
type Session = {url: string, token: string}
local function gateway_call(subject: string, workspace: string, target: string, request: Object): Object
    local policies: {security.Policy} = {}
    for index, name in ipairs(GATEWAY_SCOPE) do policies[index] = assert(security.policy(name)) end
    local executor = funcs.new():with_actor(principals.actor(subject, workspace)):with_scope(security.new_scope(policies))
    return harness.value(harness.reply(executor:call(target, request)))
end
-- Opening the listener starts a new epoch that retires earlier bindings, so
-- the sessions share one opening.
local listener_open = false
local function stock_session(workspace: string, name: string): Session
    local decoded = assert(launch_policy.decode(STOCK_POLICY, assert(registry.get(STOCK_POLICY)),
        function(_ref: string): (string?, string?) return "/usr/bin/claude-fixture", nil end))
    local surface = assert(launch_policy.with_workspace(decoded.gateway_surface, workspace))
    local subject = "bee.tests.notesdb_session_" .. name
    local address = tostring((assert(bounds.object((assert(registry.get("bee.gateway.api:gateway_endpoint"))).data))).address)
    if not listener_open then
        gateway_call(subject, workspace, "bee.gateway.binding:open", {address = address})
        listener_open = true
    end
    local thread = gateway_call(subject, workspace, "bee.threads.binding:create", {thread_id = "notesdb-" .. name,
        idempotency_key = "notesdb-thread-" .. name, title = "Stock session " .. name})
    local attempt_id = "notesdb-attempt-" .. name
    local action_id = "notesdb-action-" .. name
    gateway_call(subject, workspace, "bee.threads.binding:admit_action", {thread_id = thread.thread_id,
        idempotency_key = "notesdb-admit-" .. name, action_id = action_id, admitted = {request_id = "notesdb-request-" .. name,
            principal_id = subject, binding_ref = "bee.driver.claude.binding:binding", binding_digest = "stock", grant_refs = {},
            budget_ref = "stock", input = {text = "work with the counter"}}})
    gateway_call(subject, workspace, "bee.threads.binding:prepare_attempt", {thread_id = thread.thread_id,
        idempotency_key = "notesdb-prepare-" .. name, action_id = action_id, attempt_id = attempt_id,
        prepared = {binding_ref = "bee.driver.claude.binding:binding", binding_digest = "stock", profile_id = "window",
            profile_digest = "stock", placement_binding = "bee.placement.native.binding:binding",
            placement_attempt_id = "notesdb-placement-" .. name, plan_digest = "stock"}})
    local admitted = gateway_call(subject, workspace, "bee.gateway.binding:admit", {subject = subject, action_id = action_id,
        attempt_id = attempt_id, thread_id = thread.thread_id, owner_incarnation = 1, carrier_epoch = 1,
        tools = decoded.gateway_tools, hooks = {}, surface = surface, policy_ref = STOCK_POLICY, workspace_id = workspace})
    local binding_id = tostring((assert(bounds.object(admitted.binding))).binding_id)
    local authorized = gateway_call(subject, workspace, "bee.gateway.binding:authorize_materialization",
        {attempt_id = attempt_id, carrier_epoch = 1, binding_id = binding_id})
    local minted = gateway_call(subject, workspace, "bee.gateway.binding:materialize", {attempt_id = attempt_id,
        carrier_epoch = 1, binding_id = binding_id, materialization_key = authorized.materialization_key})
    return {url = "http://" .. address .. "/mcp/" .. action_id, token = tostring(minted.token)}
end
local rpc_id = 0
local function rpc(session: Session, method: string, params: Object): Object
    rpc_id = rpc_id + 1
    local response, err = http_client.post(session.url, {headers = {["Content-Type"] = "application/json",
        Authorization = "Bearer " .. session.token}, body = assert(json.encode({jsonrpc = "2.0", id = rpc_id, method = method, params = params})),
        timeout = 30})
    if err or not response then error("mcp " .. method .. ": " .. tostring(err)) end
    return assert(bounds.object(json.decode(tostring(response.body))))
end
local function listed(session: Session): {[string]: boolean}
    local names: {[string]: boolean} = {}
    local answer = rpc(session, "tools/list", {})
    local result = assert(bounds.object(answer.result), tostring(json.encode(answer)))
    for _, tool in ipairs(principals.objects(result.tools)) do names[tostring(tool.name)] = true end
    return names
end
local function tool_call(session: Session, name: string, arguments: Object): Object
    return rpc(session, "tools/call", {name = name, arguments = arguments})
end
local function structured(answer: Object): Object
    local result = assert(bounds.object(answer.result), tostring(json.encode(answer)))
    test.is_true(result.isError ~= true, tostring(json.encode(result)))
    local content = assert(bounds.object(result.structuredContent))
    return content.ok == true and assert(bounds.object(content.value)) or content
end

local function counts(listed_counts: Object): string
    local found: {string} = {}
    for _, value in ipairs(listed_counts.counts :: {unknown}) do found[#found + 1] = tostring(value) end
    return table.concat(found, ",")
end

local function define_tests()
    test.describe("application database through delivery", function()
        test.it("installs the database, runs its migrations forward only and shares the table with agents", function()
            local workspace = harness.isolated("notesdb")
            local writer = harness.author(workspace, "notesdb")
            local before = harness.running()

            local first = harness.value(harness.deliver(writer, OVERLAY, workspace, first_version(), "1.0.0"))
            test.eq(first.pending_migrations, 1)
            test.eq(first.activation_phase, "approval_bound")
            local shown = harness.approve(workspace, first.approval_id)
            -- The install question waits a day for the person, not minutes.
            local stamp = "2006-01-02T15:04:05.000Z07:00"
            local asked_at = assert(time.parse(stamp, tostring(shown.created_at)))
            test.eq(assert(time.parse(stamp, tostring(shown.expires_at))):sub(asked_at):milliseconds(), 86400000)
            local proposal = assert(bounds.object((assert(bounds.object(shown.proposal))).payload))
            local migrations = assert(bounds.array(proposal.migrations, 8))
            test.eq((assert(bounds.object(migrations[1]))).id, NAMESPACE .. ":create_counts")
            test.eq((assert(bounds.object(migrations[1]))).target_db, guide.DATABASE_NAME)
            local prompt = tostring((assert(bounds.object(shown.prompt))).text)
            test.eq(prompt:sub(1, #("Install " .. guide.TITLE .. " 1.0.0?")), "Install " .. guide.TITLE .. " 1.0.0?")
            test.is_true(prompt:find("It runs 1 database migration: " .. NAMESPACE .. ":create_counts on counts.", 1, true) ~= nil)
            local first_outcome = harness.installed(writer, OVERLAY, workspace, "1.0.0", first.intent_id).outcome
            harness.close_presented(before)
            test.eq(first_outcome, "applied")

            local listed_tests = as_tester(workspace, {operation = "list", application = OVERLAY})
            test.eq(listed_tests.application, APP)
            test.eq((assert(bounds.object((assert(bounds.array(listed_tests.tests, 8)))[1]))).id, NAMESPACE .. ":counter_test")
            local started = as_tester(workspace, {operation = "run", application = OVERLAY})
            test.eq(started.total, 1)
            local run = tests_completed(workspace, started.run_id)
            test.eq((assert(bounds.object(run.totals))).passed, 1)

            as_application(workspace, NAMESPACE .. ":count_record", {value = 1})
            test.eq(as_agent(workspace, "counter_record", {value = 2}).recorded, 2)
            test.eq(counts(as_application(workspace, NAMESPACE .. ":count_list", {})), "1,2")

            -- A stock session asks for the application tools; the person
            -- approves them in Needs you, for that session only.
            local asking = stock_session(workspace, "asking")
            local other = stock_session(workspace, "other")
            local before_access = listed(asking)
            test.is_true(before_access.session and before_access.delivery)
            test.is_nil(before_access.app_tools)
            test.is_nil(before_access.counter_list)
            test.is_nil(before_access.publish)
            local requested = structured(tool_call(asking, "session", {operation = "request_access",
                idempotency_key = "notesdb-access", traits = {"bee.app:tools"}, reason = "Use the counter's tools"}))
            local approval_id = assert(bounds.id(requested.approval_id), tostring(json.encode(requested)))
            local asked_person = harness.approve(workspace, approval_id)
            test.eq((assert(bounds.object(asked_person.prompt))).text, "Let this agent session use Application tools? It asks: Use the counter's tools")
            local granted = structured(tool_call(asking, "session", {operation = "access_status", approval_id = approval_id}))
            test.eq(granted.status, "granted")
            local after_access = listed(asking)
            test.is_true(after_access.app_tools and after_access.counter_list and after_access.counter_record)
            test.eq(counts(structured(tool_call(asking, "counter_list", {}))), "1,2")
            local unapproved = listed(other)
            test.is_nil(unapproved.app_tools)
            test.is_nil(unapproved.counter_list)
            local refused = assert(bounds.object(tool_call(other, "counter_list", {}).error))
            test.eq(refused.message, "tool is not admitted for this binding")
            -- Sharing with the hive reaches the session the same way.
            local share = structured(tool_call(asking, "session", {operation = "request_access",
                idempotency_key = "notesdb-share", traits = {"bee.app:share"}, reason = "Share the counter with the hive"}))
            harness.approve(workspace, share.approval_id)
            test.eq(structured(tool_call(asking, "session", {operation = "access_status", approval_id = share.approval_id})).status, "granted")
            test.is_true(listed(asking).publish)
            local published = structured(tool_call(asking, "publish", {source_overlay_id = OVERLAY, version = "1.0.0"}))
            test.is_true(published.published == true, tostring(json.encode(published)))
            test.is_nil(listed(other).publish)

            local second = harness.value(harness.deliver(writer, OVERLAY, workspace, second_version(), "1.0.1"))
            test.eq(second.pending_migrations, 1)
            test.eq(second.activation_phase, "approval_bound")
            local upgrade = harness.approve(workspace, second.approval_id)
            local upgrade_payload = assert(bounds.object((assert(bounds.object(upgrade.proposal))).payload))
            local upgrade_migrations = assert(bounds.array(upgrade_payload.migrations, 8))
            test.eq(#upgrade_migrations, 1)
            test.eq((assert(bounds.object(upgrade_migrations[1]))).id, NAMESPACE .. ":add_note")
            local second_outcome = harness.installed(writer, OVERLAY, workspace, "1.0.1", second.intent_id).outcome
            harness.close_presented(before)
            test.eq(second_outcome, "applied")
            local listed = counts(as_agent(workspace, "counter_list", {}))
            test.eq(listed, "1:kept,2:kept")
            local source = OVERLAY

            -- 1.0.0 came before add_note: going back would run it on a column it
            -- does not know, and the person reads why it stops.
            local back = harness.library(workspace, {operation = "revert", source_workspace = source, receipt_key = "countdb-back-1"})
            local fault = assert(bounds.object(back.error))
            test.eq(fault.code, "BLOCKED")
            test.eq(fault.message, "Going back to 1.0.0 is not possible: a later version changed the saved data in "
                .. guide.DATABASE_NAME .. " (" .. NAMESPACE .. ":add_note), and that change stays. Install a newer version instead.")

            -- 1.0.2 adds no migration; going back to 1.0.1, which defines both,
            -- runs none and keeps the rows.
            local third = harness.value(harness.deliver(writer, OVERLAY, workspace, revised(second_version(), "3"), "1.0.2"))
            test.eq(third.pending_migrations, 0)
            test.eq(harness.settle(writer, OVERLAY, workspace, third, "1.0.2").outcome, "applied")
            harness.close_presented(before)
            local owner = assert(workspace_applications.identity(workspace, OVERLAY)).overlay_owner
            test.eq(#harness.restart({owner}), 0)
            test.is_true(registry.get(APP) ~= nil)
            test.eq(counts(as_agent(workspace, "counter_list", {})), "1:kept,2:kept")
            local returned = harness.value(harness.library(workspace, {operation = "revert", source_workspace = source, receipt_key = "countdb-back-2"}))
            harness.close_presented(before)
            test.eq(returned.phase, "settled")
            test.eq(returned.version, "1.0.1")
            test.eq(counts(as_agent(workspace, "counter_list", {})), "1:kept,2:kept")
            test.eq(#harness.restart({owner}), 0)
            test.is_true(registry.get(APP) ~= nil)
            test.eq(counts(as_agent(workspace, "counter_list", {})), "1:kept,2:kept")

            -- Removal takes the application off and keeps its data: installing it
            -- again finds the rows, with no migration to run.
            harness.value(harness.library(workspace, {operation = "uninstall", source_workspace = source, receipt_key = "countdb-remove"}))
            test.is_nil((registry.get(APP)))
            test.eq(#harness.restart({owner}), 0)
            test.is_nil((registry.get(APP)))
            local again = harness.value(harness.deliver(writer, OVERLAY, workspace, revised(second_version(), "4"), "1.0.3"))
            test.eq(again.pending_migrations, 0)
            test.eq(harness.settle(writer, OVERLAY, workspace, again, "1.0.3").outcome, "applied")
            harness.close_presented(before)
            test.eq(counts(as_agent(workspace, "counter_list", {})), "1:kept,2:kept")
        end)
    end)
end
return test.run_cases(define_tests)
