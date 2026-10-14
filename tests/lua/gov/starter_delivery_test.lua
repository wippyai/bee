local test = require("test")
local json = require("json")
local funcs = require("funcs")
local security = require("security")
local cdc = require("cdc")
local bounds = require("bounds")
local harness = require("harness")
type Object = {[string]: unknown}
local function tester(workspace: string, request: Object): Object
    local actor = assert(security.new_actor("bee.tests.dxstarter_author", {workspace_id = workspace}))
    local scope = security.new_scope({assert(security.policy("bee.security.gateway:gateway_tool_tests_policy"))})
    return harness.value(harness.reply(funcs.new():with_actor(actor):with_scope(scope):call("bee.node.binding:tests_call", request)))
end
local function define_tests()
    test.describe("the corpus starter through app delivery", function()
        test.it("installs the typed starter and runs its real greeting tests", function()
            local workspace = harness.isolated("dxstarter")
            local actor = assert(security.new_actor("bee.tests.dxstarter_author", {workspace_id = workspace}))
            local scope = security.new_scope({assert(security.policy("bee.security.gateway:gateway_tool_docs_policy"))})
            local page = harness.value(harness.reply(funcs.new():with_actor(actor):with_scope(scope):call(
                "bee.docs.binding:call", {operation = "read", id = "reference_apps/starter"})))
            test.eq(page.eof, true)
            local source = assert(tostring(page.content):match("```json%s*(.-)%s*```"))
            local renamed = source:gsub("app%.hello", "app.dxstarter")
                :gsub("bee%.shell:apps_menu", "bee.tests.gov:unplaced_menu")
                :gsub('"type":%s*"test"', '"type":"app_test"')
            local pack = assert(json.decode(renamed)) :: {Object}
            local author = harness.author(workspace, "dxstarter")
            local before = harness.running()
            local foreign = assert(json.decode((renamed:gsub("app%.dxstarter", "app.dxstarter_other")))) :: {Object}
            local foreign_digest = harness.freeze(author, "dxstarter", foreign, "bad-neighbor")
            local refused = harness.value(harness.reply(author:call("bee.gov.binding:delivery_call", {
                operation = "preflight", workspace_id = workspace, source_overlay_id = "dxstarter",
                version = "bad-neighbor", snapshot_digest = foreign_digest})))
            test.eq(refused.ready, false)
            local namespace_denied = false
            for _, raw in ipairs(assert(bounds.array(refused.diagnostics, 128))) do
                if assert(bounds.object(raw)).code == "NAMESPACE_DENIED" then namespace_denied = true end
            end
            test.is_true(namespace_denied)
            local digest = harness.freeze(author, "dxstarter", pack, "1")
            local checked = harness.value(harness.reply(author:call("bee.gov.binding:delivery_call", {
                operation = "preflight", workspace_id = workspace, source_overlay_id = "dxstarter",
                version = "1", snapshot_digest = digest})))
            test.eq(checked.ready, true, tostring(json.encode(checked)))
            local requested = harness.value(harness.request(author, "dxstarter", workspace, "1", digest))
            test.eq(requested.ready, true)
            harness.settle(author, "dxstarter", workspace, requested, "1")
            local listed = tester(workspace, {operation = "list", application = "app.dxstarter.app:app"})
            test.eq(#assert(bounds.array(listed.tests, 64)), 1)
            local changes = assert(cdc.stream("bee:changes", {tables = {"bee_node_test_runs"}, ops = {"update"}}))
            local updates = changes:channel()
            local run = tester(workspace, {operation = "run", application = "app.dxstarter.app:app"})
            local completed: Object
            while true do
                completed = tester(workspace, {operation = "status", run_id = run.run_id})
                if completed.state == "complete" then break end
                assert((updates:receive()), "starter test run change stream closed")
            end
            changes:close()
            local totals = assert(bounds.object(completed.totals))
            test.eq(totals.passed, 2)
            test.eq(totals.failed, 0)
            test.eq(totals.errors, 0)
            harness.value(harness.library(workspace, {operation = "uninstall", source_workspace = "dxstarter",
                receipt_key = "dxstarter-remove"}))
            harness.close_presented(before)
        end)
    end)
end
return test.run_cases(define_tests)
