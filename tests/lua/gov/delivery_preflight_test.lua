local test = require("test")
local bounds = require("bounds")
local json = require("json")
local harness = require("harness")
local guide = require("guide")
local mcp = require("mcp")
local json_schema = require("json_schema")
local events = require("events")
local channel = require("channel")
local time = require("time")
local sql = require("sql")
local registry = require("registry")
local fs = require("fs")
type Object = {[string]: unknown}
local function entries(name: string): {Object}
    local bytes = assert(json.encode(guide.example())):gsub("app.counter", "app." .. name)
    return assert(json.decode(bytes)) :: {Object}
end
local function define_tests()
    test.describe("agent delivery preflight", function()
        test.it("announces one delivery decision covering installation and the declared file grant", function()
            local workspace, path = harness.isolated("bundle-delivery", "/tmp")
            local files = assert(fs.get("bee.tests.gov:bundle_files"))
            local directory = path:sub(#"/tmp/" + 1)
            assert(files:mkdir(directory))
            assert(files:mkdir(directory .. "/testdata"))
            local author = harness.author(workspace, "bundle")
            local before = harness.running()
            local pack = entries("bundle")
            pack[#pack + 1] = {id = "app.bundle:files", kind = "ns.requirement",
                meta = {value_kind = "security.policy", capability = "workspace.files.read",
                    parameters = {subpath = "testdata"}, reason = "Show fixture status"},
                data = {targets = {{entry = "app.bundle:app", path = ".security.policies +="}}}}
            local subscription = assert(events.subscribe("bee.attention", "approval.requested"))
            local digest = harness.freeze(author, "bundle", pack, "1")
            local requested = harness.value(harness.request(author, "bundle", workspace, "1", digest))
            test.eq(requested.ready, true)
            local selected = channel.select({subscription:channel():case_receive(), time.after("2s"):case_receive()})
            subscription:close()
            test.eq(selected.channel, subscription:channel())
            test.eq(selected.value.path, workspace)
            local alert = assert(bounds.object(selected.value.data))
            test.eq(alert.approval_id, requested.approval_id)
            test.eq(alert.count, 1)
            test.contains(tostring(alert.title), "Install")
            local person = harness.person(workspace)
            local card = harness.value(harness.reply(person:call("bee.approvals.binding:read", {approval_id = requested.approval_id})))
            test.eq(card.contract_version, 2)
            test.contains(tostring(assert(bounds.object(card.prompt)).text), "Read workspace files under testdata")
            test.eq(assert(bounds.object(assert(bounds.object(card.contract)).continuation)).destination, "gov.activation")
            local replay = harness.value(harness.request(author, "bundle", workspace, "1", digest))
            test.eq(replay.approval_id, requested.approval_id)
            local db = assert(sql.get("bee:db"))
            local cards = assert(db:query("SELECT approval_id FROM bee_approval_requests WHERE workspace_id = ?", {workspace}))
            test.eq(#cards, 1)
            db:release()
            test.eq(harness.settle(author, "bundle", workspace, requested, "1").outcome, "applied")
            local requirement = assert(registry.get("app.bundle:files"))
            test.not_nil(assert(bounds.object(requirement.data)).default)
            harness.value(harness.library(workspace, {operation = "uninstall", source_workspace = "bundle", receipt_key = "bundle-remove"}))
            harness.close_presented(before)
            assert(files:remove(directory .. "/testdata"))
            assert(files:remove(directory))
        end)
        test.it("refuses malformed Lua at the same location for checks and delivery", function()
            local workspace = harness.isolated("syntax-preflight")
            local author = harness.author(workspace, "syntax")
            local pack = entries("syntax")
            local data = assert(bounds.object(pack[1].data))
            data.source = "local value =\nreturn { main = function() end }"
            local digest = harness.freeze(author, "syntax", pack, "1")
            local checked = harness.value(harness.reply(author:call("bee.gov.binding:delivery_call", {
                operation = "preflight", workspace_id = workspace, source_overlay_id = "syntax",
                version = "1", snapshot_digest = digest})))
            test.eq(checked.ready, false)
            local diagnostics = assert(bounds.array(checked.diagnostics, 128))
            local diagnostic = assert(bounds.object(diagnostics[1]))
            test.eq(diagnostic.code, "LUA_LOAD_FAILED")
            test.contains(tostring(diagnostic.message), "app.syntax:")
            test.contains(tostring(diagnostic.message), ":2:")
            local delivered = harness.value(harness.request(author, "syntax", workspace, "1", digest))
            test.eq(delivered.ready, false)
            test.is_nil(delivered.approval_id)
            test.eq(assert(json.encode(delivered.diagnostics)), assert(json.encode(checked.diagnostics)))
        end)
        test.it("locates an incomplete source at end of file", function()
            local workspace = harness.isolated("eof-preflight")
            local author = harness.author(workspace, "eof")
            local pack = entries("eof")
            assert(bounds.object(pack[1].data)).source = "local value = "
            local digest = harness.freeze(author, "eof", pack, "1")
            local checked = harness.value(harness.reply(author:call("bee.gov.binding:delivery_call", {
                operation = "preflight", workspace_id = workspace, source_overlay_id = "eof",
                version = "1", snapshot_digest = digest})))
            test.eq(checked.ready, false)
            local rows = assert(bounds.array(checked.diagnostics, 128))
            local diagnostic = assert(bounds.object(rows[1]))
            test.eq(diagnostic.code, "LUA_LOAD_FAILED")
            test.contains(tostring(diagnostic.message), "app.eof:app:1:15")
        end)
        test.it("checks destination admission without staging or asking for approval", function()
            local workspace = harness.isolated("dx-preflight")
            local author = harness.author(workspace, "dx")
            for _, module in ipairs({"tty", "registry"}) do
                local name = "dx" .. module
                local pack = entries(name)
                local data = assert(bounds.object(pack[1].data))
                local modules = assert(bounds.array(data.modules, 32))
                if module ~= "tty" then modules[#modules + 1] = module end
                data.modules = modules
                local digest = harness.freeze(author, name, pack, "1")
                local checked = harness.value(harness.reply(author:call("bee.gov.binding:delivery_call", {
                    operation = "preflight", workspace_id = workspace, source_overlay_id = name,
                    version = "1", snapshot_digest = digest})))
                test.eq(checked.ready, module == "tty")
                test.eq(checked.staged, false)
                test.is_nil(json_schema.validate(assert(mcp.OUTPUT_SCHEMAS.delivery), {ok = true, value = checked}))
                test.is_nil(checked.approval_id)
                local listed = harness.value(harness.library(workspace, {operation = "list"}))
                test.eq(#assert(bounds.array(listed.plans, 128)), 0)
                if module == "registry" then
                    local rows = assert(bounds.array(checked.diagnostics, 128))
                    local found = false
                    for _, raw in ipairs(rows) do
                        local row = assert(bounds.object(raw))
                        if row.code == "MODULE_DENIED" then
                            found = true
                            test.is_true(tostring(row.remedy):find("No app capability", 1, true) ~= nil)
                            test.is_true(tostring(row.remedy):find("components", 1, true) ~= nil)
                            test.is_true(tostring(row.message):find("registry", 1, true) ~= nil)
                        end
                    end
                    test.is_true(found)
                    local delivered = harness.value(harness.request(author, name, workspace, "1", digest))
                    test.eq(delivered.ready, false)
                    test.eq(assert(json.encode(delivered.diagnostics)), assert(json.encode(checked.diagnostics)))
                    local status = harness.value(harness.reply(author:call("bee.gov.binding:delivery_call", {
                        operation = "status", workspace_id = workspace, source_overlay_id = name, version = "1"})))
                    test.is_nil(json_schema.validate(assert(mcp.OUTPUT_SCHEMAS.delivery), {ok = true, value = status}))
                end
            end
        end)
    end)
end
return test.run_cases(define_tests)
