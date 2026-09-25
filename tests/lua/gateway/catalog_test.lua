-- MIT. Component tool declarations never grant authority by themselves.
local test = require("test")
local catalog = require("catalog")
local surface = require("surface")
local mcp = require("mcp")
local access = require("access")
local function sample()
    return {tools = {{name = "measure", operation = "research:measure", description = "Run the admitted benchmark",
        policies = {"research:measure_policy"}, schema = {type = "object"}, annotations = {readOnlyHint = false}}},
        traits = {{id = "research:benchmark", title = "Benchmark", prompt = "Measure first", tools = {"measure"}},
            {id = "research:compare", title = "Compare", prompt = "Compare samples", tools = {"measure"}}}}
end
local function requestable_surface()
    return {tools = {
            {name = "measure", operation = "research:measure", description = "Measure samples",
                policies = {"research:measure_policy"}, schema = {type = "object"}, annotations = {readOnlyHint = false}},
            {name = "export", operation = "research:export", description = "Export a report",
                policies = {"research:export_policy"}, schema = {type = "object"}, annotations = {readOnlyHint = false}}},
        traits = {
            {id = "research:benchmark", title = "Benchmark", prompt = "Measure first", tools = {"measure"}},
            {id = "research:export", title = "Export", prompt = "Export after approval", tools = {"export"}}},
        base_tools = {"measure"}, active_traits = {}, dynamic_keys = {}, fixed_context = {app = "fixed"},
        access = {policy = "research:approval", traits = {"research:export"}}}
end
local function define_tests()
    test.describe("Configurable MCP catalog", function()
        test.it("copies two traits sharing a tool without sharing configuration tables", function()
            local raw = sample()
            local decoded = catalog.decode(raw)
            if not decoded then error("valid catalog refused") end
            test.eq(#decoded.traits, 2)
            raw.tools[1].policies[1] = "foreign:policy"
            test.eq(decoded.tools[1].policies[1], "research:measure_policy")
        end)
        test.it("rejects aliases, unknown references and permission-shaped extra fields", function()
            local duplicate = sample()
            duplicate.tools[2] = duplicate.tools[1]
            test.is_nil(catalog.decode(duplicate))
            local missing = sample()
            missing.traits[1].tools = {"unadmitted"}
            test.is_nil(catalog.decode(missing))
            test.is_nil(catalog.decode({tools = {}, traits = {}, authority = "root"}))
            local invalid = sample()
            invalid.tools[1].policies = {}
            test.is_nil(catalog.decode(invalid))
        end)
        test.it("validates tool schemas and annotations at admission", function()
            for _, tool in ipairs(mcp.TOOLS) do
                local decoded = catalog.decode({tools = {{name = tool.name, operation = tool.operation,
                    description = tool.description, policies = tool.policies, schema = tool.schema,
                    annotations = tool.annotations}}, traits = {}})
                test.not_nil(decoded)
            end
            local function declared(schema: unknown, annotations: unknown)
                return {tools = {{name = "probe", operation = "research:probe", description = "Probe",
                    policies = {"research:probe_policy"}, schema = schema, annotations = annotations}}, traits = {}}
            end
            test.is_nil(catalog.decode(declared({type = "object", properties = {q = {type = "string", bogus = true}}}, {readOnlyHint = true})))
            test.is_nil(catalog.decode(declared({type = "string"}, {readOnlyHint = true})))
            test.is_nil(catalog.decode(declared({type = "object"}, {readOnlyHint = "yes"})))
            test.is_nil(catalog.decode(declared({type = "object"}, {readOnlyHint = true, extraHint = false})))
            test.is_nil(catalog.decode(declared({type = "object", required = {"missing"}}, {readOnlyHint = true})))
            test.not_nil(catalog.decode(declared({type = "object", required = {"q"},
                properties = {q = {type = "string", enum = {"a", "b"}, minLength = 1}}}, {readOnlyHint = true})))
        end)
        test.it("rejects sparse lists and oversized configuration", function()
            test.is_nil(catalog.decode({tools = {[2] = sample().tools[1]}, traits = {}}))
            local large = sample()
            large.traits[1].prompt = string.rep("x", 16385)
            test.is_nil(catalog.decode(large))
        end)
        test.it("unions activated traits within the independent tool ceiling", function()
            local decoded = catalog.decode(sample())
            if not decoded then error("catalog") end
            local tools = catalog.select(decoded, {"measure"}, {}, {"research:benchmark", "research:compare"},
                {"research:benchmark", "research:compare"})
            if not tools then error("select") end
            test.eq(#tools, 1)
            test.is_nil(catalog.select(decoded, {}, {}, {"research:benchmark"}, {"research:benchmark"}))
            test.is_nil(catalog.select(decoded, {"measure"}, {}, {}, {"research:benchmark"}))
            local inactive = catalog.select(decoded, {"measure"}, {}, {"research:benchmark"}, {})
            if not inactive then error("inactive") end
            test.eq(#inactive, 0)
        end)
        test.it("keeps requestable traits gated until a copied surface grants them", function()
            local raw = requestable_surface()
            local prepared, initial = surface.prepare(raw, {}, {"measure", "export"})
            if not prepared or not initial then error("valid requestable surface refused") end
            test.eq(#prepared.allowed_traits, 1)
            test.eq(prepared.allowed_traits[1], "research:benchmark")
            test.is_nil(surface.select(prepared, {"research:export"}, {}))
            local free = surface.select(prepared, {"research:benchmark"}, {})
            if not free then error("freely selectable trait refused") end
            local requested = {"research:export"}
            local granted, grant_error = surface.grant(prepared, requested)
            if not granted then error(tostring(grant_error)) end
            requested[1] = "research:benchmark"
            test.eq(#prepared.allowed_traits, 1)
            test.eq(#granted.allowed_traits, 2)
            test.eq(granted.allowed_traits[2], "research:export")
            local selected = surface.select(granted, {"research:export"}, {})
            if not selected then error("granted trait refused") end
            test.eq(#selected.active, 1)
            test.eq(granted.fixed_context.app, "fixed")
            test.eq(granted.fixed_context.app, prepared.fixed_context.app)
            test.is_nil(surface.select(prepared, {"research:export"}, {}))
            granted.allowed_traits[1] = "changed:outside"
            test.eq(prepared.allowed_traits[1], "research:benchmark")
            granted.access.traits[1] = "changed:outside"
            test.eq(prepared.access.traits[1], "research:export")
        end)
        test.it("rejects invalid requestable declarations and grant escalation", function()
            local raw = requestable_surface()
            raw.access.traits = {"research:missing"}
            test.is_nil(surface.prepare(raw, {}, {"measure", "export"}))
            raw = requestable_surface()
            raw.access.traits = {"research:export", "research:export"}
            test.is_nil(surface.prepare(raw, {}, {"measure", "export"}))
            raw = requestable_surface()
            raw.base_tools = {"measure", "export"}
            test.is_nil(surface.prepare(raw, {}, {"measure", "export"}))
            raw = requestable_surface()
            raw.traits[1].tools = {"measure", "export"}
            test.is_nil(surface.prepare(raw, {}, {"measure", "export"}))
            raw = requestable_surface()
            raw.access.extra = true
            test.is_nil(surface.prepare(raw, {}, {"measure", "export"}))
            raw = requestable_surface()
            raw.active_traits = {"research:export"}
            test.is_nil(surface.prepare(raw, {}, {"measure", "export"}))

            raw = requestable_surface()
            local prepared = surface.prepare(raw, {}, {"measure", "export"})
            if not prepared then error("valid surface refused") end
            test.is_nil(surface.grant(prepared, {"research:benchmark"}))
            test.is_nil(surface.grant(prepared, {"research:missing"}))
            test.is_nil(surface.grant(prepared, {"research:export", "research:export"}))

            raw = requestable_surface()
            prepared = surface.prepare(raw, {}, {"measure"})
            if not prepared then error("surface with deferred tool refused") end
            test.is_nil(surface.grant(prepared, {"research:export"}))
        end)
        test.it("keeps surfaces without access configuration freely selectable", function()
            local raw = requestable_surface()
            raw.access = nil
            local prepared = surface.prepare(raw, {}, {"measure", "export"})
            if not prepared then error("plain surface refused") end
            test.eq(prepared.access, nil)
            test.eq(#prepared.allowed_traits, 2)
            if not surface.select(prepared, {"research:export"}, {}) then error("plain trait unavailable") end
        end)
        test.it("takes the approval workspace from the binding, never from the declaration", function()
            local raw = requestable_surface()
            raw.access = {policy = "research:approval", workspace_id = "declared-workspace", traits = {"research:export"}}
            test.is_nil(surface.prepare(raw, {}, {"measure", "export"}))
            local prepared = surface.prepare(requestable_surface(), {}, {"measure", "export"})
            if not prepared then error("requestable surface refused") end
            local unbound = {binding_id = "binding-one", subject = "bee.test.gateway", action_id = "action-one",
                attempt_id = "attempt-one", thread_id = "thread-one"}
            local reply = access.request(unbound, prepared, string.rep("a", 64),
                {idempotency_key = "export", traits = {"research:export"}, reason = "Export the report"})
            test.eq(reply.ok, false)
            test.eq((reply.error :: {code: string, message: string}).code, "DENIED")
            test.eq((reply.error :: {code: string, message: string}).message, "this binding names no workspace to request MCP access in")
        end)
        test.it("gates application_open behind the approved runtime trait", function()
            local raw = {tools = {}, traits = {}, base_tools = {}, active_traits = {}, fixed_context = {}, dynamic_keys = {},
                access = {policy = "application:approval", traits = {"bee.application:runtime"}}}
            local prepared, initial = surface.prepare(raw, mcp.TOOLS, {"application_open"})
            if not prepared or not initial then error("runtime surface refused") end
            test.is_nil(surface.select(prepared, {"bee.application:runtime"}, {}))
            local granted, grant_error = surface.grant(prepared, {"bee.application:runtime"})
            if not granted then error(tostring(grant_error)) end
            local selected = surface.select(granted, {"bee.application:runtime"}, {})
            if not selected then error("approved runtime trait refused") end
            local active = catalog.select(granted.catalog, granted.ceiling, granted.base_tools, granted.allowed_traits, selected.active)
            if not active or #active ~= 1 or active[1].name ~= "application_open" then error("runtime tool not active") end
            local inactive = surface.select(granted, {}, {})
            if not inactive then error("runtime trait deselection refused") end
            local hidden = catalog.select(granted.catalog, granted.ceiling, granted.base_tools, granted.allowed_traits, inactive.active)
            if not hidden or #hidden ~= 0 then error("runtime tool remained active after deselection") end

            raw = {tools = {}, traits = {}, base_tools = {"application_open"}, active_traits = {}, fixed_context = {}, dynamic_keys = {},
                access = {policy = "application:approval", traits = {"bee.application:runtime"}}}
            test.is_nil(surface.prepare(raw, mcp.TOOLS, {"application_open"}))
            raw.base_tools = {}
            raw.access = nil
            test.is_nil(surface.prepare(raw, mcp.TOOLS, {"application_open"}))
            raw.access = {policy = "application:approval", traits = {"bee.application:runtime"}}
            raw.traits = {{id = "application:spoof", title = "Spoof", prompt = "Spoof", tools = {"application_open"}}}
            test.is_nil(surface.prepare(raw, mcp.TOOLS, {"application_open"}))
        end)
    end)
end
return require("test").run_cases(define_tests)
