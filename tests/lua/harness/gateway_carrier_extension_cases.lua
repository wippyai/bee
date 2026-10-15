-- MIT. Focused gateway carrier test cases.
local test = require("test")
local bounds = require("bounds")
local principals = require("principals")
local process = require("process")
local json = require("json")
local harness = require("harness")
local support = require("support")
local ACTOR = support.ACTOR
local POLICY = support.POLICY
local ROOT = support.ROOT
local fresh = support.fresh
local scope = support.scope
local install_policy = support.install_policy
local admit_root = support.admit_root
local open_gateway = support.open_gateway
local request = support.request
local await_exit = support.await_exit
local hook_report = support.hook_report
local function define_extension_tests()
    test.describe("Managed session extension hooks", function()
        test.after_all(require("memory_host").close_all)
        install_policy(POLICY)
        admit_root()
        open_gateway()
        test.it("dispatches and denies after 100 retained events through the registered production carrier", function()
            local host = require("memory_host")
            local session = host.open(nil, "bee.tests.memory:hooks_a", "claude", true)
            local admin = harness.principal("sessions-owner", harness.ALL, host.WORKSPACE)
            local summary = assert(bounds.object(harness.value(admin:call("get", {thread_id = session.thread})).summary))
            harness.value(admin:call("join", {thread_id = session.thread, member_id = ACTOR, role = "participant",
                expected_revision = summary.revision, idempotency_key = fresh("member")}))
            local launch = request(session.thread, fresh("attempt"), {BEE_FIXTURE_HOOKS = "1", BEE_FIXTURE_HOOK_RESPONSES = "1",
                BEE_FIXTURE_HOOKS_FLOOD = "110", BEE_FIXTURE_HOOKS_FLOOD_DENY = "1"})
            launch.workspace_id, launch.session_ref = host.WORKSPACE, session.session
            launch.resources = {{name = "project", grant_ref = "host", root_ref = ROOT, subpath = "", access = "write", purpose = "project"},
                {name = "home", grant_ref = "session-host", root_ref = ROOT, subpath = "", access = "write", purpose = "session"}}
            local spawner = process.with_context({}):with_actor(principals.actor(ACTOR, host.WORKSPACE)):with_scope(scope())
            local pid = assert(spawner:spawn_monitored("bee.harness.service:carrier", "bee:workers", launch, "open", process.pid()))
            local outcome = await_exit(tostring(pid), "managed extension carrier", 30000)
            assert(outcome.value, tostring(outcome.error))
            test.eq(assert(bounds.object(outcome.value.settlement)).outcome, "succeeded")
            local reported = hook_report(session.thread)
            test.eq(json.encode(reported.statuses), (json.encode({202, 200, 200, 200, 202})))
            local responses = assert(bounds.array(reported.responses, 8))
            test.eq(assert(bounds.object(assert(bounds.object(responses[2])).hookSpecificOutput)).additionalContext, "fixture context:a")
            local before = assert(bounds.object(assert(bounds.object(responses[3])).hookSpecificOutput))
            test.eq(assert(bounds.object(before.updatedInput)).command, "true:a")
            test.is_true(assert(bounds.text(assert(bounds.object(assert(bounds.object(responses[4])).hookSpecificOutput)).updatedToolOutput)):sub(-2) == ":a")
            test.eq(assert(bounds.object(reported.flood))["200"], 110)
            local denial = assert(bounds.object(reported.flood_denial))
            test.eq(denial.status, 200)
            test.eq(assert(bounds.object(assert(bounds.object(denial.response)).hookSpecificOutput)).permissionDecision, "deny")
        end)
    end)
end
return {define = define_extension_tests}
