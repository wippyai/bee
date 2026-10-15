-- MIT. Spec launch behaviour.
local test = require("test")
local tty = require("tty")
local principals = require("principals")
local process = require("process")
local channel = require("channel")
local registry = require("registry")
local time = require("time")
local trait_access = require("trait_access")
local bounds = require("bounds")
local json = require("json")
local fixture = require("fixture")
local DEFINITION = fixture.DEFINITION
local RETAINED_DEFINITION = fixture.RETAINED_DEFINITION
local POLICY = fixture.POLICY
local fresh = fixture.fresh
local workspace_id = fixture.workspace_id
local scope = fixture.scope
local call = fixture.call
local profile_call = fixture.profile_call
local call_as_bound = fixture.call_as_bound
local value = fixture.value
local open_gateway = fixture.open_gateway
local with_entry = fixture.with_entry
local fixture_paths = fixture.fixture_paths
local await_settled = fixture.await_settled
local function define_tests()
    test.describe("Launch spec", function()
        local workspace = fixture.prepare()
        test.it("refuses a saved container Codex bypass when launch selects native placement", function()
            local definition_ref = "bee.driver.codex.profiles:research_batch"
            local policy_ref = "bee.driver.codex.security:launch_policy_codex_batch"
            with_entry(definition_ref, function(data) data.allowed_overrides = {"thread", "workdir", "placement"} end, function()
                with_entry(policy_ref, function(data)
                    data.allowed_overrides = {"thread", "workdir", "placement"}
                    data.executables, data.executable_env = {codex = "/bin/true"}, {}
                end, function()
                    local id = fresh("container-yolo")
                    local written = profile_call({operation = "put", workspace_id = workspace, profile_id = id, expected_revision = 0,
                        idempotency_key = fresh("container-save"), profile = {schema_revision = "bee.agent-profile@3", name = "Container Codex",
                            definition_ref = definition_ref, driver_binding_ref = "bee.driver.codex.binding:binding",
                            placement = {kind = "docker", profile_ref = "bee.placement.docker.profiles:coding"}, bee = {},
                            provider = {options = {sandbox = "danger-full-access", approval_policy = "never", dangerously_bypass_approvals_and_sandbox = true}}}})
                    assert(written.ok == true, tostring(written.message))
                    local planned = value(call("bee.tests.harness.admission:resolve", {definition_ref = definition_ref, workspace_id = workspace,
                        saved_profile_id = id, saved_profile_revision = 1}))
                    test.eq(planned.placement_kind, "docker")
                    local denied = call("bee.tests.harness.admission:admit", {request_id = fresh("native-yolo"), definition_ref = definition_ref,
                        workspace_id = workspace, saved_profile_id = id, saved_profile_revision = 1, brief = "Fixture", expected_plan_digest = planned.plan_digest,
                        placement_override = {kind = "native", home = "private"}})
                    test.is_false(denied.ok)
                    test.is_true(tostring(denied.error and denied.error.message):find("ceiling", 1, true) ~= nil, tostring(denied.error and denied.error.message))
                end)
            end)
        end)
        test.it("spawns a saved spec through the real carrier and MCP, including a narrowed child", function()
            local parent_id, child_id = fresh("spec-parent"), fresh("spec-child")
            local tools = {"thread_read", "capabilities", "profile_get", "profile_put", "profile_list", "session_open", "session_run", "session_get", "session_close", "thread_message"}
            with_entry("bee.tests.threads.sessions:fake_owner", function(data)
                local contracts: {{[string]: unknown}} = {}
                for _, item in ipairs(principals.objects(data.contracts)) do
                    local copied: {[string]: unknown} = {}
                    for key, value in pairs(item) do copied[key] = value end
                    copied.default = false
                    contracts[#contracts + 1] = copied
                end
                data.contracts = contracts
            end, function()
            with_entry("bee.threads.sessions.binding:owner_binding", function(data)
                local contracts: {{[string]: unknown}} = {}
                for _, item in ipairs(principals.objects(data.contracts)) do
                    local copied: {[string]: unknown} = {}
                    for key, value in pairs(item) do copied[key] = value end
                    copied.default = true
                    contracts[#contracts + 1] = copied
                end
                data.contracts = contracts
            end, function()
            with_entry(RETAINED_DEFINITION, function(data)
                data.profile_id, data.default_mode, data.credentials = "window", "window", {}
                data.allowed_overrides = {"brief", "thread"}
            end, function()
            with_entry(POLICY, function(data)
                local bin, streams = fixture_paths()
                data.allow_host_home = true
                data.allowed_overrides = {"thread"}
                data.gateway_tools = tools
                data.gateway_surface = {tools = {}, traits = {
                    {id = "bee.tests.memory:review", title = "Review", prompt = "Review changes.", tools = {}},
                    {id = "bee.tests.memory:outside", title = "Outside", prompt = "Outside parent ceiling.", tools = {}},
                    assert(trait_access.load("bee.tests.memory:trait"))},
                    base_tools = tools, active_traits = {}, dynamic_keys = {}, fixed_context = {["bee.fixture"] = "host"},
                    access = {policy = "agent-access", traits = {"bee.tests.memory:trait"}}}
                data.environment = {BEE_FIXTURE_STREAM = streams .. "/claude/stream-json-2/plain.jsonl",
                    BEE_FIXTURE_GATEWAY = "1", BEE_FIXTURE_REPORT_STREAM = "1", BEE_FIXTURE_AGENT_SPEC = parent_id}
            end, function()
                local mcp: {{tool: string, scope: {[string]: unknown}}} = {}
                for _, name in ipairs(tools) do mcp[#mcp + 1] = {tool = name, scope = {}} end
                for _, selected in ipairs({{id = parent_id, definition = DEFINITION}, {id = child_id, definition = RETAINED_DEFINITION}}) do
                    value(call("bee.harness.binding:call", {operation = "put", workspace_id = workspace, profile_id = selected.id,
                        expected_revision = 0, idempotency_key = fresh("put"), profile = {schema_revision = "bee.agent-profile@3",
                            definition_ref = selected.definition, driver_binding_ref = "bee.driver.claude.binding:binding", name = "Saved",
                            role = "Parent", provider = {}, bee = {mcp = mcp}, active_traits = {"bee.tests.memory:review"},
                            requestable = selected.id == child_id and {"bee.tests.memory:trait", "bee.tests.memory:outside"} or {"bee.tests.memory:trait"}, context = {project = "Bee", child_profile = child_id, child_definition = RETAINED_DEFINITION}}}))
                end
                open_gateway()
                local measured = value(call("bee.tests.harness.admission:resolve", {definition_ref = DEFINITION, workspace_id = workspace,
                    saved_profile_id = parent_id, saved_profile_revision = 1, overrides = {name = "Parent", role = "Inspect", traits = {"bee.tests.memory:review", "bee.tests.memory:trait"}, context = {task = "Review", readonly = false}}}))
                local started = value(call("bee.tests.harness.admission:start", {request_id = fresh("spec-start"), definition_ref = DEFINITION,
                    workspace_id = workspace, saved_profile_id = parent_id, saved_profile_revision = 1, expected_plan_digest = measured.plan_digest,
                    brief = "Read the supplied context", overrides = {name = "Parent", role = "Inspect", traits = {"bee.tests.memory:review", "bee.tests.memory:trait"}, context = {task = "Review", readonly = false}}}))
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
                assert(report, "real carrier did not record its MCP report")
                local function rejected(name: string): string
                    local reply = assert(bounds.object(report[name]), name .. " returned no MCP result")
                    test.eq(reply.ok, false)
                    return assert(bounds.text(assert(bounds.object(reply.error)).message))
                end
                local before = value(principals.reply(report.spec_read))
                test.eq(assert(bounds.object(before.context)).project, "Bee")
                test.eq(assert(bounds.object(before.context)).task, "Review")
                test.eq(assert(bounds.object(before.context)).readonly, false)
                test.eq(assert(bounds.object(before.context))["bee.fixture"], "host")
                test.eq(assert(bounds.ids(before.active_traits, true))[1], "bee.tests.memory:review")
                local consent = value(principals.reply(report.consent_first))
                test.not_nil(consent.approval_id)
                test.eq(consent.approval_id, value(principals.reply(report.consent_again)).approval_id)
                test.not_nil(value(principals.reply(report.profile_get)).profile)
                test.not_nil(value(principals.reply(report.profile_list)).items)
                test.not_nil(value(principals.reply(report.profile_put)).profile)
                local after = value(principals.reply(report.spec_after_put))
                test.eq(#assert(bounds.ids(after.active_traits, true)), 1)
                test.is_true(rejected("profile_denied"):find("bee.tests.memory:outside", 1, true) ~= nil)
                test.is_true(rejected("driver_denied"):find("launch ceiling: bee.app:tools", 1, true) ~= nil)
                test.is_true(rejected("parent_denied"):find("parent ceiling", 1, true) ~= nil)
                value(principals.reply(report.child_run))
                local child = value(principals.reply(report.child_get))
                local snapshot = assert(bounds.object(child.value))
                local profile = assert(bounds.object(snapshot.effective_profile))
                test.eq(profile.name, "Child")
                test.eq(profile.role, "Review changes")
                test.is_true(tostring(snapshot.title):find("Child · Review changes", 1, true) == 1)
                test.eq(assert(bounds.ids(profile.active_traits, true))[1], "bee.tests.memory:review")
                test.eq(assert(bounds.object(profile.context)).from_parent, true)
                local child_thread = assert(bounds.id(snapshot.thread_ref))
                local child_actor = "bee.application:" .. workspace .. ":" .. child_thread:sub(8)
                local function child_call(target: string, request: unknown): {[string]: unknown}
                    return value(call_as_bound(child_actor, target, request, workspace))
                end
                local child_read: {[string]: unknown}? = nil
                local cursor = 0
                while not child_read do
                    local records = child_call("bee.threads.binding:read_after", {thread_id = child_thread, cursor = cursor, limit = 64})
                    for _, row in ipairs(principals.objects(records.records)) do
                        local body = bounds.object(row.body)
                        local content = body and bounds.object(body.content)
                        local text = content and bounds.text(content.text)
                        if text and text:sub(1, 11) == "spec-child:" then child_read = bounds.object(json.decode(text:sub(12))) end
                    end
                    cursor = math.floor(tonumber(records.scanned_through) or cursor)
                    if not child_read then
                        local watched = child_call("bee.threads.binding:watch", {thread_id = child_thread, after_sequence = cursor, wait_ms = 10000})
                        if watched.status ~= "ready" then
                            local token = "bee.session.viewer/" .. fresh("diagnostic")
                            local replies = assert(process.listen("bee.session.window.reply", {message = true}))
                            assert(process.registry.register(token))
                            local owner = assert(process.registry.lookup("bee.session.window/" .. tostring(snapshot.session)))
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
                            error("child produced no session read: " .. shown)
                        end
                    end
                end
                local observed = value(principals.reply(child_read))
                test.eq(assert(bounds.object(observed.context)).from_parent, true)
                test.eq(assert(bounds.object(observed.context)).project, "Bee")
                local restored = child_call("bee.threads.sessions.binding:restore", {session = snapshot.session})
                local ceiling = bounds.ids(restored.trait_ceiling, true)
                test.not_nil(ceiling, "restore must retain the spawning parent's ceiling")
                test.is_true(not bounds.member("bee.tests.memory:outside", assert(ceiling)))
                test.eq(assert(bounds.ids(observed.active_traits, true))[1], "bee.tests.memory:review")
                test.is_true(rejected("child_denied"):find("outside:trait", 1, true) ~= nil)
                test.is_true(rejected("context_denied"):find("bee.workspace_id", 1, true) ~= nil)
            end)
            end)
            end)
            end)
        end)
        fixture.restore_host()
    end)
end
return test.run_cases(define_tests)
