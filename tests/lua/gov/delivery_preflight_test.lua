local test = require("test")
local bounds = require("bounds")
local json = require("json")
local harness = require("harness")
local guide = require("guide")
local mcp = require("mcp")
local json_schema = require("json_schema")
type Object = {[string]: unknown}
local function entries(name: string): {Object}
    local bytes = assert(json.encode(guide.example())):gsub("app.counter", "app." .. name)
    return assert(json.decode(bytes)) :: {Object}
end
local function define_tests()
    test.describe("agent delivery preflight", function()
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
