-- MIT. The authoring guide is a product surface: bounded, self-describing and
-- derived from the rules the destination actually enforces.
local test = require("test")
local guide = require("guide")
local artifact = require("artifact")
local preflight = require("preflight")
local naming = require("workspace_applications")
local json = require("json")

local function define_tests()
    test.describe("Governance application guide", function()
        test.it("names the artifact file and one process.lua application entry", function()
            local value = guide.value()
            test.eq(value.revision, guide.REVISION)
            local document = value.document :: string
            test.not_nil(string.find(document, "entries.json", 1, true))
            test.not_nil(string.find(document, "process.lua", 1, true))
            test.not_nil(string.find(document, "bee.application", 1, true))
            test.not_nil(string.find(document, "freeze", 1, true))
            test.not_nil(string.find(document, "Overlays", 1, true))
            test.not_nil(string.find(document, "Approvals", 1, true))
            test.not_nil(string.find(document, "append migration functions", 1, true))
            test.not_nil(string.find(document, "existing host-admitted database", 1, true))
        end)
        test.it("names the workspace delivery rule and follows it in its example", function()
            local document = guide.value().document :: string
            test.not_nil(string.find(document, naming.RULE, 1, true))
            test.not_nil(string.find(document, "workspace_id defaults to your own workspace", 1, true))
            test.not_nil(string.find(document, "create overlay " .. guide.OVERLAY_ID, 1, true))
            local identity = assert(naming.identity(string.rep("a", 32), guide.OVERLAY_ID))
            test.eq(guide.DEFINITION_ID, identity.definition_id)
            test.eq(guide.NAMESPACE, identity.namespace)
            test.eq((guide.example()[1] :: {[string]: unknown}).id, identity.definition_id)
        end)
        test.it("points at the offline platform documentation the docs tool reads", function()
            local document = guide.value().document :: string
            -- An agent that reads the application contract must be told where
            -- the platform documentation is and how to look things up.
            test.not_nil(string.find(document, "docs tool", 1, true))
            test.not_nil(string.find(document, guide.DOCS_REVISION, 1, true))
            test.not_nil(string.find(document, "list, search and read", 1, true))
            -- The topics for cross-node applications and for terminal UIs are
            -- named by their corpus names, which the corpus manifest carries.
            for _, topic in ipairs(guide.CROSS_NODE_TOPICS) do
                test.not_nil(string.find(document, topic, 1, true))
            end
            for _, topic in ipairs(guide.TERMINAL_TOPICS) do
                test.not_nil(string.find(document, topic, 1, true))
            end
            test.not_nil(string.find(document, "hive", 1, true))
            test.not_nil(string.find(document, "toolkit", 1, true))
            test.not_nil(string.find(document, "docs/guides/ui.md", 1, true))
            test.not_nil(string.find(document, "src/apps/stylebook/", 1, true))
            test.not_nil(string.find(document, "canonical runnable", 1, true))
        end)
        test.it("routes every application request to its archetype, the style rules and the kit", function()
            local document = guide.value().document :: string
            for _, needle in ipairs({"docs/guides/app-style.md", "80x24", "120x36", "160x48", "frame.size", "frame.layout",
                "bee.application:viz", "viz = \"bee.application:viz\"", "src/apps/monitor/", "System Monitor", "one-shot"}) do
                test.eq(needle .. (string.find(document, needle, 1, true) and "" or " missing"), needle)
            end
            test.eq(#guide.ARCHETYPES, 6)
            for _, archetype in ipairs(guide.ARCHETYPES) do
                test.not_nil(string.find(document, archetype.name .. ": " .. archetype.request, 1, true))
                for _, call in ipairs(archetype.calls) do
                    test.eq(archetype.name .. " " .. call .. (string.find(document, call, 1, true) and "" or " missing"),
                        archetype.name .. " " .. call)
                end
            end
        end)
        test.it("derives the CONFIG_SHAPE rule from the enforcing tables", function()
            local rule = guide.config_shape_rule()
            for kind, fields in pairs(preflight.CONFIG_LISTS) do
                for field in pairs(fields) do
                    test.not_nil(string.find(rule, kind .. " reads " .. field .. " as a list", 1, true))
                end
            end
            for kind, fields in pairs(preflight.CONFIG_OBJECTS) do
                for field in pairs(fields) do
                    test.not_nil(string.find(rule, kind .. " reads " .. field .. " as a named object", 1, true))
                end
            end
            test.not_nil(string.find(guide.value().document :: string, rule, 1, true))
        end)
        test.it("carries one measurable example entry with inline source", function()
            local encoded = guide.example_json()
            local decoded, decode_error = json.decode(encoded :: string)
            test.is_nil(decode_error)
            local measured, measure_error = artifact.create(decoded)
            test.is_nil(measure_error)
            test.eq(#measured.entries, 1)
            test.eq(measured.entries[1].id, guide.DEFINITION_ID)
            test.eq(measured.entries[1].kind, "process.lua")
            test.eq((measured.entries[1].meta :: {[string]: unknown}).type, "bee.application")
            local data = measured.entries[1].data :: {[string]: unknown}
            local source = data.source :: string
            local modules = data.modules :: {string}
            local imports = data.imports :: {[string]: unknown}
            test.eq(#modules, 4)
            test.eq(modules[1], "tty")
            test.eq(modules[2], "process")
            test.eq(modules[3], "channel")
            test.eq(modules[4], "json")
            test.eq(imports.client, "bee.application:client")
            test.eq(imports.appearance, "bee.application:appearance")
            test.eq(imports.frame, "bee.application:frame")
            test.is_true(#source < 10000)
            for _, fragment in ipairs({
                "local appearance = require(\"appearance\")", "appearance.defaults()",
                "local frame = require(\"frame\")", "frame.new(width, height, preferences)",
                "frame.header(painter, \"COUNTER APP\"", "frame.actions(painter, height - 1", "primary = true",
                "frame.footer(painter, \"Status: \" .. status, HINTS)", "frame.hints(", "frame.hit(hits",
                "frame.rows(painter)", "tty.mouse(true)", "WORK",
                "message:from() == launch.broker_pid", "data.version == 1",
                "data.request_id == pending_request_id", "local submitted = pending_count",
                "data.error_code == \"\"", "saved = submitted", "data.error_code == \"superseded\"",
                "status = \"Save failed\"", "data.key_type == \"enter\"",
                "data.key_type == \"escape\"", "data.type == \"mouse\"",
            }) do
                test.not_nil(string.find(source, fragment, 1, true))
            end
            test.is_nil(string.find(source, "file://", 1, true))
            -- The example's modules are a list and its imports an object, so the
            -- guide's own example satisfies the rule the guide states.
            local objects, lists, empty = artifact.config_shapes(data)
            test.is_true(#empty == 0 and #lists == 1 and #objects == 1)
            test.eq(lists[1], "modules")
            test.eq(objects[1], "imports")
            test.not_nil(string.find(source, "client.checkpoint", 1, true))
            local application = (measured.entries[1].meta :: {[string]: unknown}).application :: {[string]: unknown}
            test.eq(application.resume_schema, "guide-counter.v1")
            test.eq(application.restart_policy, "automatic")
        end)
    end)
end

return test.run_cases(define_tests)
