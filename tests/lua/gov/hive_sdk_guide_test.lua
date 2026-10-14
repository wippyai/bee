-- MIT
local test = require("test")
local guide = require("guide")
local json = require("json")
local bounds = require("bounds")
local harness = require("harness")
type Object = {[string]: unknown}
local function define_tests()
    test.describe("Hive SDK authoring guide", function()
        test.it("teaches bounded peer calls and explicit destination consent", function()
            local section = assert(guide.section_text("hive_sdk"))
            for _, phrase in ipairs({"hive.call", "hive.expose", "agent.tools", "app_tools", "idempotency_key", "outcome unknown", "follow_source"}) do
                test.contains(section, phrase)
            end
            test.contains(section, '"app.test_sdk:app"')
            test.contains(section, "entries.json")
        end)
        test.it("admits the exact SDK manifest through the production frozen delivery preflight", function()
            local workspace = harness.isolated("hive-sdk-guide")
            local writer = harness.author(workspace, "hive_sdk_guide")
            local section = assert(guide.section_text("hive_sdk"))
            local marker = "entries.json (freeze this complete JSON list):\n"
            local start = assert((section:find(marker, 1, true)))
            local decoded = assert(json.decode(section:sub(start + #marker))) :: {Object}
            test.eq(#decoded, 9)
            local result = harness.value(harness.deliver(writer, "test_sdk", workspace, decoded, "1.0.0"))
            local diagnostics = assert(json.encode(result.diagnostics))
            test.is_true(result.ready == true, diagnostics)
            test.eq(result.pending_migrations, 0)
            test.eq(result.activation_phase, "approval_bound", assert(json.encode(result)))
            test.not_nil(bounds.id(result.approval_id))
        end)
    end)
end
return test.run_cases(define_tests)
