-- MIT. The authoring guide is a product surface: bounded, self-describing and
-- derived from the rules the destination actually enforces.
local test = require("test")
local principals = require("principals")
local bounds = require("bounds")
local guide = require("guide")
local artifact = require("artifact")
local preflight = require("preflight")
local naming = require("workspace_applications")
local json = require("json")

local function define_tests()
    test.describe("Governance application guide", function()
        test.it("explains how an approved driver becomes selectable in Sessions", function()
            local text = guide.driver_delivery()
            for _, needle in ipairs({"presentation.start_menu = true", "session_resource = session", "Sessions", "N", "E", "default_mode window", "docker_credentials"}) do
                test.not_nil((string.find(text, needle, 1, true)))
            end
            local steps, next_app = guide.delivery_steps("driver.stubagent")
            test.eq(next_app, "Sessions")
            test.not_nil((string.find(steps[#steps], "N", 1, true)))
        end)
        test.it("names the artifact file and one process.lua application entry", function()
            local value = guide.value()
            test.eq(value.revision, guide.REVISION)
            local document = guide.document()
            test.not_nil((string.find(document, "entries.json", 1, true)))
            test.not_nil((string.find(document, "process.lua", 1, true)))
            test.not_nil((string.find(document, "bee.app", 1, true)))
            test.not_nil((string.find(document, "freeze", 1, true)))
            test.not_nil((string.find(document, "Needs you", 1, true)))
            test.not_nil((string.find(document, "append migration functions", 1, true)))
            test.not_nil((string.find(document, "existing host-admitted database", 1, true)))
        end)
        test.it("names the workspace delivery rule and follows it in its example", function()
            local document = guide.document()
            test.not_nil((string.find(document, naming.RULE, 1, true)))
            test.not_nil((string.find(document, "workspace_id defaults to your own workspace", 1, true)))
            test.not_nil((string.find(document, "create overlay " .. guide.OVERLAY_ID, 1, true)))
            local identity = assert(naming.identity(string.rep("a", 32), guide.OVERLAY_ID))
            test.eq(assert(naming.application(guide.example())), "app.counter:app")
            test.eq(guide.NAMESPACE, identity.namespace)
            test.eq((assert(bounds.object(guide.example()[1]))).id, assert(naming.application(guide.example())))
        end)
        test.it("explains how an application requests process execution, network and native modules", function()
            local text = guide.workspace_delivery()
            for _, needle in ipairs({"process.exec", "command", "directory", "explicitly", "MODULE_DENIED",
                "exec module", "contract module", "http.api", "bee.gov.binding:http_request",
                "bee.gov.binding:granted_resources", "executors", "Needs you"}) do
                test.not_nil((string.find(text, needle, 1, true)), needle)
            end
            local contents = guide.pack_contents()
            for _, needle in ipairs({"request_capability", "process_run", "http_request", "capability_status"}) do
                test.not_nil((string.find(contents, needle, 1, true)), needle)
            end
        end)
        test.it("points at the offline platform documentation the docs tool reads", function()
            local document = guide.document()
            -- An agent that reads the application contract must be told where
            -- the platform documentation is and how to look things up.
            test.not_nil((string.find(document, "docs tool", 1, true)))
            test.not_nil((string.find(document, guide.DOCS_REVISION, 1, true)))
            test.not_nil((string.find(document, "list, search and read", 1, true)))
            -- The topics for cross-node applications and for terminal UIs are
            -- named by their corpus names, which the corpus manifest carries.
            for _, topic in ipairs(guide.CROSS_NODE_TOPICS) do
                test.not_nil((string.find(document, topic, 1, true)))
            end
            for _, topic in ipairs(guide.TERMINAL_TOPICS) do
                test.not_nil((string.find(document, topic, 1, true)))
            end
            test.not_nil((string.find(document, "hive", 1, true)))
            test.not_nil((string.find(document, "toolkit", 1, true)))
            test.not_nil((string.find(document, "docs/ui_brand_book", 1, true)))
            test.not_nil((string.find(document, "compact examples", 1, true)))
            test.is_nil((string.find(document, "src/apps/stylebook/", 1, true)))
        end)
        test.it("routes every application request to its archetype, the style rules and the kit", function()
            local document = guide.document()
            for _, needle in ipairs({"docs/app_style", "80x24", "120x36", "160x48", "frame.size", "frame.layout",
                "bee.ui.viz:viz", "viz = \"bee.ui.viz:viz\"", "tested example", "one-shot"}) do
                test.eq(needle .. (string.find(document, needle, 1, true) and "" or " missing"), needle)
            end
            test.eq(#guide.ARCHETYPES, 6)
            for _, archetype in ipairs(guide.ARCHETYPES) do
                test.not_nil((string.find(document, archetype.name .. ": " .. archetype.request, 1, true)))
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
                    test.not_nil((string.find(rule, kind .. " reads " .. field .. " as a list", 1, true)))
                end
            end
            for kind, fields in pairs(preflight.CONFIG_OBJECTS) do
                for field in pairs(fields) do
                    test.not_nil((string.find(rule, kind .. " reads " .. field .. " as a named object", 1, true)))
                end
            end
            test.not_nil((string.find(guide.document(), rule, 1, true)))
        end)
        test.it("returns a short index first, sections on request and the example separately", function()
            local index = guide.value()
            test.eq(index.revision, guide.REVISION)
            local short = index.document
            test.is_true(#short < 1500)
            test.is_nil((assert(bounds.object(index))).example)
            test.not_nil((string.find(short, "entries.json", 1, true)))
            local sections = index.sections
            test.is_true(#sections >= 8)
            for _, section in ipairs(guide.section_list()) do
                test.not_nil((string.find(short, section.id, 1, true)))
                local read = guide.value({section = section.id})
                test.eq(read.section, section.id)
                test.eq(read.text, guide.section_text(section.id))
                test.is_nil((assert(bounds.object(read))).example)
            end
            local unknown = guide.value({section = "no-such-section"})
            test.not_nil((assert(bounds.object(unknown))).error)
            local example = guide.value({include_example = true})
            local entry = assert(bounds.object((assert(bounds.object(example))).example))
            test.eq(entry.definition_id, assert(naming.application(guide.example())))
            test.not_nil((string.find(entry.entries_json, "process.lua", 1, true)))
        end)
        test.it("teaches an application's own database and carries it in the example", function()
            local text = assert(guide.section_text("database"))
            for _, needle in ipairs({"app.database", "ns.requirement", "meta.type migration", "meta.target_db",
                "meta.ordinal", "wippy.migration:migration", "append-only", "Needs you", "bee.gov.binding:granted_resources",
                "sql.get", "database_entries_json"}) do
                test.not_nil((string.find(text, needle, 1, true)), needle)
            end
            test.not_nil((string.find(guide.index(), "database:", 1, true)))
            local example = assert(bounds.object((assert(bounds.object(guide.value({include_example = true})))).example))
            local decoded = assert(json.decode(tostring(example.database_entries_json)))
            local ids: {string} = {}
            for _, raw in ipairs(decoded :: {unknown}) do ids[#ids + 1] = tostring((assert(bounds.object(raw))).id) end
            test.eq(table.concat(ids, ","), "app.counter:database,app.counter:agent_tools,app.counter:create_counts,app.counter:count_record,app.counter:count_list")
            local pack: {{[string]: unknown}} = {guide.example()[1]}
            for _, entry in ipairs(guide.database_example()) do pack[#pack + 1] = entry end
            local _, measure_error = artifact.create(pack)
            test.is_nil(measure_error)
        end)
        test.it("teaches offering application tools to agents on the application's own state", function()
            local text = assert(guide.section_text("agent_tools"))
            for _, needle in ipairs({"meta.type tool", "llm_alias", "llm_description", "input_schema", "output_schema",
                "agent.tools", "{ok, value, error}", "no security", "granted_resources", "app_tools", "profile",
                "Needs you", "as the application", "TOOLS_CHANGED"}) do
                test.not_nil((string.find(text, needle, 1, true)), needle)
            end
            test.not_nil((string.find(guide.index(), "agent_tools:", 1, true)))
        end)
        test.it("teaches shipping tests and running them with the tests tool", function()
            local text = assert(guide.section_text("tests"))
            for _, needle in ipairs({"function.lua", "meta.type test", "meta.suite", "meta.timeout", "wippy.test:test",
                "test.describe", "test.it", "test.eq", "test.run_cases", "{run = function(options) return cases(options) end}", "library.lua",
                "tests tool", "run_id", "status", "pass, fail or skip", "as your application"}) do
                test.eq(needle .. (string.find(text, needle, 1, true) and "" or " missing"), needle)
            end
            test.not_nil((string.find(guide.document(), text, 1, true)))
            test.not_nil((string.find(guide.index(), "tests:", 1, true)))
            local example = assert(bounds.object((assert(bounds.object(guide.value({include_example = true})))).example))
            test.eq(example.test_entry_id, "app.counter:counter_test")
            local decoded = assert(json.decode(tostring(example.test_entry_json)))
            test.eq((assert(bounds.object(decoded))).kind, "function.lua")
        end)
        test.it("carries an example test entry the destination's preflight admits with the application", function()
            local pack = {guide.example()[1], guide.test_example()[1]}
            local measured, measure_error = artifact.create(pack)
            test.is_nil(measure_error)
            local entry = assert(bounds.object(measured.entries[2]))
            test.eq(entry.kind, "function.lua")
            test.eq((assert(bounds.object(entry.meta))).type, "test")
            local data = assert(bounds.object(entry.data))
            test.eq((assert(bounds.object(data.imports))).test, "wippy.test:test")
            test.is_nil((string.find(tostring(data.source), "file://", 1, true)))
            local no_strings: {string} = {}
            local function measure(item: {[string]: unknown}, references: {string}): preflight.Entry
                local item_data = assert(bounds.object(item.data))
                local objects, lists, empty = artifact.config_shapes(item_data)
                return {id = tostring(item.id), kind = tostring(item.kind), package = "app.counter", digest = string.rep("b", 64),
                    references = references, auto_start = false, grants = no_strings,
                    modules = item_data.modules and principals.strings(item_data.modules) or no_strings,
                    config_objects = objects, config_lists = lists, config_empty = empty,
                    application_unplaced = artifact.application_unplaced(item)}
            end
            local base: preflight.Entry = {id = "wippy.test:test", kind = "library.lua", package = "wippy/test", digest = string.rep("c", 64),
                references = no_strings, auto_start = false, grants = no_strings, modules = no_strings,
                config_objects = no_strings, config_lists = no_strings, config_empty = no_strings}
            local candidate: preflight.Candidate = {destination_node = "node-a", source_node = "node-a", base_revision = 1,
                base_digest = string.rep("a", 64),
                artifacts = {{component = "app.counter", version = "1.0.0", digest = string.rep("d", 64), dependencies = no_strings,
                    namespaces = {"app.counter"}}},
                entries = {measure(assert(bounds.object(measured.entries[1])), {"bee.app:client", "bee.ui:appearance", "bee.ui:frame", "bee.shell:apps_menu"}),
                    measure(entry, {"wippy.test:test"})},
                requirements = {}, migrations = {}}
            local context: preflight.Context = {node_id = "node-a", registry_revision = 1, registry_digest = string.rep("a", 64),
                policy_digest = string.rep("a", 64), packages = {["app.counter"] = true}, namespaces = {["app.counter"] = true},
                kinds = {["process.lua"] = true, ["function.lua"] = true}, databases = {}, entries = {["wippy.test:test"] = base,
                    ["bee.app:client"] = base, ["bee.ui:appearance"] = base, ["bee.ui:frame"] = base, ["bee.shell:apps_menu"] = base},
                installed_entries = nil, applied = {}, grants = {}, modules = {tty = true, process = true, channel = true, json = true},
                exact_expansion = true, migration_barrier = false, auto_start = false,
                protected = {revision = 1, namespaces = {"bee.gov", "bee.security"}, super_edit = {},
                    entries = {"bee.security.approvals:approver_policies", "bee.gov:protected_kernel"}},
                host_evidence = {application_admission = {kind = "absent"}, capability = {kind = "absent"}}}
            local report, check_error = preflight.check(candidate, context)
            if not report then error(tostring(check_error)) end
            local codes: {string} = {}
            for _, diagnostic in ipairs(report.diagnostics) do codes[#codes + 1] = diagnostic.code .. " " .. diagnostic.target end
            test.eq(table.concat(codes, ", "), "")
            test.is_true(report.ready)
        end)
        test.it("carries one measurable example entry with inline source", function()
            local encoded = guide.example_json()
            if type(encoded) ~= "string" then error("invalid fixture encoded") end
            local decoded, decode_error = json.decode(encoded)
            test.is_nil(decode_error)
            local measured, measure_error = artifact.create(decoded)
            test.is_nil(measure_error)
            test.eq(#measured.entries, 1)
            test.eq(measured.entries[1].id, assert(naming.application(guide.example())))
            test.eq(measured.entries[1].kind, "process.lua")
            local metadata = measured.entries[1].meta
            if type(metadata) ~= "table" then error("example metadata is not an object") end
            test.eq(metadata.type, "bee.app")
            local data = assert(bounds.object(measured.entries[1].data))
            local source = data.source
            local modules = principals.strings(data.modules)
            local imports = assert(bounds.object(data.imports))
            test.eq(#modules, 4)
            test.eq(modules[1], "tty")
            test.eq(modules[2], "process")
            test.eq(modules[3], "channel")
            test.eq(modules[4], "json")
            test.eq(imports.client, "bee.app:client")
            test.eq(imports.appearance, "bee.ui:appearance")
            test.eq(imports.frame, "bee.ui:frame")
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
                test.not_nil((string.find(source, fragment, 1, true)))
            end
            test.is_nil((string.find(source, "file://", 1, true)))
            -- The example's modules are a list and its imports an object, so the
            -- guide's own example satisfies the rule the guide states.
            local objects, lists, empty = artifact.config_shapes(data)
            test.is_true(#empty == 0 and #lists == 1 and #objects == 1)
            test.eq(lists[1], "modules")
            test.eq(objects[1], "imports")
            test.not_nil((string.find(source, "client.checkpoint", 1, true)))
            local application = assert(bounds.object((assert(bounds.object(measured.entries[1].meta))).application))
            test.eq(application.resume_schema, "guide-counter.v1")
            test.eq(application.restart_policy, "automatic")
        end)
    end)
end

return test.run_cases(define_tests)
