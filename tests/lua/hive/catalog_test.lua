-- MIT. The exposure catalog: host ceilings, malformed declarations, and
-- interfaces that narrow but never widen.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local catalog = require("catalog")
local types = require("types")
type Probe = {generation: integer, operations: {string}, interfaces: {string}, diagnostics: {string}}
local function probe(policies: {string}): Probe
    local list: {security.Policy} = {}
    for index, name in ipairs(policies) do
        local policy, err = security.policy(name)
        if not policy then error("policy " .. name .. ": " .. tostring(err)) end
        list[index] = policy
    end
    local result, err = funcs.new():with_scope(security.new_scope(list)):call("bee.hive:catalog_probe", {})
    if err or type(result) ~= "table" then error("probe: " .. tostring(err)) end
    return result :: Probe
end
local function has(list: {string}, item: string): boolean
    for _, candidate in ipairs(list) do if candidate == item then return true end end
    return false
end
local function operation(): {[string]: unknown}
    return {id = "bee.hive:probe_open", kind = "function.lua", meta = {hive = "open", hive_operation = {revision = "1", title = "Probe",
        input = {type = "object", additionalProperties = false, properties = {name = {type = "string"}, count = {type = "integer"}}},
        output = {type = "object", additionalProperties = false, properties = {}}}}, data = {source = "file://probe_open.lua", method = "handle"}}
end
local function define_tests()
    test.describe("Hive catalog", function()
        test.it("includes only operations the host ceiling admits", function()
            local full = probe({"bee:hive_catalog_policy", "bee:hive_exposure_policy", "bee.hive:probe_exposure_policy"})
            test.is_true(has(full.operations, "bee.hive.telemetry:stats"))
            test.is_true(has(full.operations, "bee.hive:probe_open"))
            test.is_true(has(full.interfaces, "bee.hive:probe_tool"))
            local narrow = probe({"bee:hive_catalog_policy", "bee:hive_exposure_policy"})
            test.is_true(has(narrow.operations, "bee.hive.telemetry:stats"))
            test.is_false(has(narrow.operations, "bee.hive:probe_open"))
            test.is_false(has(narrow.interfaces, "bee.hive:probe_tool"))
            test.is_true(has(narrow.diagnostics, "bee.hive:probe_open: host ceiling denies open"))
            test.is_false(has(full.operations, "bee.hive:probe_bad_meta"))
            test.is_true(has(full.diagnostics, "bee.hive:probe_bad_meta: meta.hive_operation is required"))
            test.is_false(has(full.operations, "bee.hive:probe_policy_mode"))
            test.is_true(has(full.diagnostics, "bee.hive:probe_policy_mode: host ceiling denies policy"))
        end)
        test.it("rejects malformed declarations and unsupported callables", function()
            local good, good_error = catalog.decode_operation(operation())
            if not good then error(tostring(good_error)) end
            test.eq(good.mode, "open")
            test.eq(good.limits.max_input_bytes, types.MAX_INPUT_BYTES)
            test.eq(#good.measured, 64)
            local kind = operation()
            kind.kind = "library.lua"
            local _, kind_error = catalog.decode_operation(kind)
            test.eq(kind_error, "bee.hive:probe_open: exposure requires a function.lua entry")
            local mode = operation()
            mode.meta.hive = "public"
            local _, mode_error = catalog.decode_operation(mode)
            test.eq(mode_error, "bee.hive:probe_open: meta.hive must be open, approval or policy")
            local loose = operation()
            loose.meta.hive_operation.input = {type = "object", properties = {}}
            local _, loose_error = catalog.decode_operation(loose)
            test.eq(loose_error, "bee.hive:probe_open: input schema must set additionalProperties to false")
            local actor = operation()
            actor.data.security = {actor = {id = "root"}}
            local _, actor_error = catalog.decode_operation(actor)
            test.eq(actor_error, "bee.hive:probe_open: an exposed operation cannot replace the caller's actor")
            local limit = operation()
            limit.meta.hive_operation.limits = {max_input_bytes = types.MAX_INPUT_BYTES + 1}
            local _, limit_error = catalog.decode_operation(limit)
            test.eq(limit_error, "bee.hive:probe_open: max_input_bytes must be between 1 and " .. tostring(types.MAX_INPUT_BYTES))
            local changed = operation()
            changed.data.source = "file://other.lua"
            local other = catalog.decode_operation(changed)
            if not other then error("changed operation") end
            test.neq(other.measured, good.measured)
        end)
        test.it("applies interfaces from one snapshot and refuses widening", function()
            local snapshot, snapshot_error = catalog.snapshot()
            if not snapshot then error(tostring(snapshot_error)) end
            local resolved, resolve_error = catalog.apply_interface(snapshot, "bee.hive:probe_tool", {name = "x"})
            if not resolved then error(tostring(resolve_error)) end
            test.eq(resolved.operation.operation_ref, "bee.hive:probe_open")
            test.eq(#resolved.operation.measured, 64)
            test.eq(resolved.operation.limits.max_output_bytes, types.MAX_OUTPUT_BYTES)
            test.eq(resolved.input.count, 5)
            test.eq(resolved.input.name, "x")
            test.eq(resolved.generation, snapshot.generation)
            local direct = catalog.resolve_call(snapshot, "bee.hive:probe_open", {name = "x", count = 5})
            if not direct then error("direct call") end
            test.eq(direct.input_digest, resolved.input_digest)
            local _, fixed = catalog.apply_interface(snapshot, "bee.hive:probe_tool", {name = "x", count = 9})
            test.eq(fixed, "argument count is fixed by the interface")
            local _, extra = catalog.apply_interface(snapshot, "bee.hive:probe_tool", {name = "x", other = 1})
            test.eq(extra, "argument other is not accepted by the interface")
            local _, schema = catalog.apply_interface(snapshot, "bee.hive:probe_tool", {name = 12})
            test.is_true(tostring(schema):find("input does not satisfy the operation schema", 1, true) ~= nil)
            local _, missing = catalog.apply_interface(snapshot, "bee.hive:probe_widening", {name = "x"})
            test.eq(missing, "interface bee.hive:probe_widening is not exposed")
            test.is_true(has(snapshot.diagnostics, "bee.hive:probe_widening: allowed argument extra is not an operation input"))
            local empty, empty_error = catalog.resolve_call(snapshot, "bee.hive:probe_policy_mode", {})
            if not empty then error(tostring(empty_error)) end
            test.eq(empty.operation.mode, "policy")
            local _, unexposed = catalog.resolve_call(snapshot, "bee.hive:nothing", {})
            test.eq(unexposed, "operation bee.hive:nothing is not exposed")
            local summaries = catalog.summaries(snapshot)
            for _, summary in ipairs(summaries) do
                test.is_nil((summary :: {[string]: unknown}).input_schema)
                test.is_nil((summary :: {[string]: unknown}).measured)
            end
        end)
        test.it("re-resolves an operation at admission under the current ceiling", function()
            local operation_ref = "bee.hive.telemetry:presence"
            local resolved, resolve_error = catalog.resolve(operation_ref)
            if not resolved then error(tostring(resolve_error)) end
            test.eq(resolved.mode, "open")
            local _, missing = catalog.resolve("bee.hive:nothing")
            test.eq(missing, "operation is not in the registry")
            local policy_mode = catalog.resolve("bee.hive:probe_policy_mode")
            if not policy_mode then error("policy operation under the runner scope") end
            test.eq(policy_mode.mode, "policy")
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
