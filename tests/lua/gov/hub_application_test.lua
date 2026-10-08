-- MIT. Library installation from a verified fixture catalog through governance.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local json = require("json")
local time = require("time")
local system = require("system")
local registry = require("registry")
local application = require("application")
local harness = require("harness")
local hub = require("hub")
local governed = require("governed")
local preflight = require("preflight")
local client = require("client")
type Object = {[string]: unknown}
local APP = "app.progress:app"
local function call(executor: funcs.Executor, target: string, input: unknown): Object
    local reply, problem = executor:call(target, input)
    if problem then error(target .. ": " .. tostring(problem)) end
    return assert(bounds.object(reply))
end
local function define_tests()
    test.describe("Hub application through Library", function()
        test.it("approves once, applies both migrations, offers eight tools, runs four tests and places the menu", function()
            local workspace = harness.isolated("hub-progress")
            local before = harness.running()
            local definition = assert(application.definition("bee.apps.library:app"))
            local declaration = assert(registry.get(definition.process))
            local data = assert(bounds.object(declaration.data))
            local execution = assert(bounds.object(data.security))
            local policies: {security.Policy} = {}
            for _, id in ipairs(assert(bounds.ids(execution.policies, true))) do
                policies[#policies + 1] = assert(security.policy(id))
            end
            local person = funcs.new():with_actor(assert(application.actor(workspace, "hub-proof", definition, 1)))
                :with_scope(security.new_scope(policies))
            local state = hub.new()
            hub.select(state, "bee/progress")
            hub.select_version(state, "1.0.0")
            test.is_nil(hub.set_parameter(state, "app.progress:title", '"Team progress"'))
            local plan_request = assert(hub.plan_intent(state))
            local planned = call(person, hub.HUB, plan_request)
            local stage = assert(hub.governed_request(state, planned :: hub.Reply, workspace, "hub-stage"),
                tostring(json.encode(planned)))
            local refused = call(person, hub.HUB, {operation = "apply", request = plan_request.request,
                expected_digest = stage.artifact_digest})
            test.is_false(refused.ok)
            test.eq(refused.code, "GOVERNED_DELIVERY")
            local gov = governed.new(workspace)
            local staged = call(person, governed.CALL, stage)
            test.is_true(governed.apply_plan(gov, staged), tostring(json.encode(staged)))
            local item = assert(gov.detail)
            local detailed = call(person, governed.CALL, governed.get_request(gov, item))
            test.is_true(governed.apply_plan(gov, detailed), tostring(json.encode(detailed)))
            item = assert(gov.detail)
            local report = assert(preflight.decode_report(item.preflight_bytes, item.preflight_digest))
            test.is_true(report.ready, tostring(json.encode(report.diagnostics)))
            test.eq(#report.pending_migrations, 2)
            governed.select(gov, governed.key(item))
            local reviewed = call(person, governed.CALL, governed.review_request(gov, item, true, "hub-review"))
            test.is_true(governed.apply_plan(gov, reviewed), tostring(json.encode(reviewed)))
            item = assert(gov.detail)
            local selected = call(person, governed.CALL, governed.select_request(gov, item, "hub-select"))
            test.is_true(governed.apply_plan(gov, selected), tostring(json.encode(selected)))
            item = assert(gov.detail)
            local prepare = governed.prepare_request(gov, item, "hub-intent", "hub-prepare")
            local pending = harness.value(call(person, governed.CALL, prepare))
            test.eq(pending.phase, "approval_bound")
            local replay = harness.value(call(person, governed.CALL, prepare))
            test.eq(replay.approval_id, pending.approval_id)
            local shown = harness.approve(workspace, pending.approval_id)
            local payload = assert(bounds.object((assert(bounds.object(shown.proposal))).payload))
            test.eq(#assert(bounds.array(payload.migrations, 8)), 2)
            local drained = harness.drain()
            local installed = harness.value(call(person, governed.CALL, governed.status_request(gov, "hub-intent")))
            test.eq(installed.phase, "settled", tostring(json.encode(drained)))
            test.eq(installed.outcome, "applied", tostring(json.encode(installed)))
            test.is_true(installed.migrations_completed == true)
            local actor = assert(security.new_actor("bee.tests.hub_progress_agent", {workspace_id = workspace}))
            local agent = funcs.new():with_actor(actor):with_scope(security.new_scope({
                assert(security.policy("bee.security.gateway:gateway_tool_app_tools_policy")),
                assert(security.policy("bee.security.gateway:gateway_tool_tests_policy"))}))
            local tools = harness.value(call(agent, "bee.node.binding:app_tools", {}))
            local aliases: {[string]: boolean} = {}
            local offered = 0
            for _, raw in ipairs(assert(bounds.array(tools.tools, 64))) do
                local tool = assert(bounds.object(raw))
                if tool.definition_id == APP then
                    aliases[assert(bounds.id(tool.alias))] = true
                    offered = offered + 1
                end
            end
            test.eq(offered, 8, tostring(json.encode(tools)))
            for _, name in ipairs({"allocate", "assign", "create", "get", "report", "state", "tree", "updates"}) do
                test.is_true(aliases["progress_" .. name], "Progress does not offer " .. name)
            end
            local output = harness.value(call(agent, "bee.node.binding:app_tool_call", {tool = "progress_tree", arguments = {}}))
            test.eq(#assert(bounds.array(output.migrations, 8)), 2)
            local listed = harness.value(call(agent, "bee.node.binding:tests_call", {operation = "list", application = APP}))
            test.eq(#assert(bounds.array(listed.tests, 64)), 4)
            local started = harness.value(call(agent, "bee.node.binding:tests_call", {operation = "run", application = APP}))
            local completed: Object? = nil
            for _ = 1, 80 do
                local status = harness.value(call(agent, "bee.node.binding:tests_call", {operation = "status", run_id = started.run_id}))
                if status.state == "complete" then completed = status; break end
                time.sleep("250ms")
            end
            local totals = assert(bounds.object(assert(completed, "application tests do not complete").totals))
            test.eq(totals.passed, 4, tostring(json.encode(completed)))
            test.eq(totals.failed, 0)
            test.eq(totals.errors, 0)
            local catalog = assert(client.call(assert(system.node.id()), "list", {}))
            local placed = false
            for _, raw in ipairs(catalog.apps :: {unknown}) do
                local app = assert(bounds.object(raw))
                if app.id == APP then
                    for _, entry in ipairs(assert(bounds.array(app.menus, 8))) do
                        local menu = assert(bounds.object(entry))
                        if menu.id == "bee.shell:apps_menu" and menu.location == "start" then placed = true end
                    end
                end
            end
            test.is_true(placed, "Progress is absent from the Start menu")
            local installed_app = assert(registry.get(APP))
            local installed_meta = assert(bounds.object(installed_app.meta))
            test.eq(assert(bounds.object(installed_meta.application)).title, "Team progress")
            local revert = call(person, governed.CALL, governed.revert_request(gov, "hub:bee/progress", "hub-back"))
            test.is_false(revert.ok)
            local refusal = assert(bounds.object(revert.error))
            test.eq(refusal.code, "BLOCKED", tostring(json.encode(revert)))
            harness.value(call(person, governed.CALL, governed.uninstall_request(gov, "hub:bee/progress", "hub-remove")))
            harness.close_presented(before)
        end)
    end)
end
return test.run_cases(define_tests)
