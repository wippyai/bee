-- MIT. Spec boundary launch behaviour.
local test = require("test")
local sql = require("sql")
local tty = require("tty")
local principals = require("principals")
local funcs = require("funcs")
local process = require("process")
local channel = require("channel")
local registry = require("registry")
local time = require("time")
local bounds = require("bounds")
local json = require("json")
local fixture = require("fixture")
local REQUESTER = fixture.REQUESTER
local DEFINITION = fixture.DEFINITION
local RETAINED_DEFINITION = fixture.RETAINED_DEFINITION
local POLICY = fixture.POLICY
local fresh = fixture.fresh
local workspace_id = fixture.workspace_id
local scope = fixture.scope
local call = fixture.call
local call_as_bound = fixture.call_as_bound
local value = fixture.value
local open_gateway = fixture.open_gateway
local with_entry = fixture.with_entry
local fixture_paths = fixture.fixture_paths
local await_settled = fixture.await_settled
local function define_tests()
    test.describe("Launch spec boundary", function()
        local workspace = fixture.prepare()
        for _, scenario in ipairs({"saved", "delegated", "legacy", "cleared", "narrowed", "context", "input_open", "input_run"}) do
            test.it("preserves the agent spec boundary through real MCP: " .. scenario, function()
                local parent_id, child_id = fresh("regression-parent"), fresh("regression-child")
                local tools = {"thread_read", "profile_get", "profile_put", "session_open", "session_run", "session_get", "thread_message", "app_tools"}
                with_entry("bee.tests.threads.sessions:fake_owner", function(data)
                    local contracts = principals.objects((json.decode(assert(json.encode(data.contracts)))))
                    for _, contract in ipairs(contracts) do contract.default = false end
                    data.contracts = contracts
                end, function()
                with_entry("bee.threads.sessions.binding:owner_binding", function(data)
                    local contracts = principals.objects((json.decode(assert(json.encode(data.contracts)))))
                    for _, contract in ipairs(contracts) do contract.default = true end
                    data.contracts = contracts
                end, function()
                with_entry(RETAINED_DEFINITION, function(data)
                    data.profile_id, data.default_mode, data.credentials = "window", "window", {}
                    data.allowed_overrides = {"brief", "thread"}
                end, function()
                with_entry(POLICY, function(data)
                    local _, streams = fixture_paths()
                    local shipped = assert(bounds.object(assert(registry.get("bee.driver.claude.security:launch_policy_claude_window")).data))
                    local declared = assert(bounds.object(json.decode(assert(json.encode(shipped.gateway_surface)))))
                    declared.fixed_context = {project = "host-project", ["bee.fixture"] = "host"}
                    declared.dynamic_keys = {"experiment"}
                    data.gateway_surface, data.gateway_tools = declared, tools
                    data.allow_host_home, data.allowed_overrides = true, {"thread"}
                    data.environment = {BEE_FIXTURE_STREAM = streams .. "/claude/stream-json-2/plain.jsonl",
                        BEE_FIXTURE_GATEWAY = "1", BEE_FIXTURE_REPORT_STREAM = "1", BEE_FIXTURE_SPEC_REGRESSION = scenario}
                end, function()
                    local mcp: {{tool: string, scope: {[string]: unknown}}} = {}
                    for _, name in ipairs(tools) do mcp[#mcp + 1] = {tool = name, scope = {}} end
                    for _, selected in ipairs({{id = parent_id, definition = DEFINITION}, {id = child_id, definition = RETAINED_DEFINITION}}) do
                        value(call("bee.harness.binding:call", {operation = "put", workspace_id = workspace, profile_id = selected.id,
                            expected_revision = 0, idempotency_key = fresh("put"), profile = {schema_revision = "bee.agent-profile@3",
                                definition_ref = selected.definition, driver_binding_ref = "bee.driver.claude.binding:binding", name = "Saved",
                                provider = {}, bee = {mcp = mcp}, active_traits = {"bee.app:tools"}, requestable = {},
                                context = {project = "profile-project", parent_profile = parent_id, child_profile = child_id, child_definition = RETAINED_DEFINITION}}}))
                    end
                    if scenario == "legacy" then
                        local db = assert(sql.get("bee:db"))
                        assert(db:execute("UPDATE bee_sync_projections SET value_json = json_remove(value_json, '$.active_traits', '$.requestable') WHERE projection_key = ?", {parent_id}))
                        assert(db:execute("UPDATE bee_approval_grants SET scope_json = json_remove(scope_json, '$.parameters.configuration.active_traits', '$.parameters.configuration.requestable'), provenance_json = json_set(provenance_json, '$.kind', 'legacy') WHERE domain = 'profile_choices' AND json_extract(metadata_json, '$.profile_id') = ?", {parent_id}))
                        assert(db:execute("DELETE FROM _migrations WHERE id = 'bee.harness.migrations:profile_consent_traits'"))
                        db:release()
                        local migration = "bee.harness.migrations:profile_consent_traits"
                        local migrated, err = funcs.call(migration, {target_db = "bee:db", database_id = "bee:db", direction = "up", id = migration})
                        assert(not err, tostring(err))
                        assert(assert(bounds.object(migrated)).status ~= "error", json.encode(migrated))
                        local stored = value(call("bee.harness.binding:call", {operation = "get", workspace_id = workspace, profile_id = parent_id}))
                        test.eq(assert(bounds.ids(assert(bounds.object(stored.profile)).active_traits, true))[1], "bee.app:tools")
                    end
                    open_gateway()
                    for _ = 1, (scenario == "saved" or scenario == "legacy") and 2 or 1 do
                    local measured = value(call("bee.tests.harness.admission:resolve", {definition_ref = DEFINITION, workspace_id = workspace,
                        saved_profile_id = parent_id, saved_profile_revision = 1}))
                    local started = value(call("bee.tests.harness.admission:start", {request_id = fresh("regression-start"), definition_ref = DEFINITION,
                        workspace_id = workspace, saved_profile_id = parent_id, saved_profile_revision = 1,
                        expected_plan_digest = measured.plan_digest, brief = "Spawn the child"}))
                    await_settled(tostring(started.thread_id), tostring(started.attempt_id))
                    local page = value(call("bee.threads.binding:read_after", {thread_id = started.thread_id, cursor = 0, limit = 64}))
                    local report: {[string]: unknown}? = nil
                    for _, row in ipairs(principals.objects(page.records)) do
                        local body = bounds.object(row.body)
                        local data = body and bounds.object(body.data)
                        local content = data and bounds.object(data.content)
                        local text = content and bounds.text(content.text)
                        local at = text and text:find("gateway:", 1, true)
                        if text and at then report = bounds.object(json.decode(text:sub(at + 8))) end
                    end
                    assert(report, "real parent carrier did not record its MCP report")
                    test.not_nil(bounds.member("app_tools", assert(bounds.ids(report.tools, true))), "person's saved consent must offer app_tools")
                    test.eq(assert(bounds.object(report.app_tools)).ok, true, json.encode(report.app_tools))
                    local db = assert(sql.get("bee:db"))
                    local requests = assert(db:query("SELECT approval_id FROM bee_approval_requests WHERE thread_id = ?", {started.thread_id}))
                    db:release()
                    test.eq(#requests, 0, "person's saved choice must not ask again")
                    if scenario ~= "saved" and scenario ~= "legacy" then
                    if scenario == "cleared" or scenario == "delegated" then test.eq(report.put_ok, true, tostring(json.encode(report.put_error))) end
                    local snapshot: {[string]: unknown}? = nil
                    local child_thread: string
                    local child_actor: string
                    if scenario == "cleared" or scenario == "delegated" then
                        local overrides = {context = {from_parent = true}}
                        local measured = value(call("bee.tests.harness.admission:resolve", {definition_ref = DEFINITION, workspace_id = workspace,
                            saved_profile_id = child_id .. "-cleared", saved_profile_revision = 1, overrides = overrides}))
                        local launched = value(call("bee.tests.harness.admission:start", {request_id = fresh("cleared-start"), definition_ref = DEFINITION,
                            workspace_id = workspace, saved_profile_id = child_id .. "-cleared", saved_profile_revision = 1,
                            expected_plan_digest = measured.plan_digest, brief = "Read your session", overrides = overrides}))
                        child_thread, child_actor = assert(bounds.id(launched.thread_id)), REQUESTER
                        await_settled(child_thread, tostring(launched.attempt_id))
                    else
                        assert(bounds.object(report.opened), "parent MCP report: " .. assert(json.encode(report)))
                        test.eq(assert(bounds.object(report.opened)).ok, true, assert(json.encode(report.opened)))
                        value(principals.reply(report.opened))
                        snapshot = assert(bounds.object(value(principals.reply(report.child_get)).value))
                        child_thread = assert(bounds.id(snapshot.thread_ref))
                        child_actor = "bee.application:" .. workspace .. ":" .. child_thread:sub(8)
                    end
                    local child_read: {[string]: unknown}? = nil
                    local cursor = 0
                    while not child_read do
                        local records = value(call_as_bound(child_actor, "bee.threads.binding:read_after", {thread_id = child_thread, cursor = cursor, limit = 64}, workspace))
                        for _, row in ipairs(principals.objects(records.records)) do
                            local content = bounds.object(assert(bounds.object(row.body)).content)
                            local text = content and bounds.text(content.text)
                            if text and text:sub(1, 11) == "spec-child:" then child_read = bounds.object(json.decode(text:sub(12))) end
                        end
                        cursor = math.floor(tonumber(records.scanned_through) or cursor)
                        if not child_read then
                            local watched = value(call_as_bound(child_actor, "bee.threads.binding:watch", {thread_id = child_thread, after_sequence = cursor, wait_ms = 10000}, workspace))
                            if watched.status ~= "ready" then
                                local token = "bee.session.viewer/" .. fresh("diagnostic")
                                local replies = assert(process.listen("bee.session.window.reply", {message = true}))
                                assert(process.registry.register(token))
                                local owner = assert(process.registry.lookup("bee.session.window/" .. tostring(assert(snapshot).session)))
                                assert(process.send(owner, "bee.session.window.request", {op = "attach", caller_token = token}))
                                local received = channel.select({replies:case_receive(), time.after("5s"):case_receive()})
                                assert(received.ok and received.channel == replies, "child terminal did not answer")
                                local reply = assert(bounds.object(received.value:payload():data()))
                                local mount = assert(bounds.id(assert(bounds.object(reply.value)).mount))
                                local view = assert(tty.attach(mount))
                                local shown = table.concat(assert(view:snapshot()).rows, "\n")
                                view:close()
                                process.registry.unregister(token, process.registry.LOCAL)
                                process.unlisten(replies)
                                error("real child carrier did not start and read its session: " .. shown)
                            end
                        end
                    end
                    local observed = value(principals.reply(child_read))
                    if scenario == "cleared" or scenario == "narrowed" or scenario == "delegated" then
                        test.is_true(not bounds.member("app_tools", assert(bounds.ids(observed.offered_tools, true))), "removed consent trait must remove app_tools")
                        test.eq(assert(bounds.object(observed.app_tools_denied)).ok, false)
                        test.eq(#assert(bounds.ids(observed.active_traits, true)), 0)
                        local db = assert(sql.get("bee:db"))
                        local requests = assert(db:query("SELECT approval_id FROM bee_approval_requests WHERE thread_id = ?", {child_thread}))
                        db:release()
                        test.eq(#requests, scenario == "delegated" and 1 or 0)
                    elseif scenario == "context" then
                        test.eq(assert(bounds.object(observed.context)).project, "host-project")
                        test.eq(assert(bounds.object(observed.context))["bee.fixture"], "host")
                        test.eq(observed.dynamic_selection, true)
                        test.eq(assert(bounds.object(observed.dynamic_context)).experiment, "child-value")
                    else
                        test.eq(observed.initial_input_bytes, 16384)
                        test.eq(observed.initial_input_matches, true)
                        local history = value(call_as_bound(child_actor, "bee.threads.sessions.binding:history", {session = assert(snapshot).session, limit = 10}, workspace))
                        local items = principals.objects(history.items)
                        test.eq(#items, 1)
                        test.eq(items[1].input, string.rep("x", 16384))
                    end
                    end
                    end
                end)
                end)
                end)
                end)
            end)
        end
        fixture.restore_host()
    end)
end
return test.run_cases(define_tests)
