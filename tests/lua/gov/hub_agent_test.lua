-- MIT. An agent installs configured Hub applications through consent and governance.
local test = require("test")
local fixtures = require("fixtures")
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local json = require("json")
local registry = require("registry")
local harness = require("harness")
local sessions = require("stock_session")
local application = require("application")
type Object = {[string]: unknown}
local function stock_session(workspace: string, name: string): sessions.Session
    return sessions.open(workspace, "hub-agent-" .. name)
end
local listed, tool_call, structured = sessions.listed, sessions.tool_call, sessions.structured

local function inbox(workspace: string): {unknown}
    local actor = assert(application.actor(workspace, "hub-agent-inbox", assert(application.definition("bee.approvals.inbox.app:app")), 1))
    return assert(bounds.array(harness.value(harness.reply(funcs.new():with_actor(actor):call(
        "bee.approvals.binding:feed_snapshot", {workspace_id = workspace}))).items, 64))
end
local function define_tests()
    test.describe("Agent Hub application", function()
        test.after_all(fixtures.registry_cleanup(true))
        test.it("fills a parameter through the Hub trait and installs with one governed approval", function()
            local workspace = harness.isolated("hub-agent")
            local before = harness.running()
            local session = stock_session(workspace, "progress")
            local hidden = listed(session)
            for _, name in ipairs({"components", "install_request", "uninstall_request", "install_status"}) do test.is_nil(hidden[name]) end
            local requested = structured(tool_call(session, "session", {operation = "request_access",
                traits = {"bee.hub:library"}, reason = "Install Progress for this workspace", idempotency_key = "hub-agent-access"}))
            harness.approve(workspace, requested.approval_id)
            test.eq(structured(tool_call(session, "session", {operation = "access_status", approval_id = requested.approval_id})).status, "granted")
            local offered = listed(session)
            for _, name in ipairs({"components", "install_request", "uninstall_request", "install_status"}) do test.is_true(offered[name]) end
            local catalog = structured(tool_call(session, "components", {operation = "catalog", request = {query = "progress"}}))
            test.eq(assert(bounds.object(assert(bounds.array(catalog.items, 64))[1])).component, "bee/progress")
            local request = {component = "bee/progress", version = "1.0.0", parameters = {{name = "app.progress:title", value = "Agent progress"}}}
            local filed = structured(tool_call(session, "install_request", request))
            test.eq(filed.status, "pending")
            test.eq(structured(tool_call(session, "install_request", request)).request_id, filed.request_id)
            test.eq(structured(tool_call(session, "install_status", {request_id = filed.request_id})).status, "pending")
            local approvals = 0
            for _, raw in ipairs(inbox(workspace)) do
                local item = assert(bounds.object(assert(bounds.object(raw)).value))
                if item.state == "pending" then
                    approvals = approvals + 1
                    test.eq(item.approval_id, filed.approval_id)
                    local proposal = assert(bounds.object(item.proposal))
                    test.is_true(proposal.ref ~= "bee.hub:apply")
                    test.eq(#assert(bounds.array(assert(bounds.object(proposal.payload)).migrations, 8)), 2)
                end
            end
            test.eq(approvals, 1)
            harness.approve(workspace, filed.approval_id)
            harness.drain()
            local installed = structured(tool_call(session, "install_status", {request_id = filed.request_id}))
            test.eq(installed.status, "applied", tostring(json.encode(installed)))
            test.eq(assert(bounds.object(assert(bounds.object((assert(registry.get("app.progress:app"))).meta)).application)).title, "Agent progress")
            harness.value(harness.library(workspace, {operation = "uninstall", source_workspace = "hub:bee/progress", receipt_key = "hub-agent-cleanup"}))
            harness.close_presented(before)
        end)
    end)
end
return test.run_cases(define_tests)
