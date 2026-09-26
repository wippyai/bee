-- MIT. Bounded OPEN telemetry dispatch tests: host exposure ceiling,
-- envelope verification, narrow policy scope, and output validation.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local types = require("types")
local bounds = require("bounds")
local dispatch = require("dispatch")

local function make_request(operation_ref: string, input: {[string]: unknown}): types.Request
    local digest, err = types.digest(input)
    if not digest then error("digest failed: " .. tostring(err)) end
    local colon = operation_ref:find(":", 1, true)
    local ns = colon and operation_ref:sub(1, colon - 1) or "bee.hive.telemetry"
    local raw = {
        protocol_revision = types.REVISION,
        request_id = "req-1",
        idempotency_key = "idem-1",
        caller_node_id = "laptop",
        caller_incarnation = "inc-1",
        owner_ref = {node_id = "forge", service_id = ns},
        operation_ref = operation_ref,
        operation_revision = "1",
        input = input,
        input_digest = digest,
        principal_ref = {issuer = "node:laptop", subject_id = "user-1"},
        principal_assertion = {
            method = types.ASSERTION_METHOD,
            audience = "forge",
            issued_at = "2026-09-08T10:00:00.000Z",
            expires_at = "2026-09-08T10:05:00.000Z",
        },
        delegation_refs = {},
        deadline = "2026-09-08T10:05:00.000Z",
    }
    local decoded, dec_err = types.decode_request(raw)
    if not decoded then error("invalid base request: " .. tostring(dec_err)) end
    return decoded
end

local function call_scoped(policies: {string}, req: types.Request): types.Reply
    local list: {security.Policy} = {}
    for index, name in ipairs(policies) do
        local policy, err = security.policy(name)
        if not policy then error("policy " .. name .. ": " .. tostring(err)) end
        list[index] = policy
    end
    local result, err = funcs.new():with_scope(security.new_scope(list)):call("bee.hive.supervisor:dispatch_probe", req)
    if err or type(result) ~= "table" then error("scoped call failed: " .. tostring(err)) end
    local reply, reply_err = types.decode_reply(result)
    if not reply then error("invalid reply envelope: " .. tostring(reply_err)) end
    return reply
end

local GROUP_SCOPE = {"bee.security.hive:hive_catalog_policy", "bee.security.hive:hive_exposure_facade_policy",
    "bee.hive:mapping_test_policy"}

local function set_audiences(rows: unknown)
    local list: {security.Policy} = {}
    for index, name in ipairs({"bee.security.hive:hive_catalog_policy", "bee.hive:mapping_test_policy"}) do
        local policy, err = security.policy(name)
        if not policy then error("policy " .. name .. ": " .. tostring(err)) end
        list[index] = policy
    end
    local result, err = funcs.new():with_scope(security.new_scope(list)):call("bee.hive.supervisor:audiences_probe", rows)
    if err or type(result) ~= "table" then error("audiences install failed: " .. tostring(err)) end
end

local function with_audiences(rows: unknown, fn: () -> ())
    set_audiences(rows)
    local ok, err = pcall(fn)
    set_audiences({})
    if not ok then error(err) end
end

local function define_tests()
    test.describe("Hive telemetry dispatch execution", function()
        test.it("successfully dispatches reviewed open telemetry operations", function()
            -- 1. stats
            local req_stats = make_request("bee.hive.telemetry:stats", {})
            local rep_stats = dispatch.dispatch(req_stats)
            test.is_true(rep_stats.ok)
            test.is_nil(rep_stats.error)
            test.eq(rep_stats.request_id, req_stats.request_id)
            test.eq(rep_stats.protocol_revision, types.REVISION)
            local stats_val = rep_stats.value
            test.is_true(type(stats_val) == "table")
            if type(stats_val) == "table" then
                test.is_true(type(stats_val.goroutines) == "number")
                test.is_true(type(stats_val.cpu_count) == "number")
                test.is_true(type(stats_val.memory) == "table")
                test.not_nil(bounds.timestamp(stats_val.sampled_at))
            end

            -- 2. presence
            local req_pres = make_request("bee.hive.telemetry:presence", {})
            local rep_pres = dispatch.dispatch(req_pres)
            test.is_true(rep_pres.ok)
            test.is_nil(rep_pres.error)
            local pres_val = rep_pres.value
            test.is_true(type(pres_val) == "table")
            if type(pres_val) == "table" then
                test.eq(pres_val.protocol_revision, types.REVISION)
                test.is_true(type(pres_val.cluster_size) == "number")
                test.not_nil(bounds.timestamp(pres_val.sampled_at))
            end

            -- 3. catalog_list
            local req_cat = make_request("bee.hive.telemetry:catalog_list", {})
            local rep_cat = dispatch.dispatch(req_cat)
            test.is_true(rep_cat.ok)
            test.is_nil(rep_cat.error)
            local cat_val = rep_cat.value
            test.is_true(type(cat_val) == "table")
            if type(cat_val) == "table" then
                test.is_true(type(cat_val.operations) == "table")
                test.is_true(type(cat_val.generation) == "number")
            end
        end)

        test.it("rejects request with wrong owner service id", function()
            local req = make_request("bee.hive.telemetry:stats", {})
            req.owner_ref = {node_id = "forge", service_id = "bee.wrong_service"}
            local rep = dispatch.dispatch(req)
            test.is_false(rep.ok)
            test.not_nil(rep.error)
            if rep.error then
                test.eq(rep.error.code, "INVALID_ARGUMENT")
            end
        end)

        test.it("rejects request when resource_ref is present (node telemetry only)", function()
            local req = make_request("bee.hive.telemetry:stats", {})
            req.owner_ref = {node_id = "forge", service_id = "bee.hive.telemetry", resource_ref = "cpu-core-0"}
            local rep = dispatch.dispatch(req)
            test.is_false(rep.ok)
            test.not_nil(rep.error)
            if rep.error then
                test.eq(rep.error.code, "INVALID_ARGUMENT")
            end
        end)

        test.it("rejects request with operation revision mismatch", function()
            local req = make_request("bee.hive.telemetry:stats", {})
            req.operation_revision = "999"
            local rep = dispatch.dispatch(req)
            test.is_false(rep.ok)
            test.not_nil(rep.error)
            if rep.error then
                test.eq(rep.error.code, "CONFLICT")
            end
        end)

        test.it("rejects request with input digest mismatch", function()
            local req = make_request("bee.hive.telemetry:catalog_list", {after_operation_ref = "bee:some_other_op"})
            -- Alter the digest so it no longer matches the input
            req.input_digest = "0000000000000000000000000000000000000000000000000000000000000000"
            local rep = dispatch.dispatch(req)
            test.is_false(rep.ok)
            test.not_nil(rep.error)
            if rep.error then
                test.eq(rep.error.code, "INVALID_ARGUMENT")
            end
        end)

        test.it("denies operations the host ceiling does not expose", function()
            -- probe_open carries open metadata in the catalog fixtures, but
            -- this scope selects no exposure policy for it, so dispatch denies
            -- it before resolving the catalog.
            local req = make_request("bee.hive:probe_open", {name = "node-1", count = 2})
            local rep = call_scoped({"bee.security.hive:hive_catalog_policy", "bee.hive:mapping_test_policy"}, req)
            test.is_false(rep.ok)
            test.not_nil(rep.error)
            if rep.error then
                test.eq(rep.error.code, "DENIED")
            end
        end)

        test.it("dispatches an operation the host ceiling exposes with no code allowlist", function()
            -- probe_open carries open metadata; the fixture ceiling grants it
            -- only under the probe exposure policy, so dispatch admits it only
            -- in a scope that selects that policy.
            local req = make_request("bee.hive:probe_open", {name = "node-1", count = 2})
            local rep = call_scoped({"bee.security.hive:hive_catalog_policy", "bee.hive:probe_exposure_policy",
                "bee.hive:mapping_test_policy"}, req)
            test.is_true(rep.ok)
            test.is_nil(rep.error)
        end)

        test.it("denies unexposed arbitrary functions", function()
            local req = make_request("bee.apps:welcome", {})
            local rep = dispatch.dispatch(req)
            test.is_false(rep.ok)
            test.not_nil(rep.error)
            if rep.error then
                test.eq(rep.error.code, "DENIED")
            end
        end)

        test.it("denies non-open operations such as policy or approval", function()
            -- probe_policy_mode has mode: policy
            local req = make_request("bee.hive:probe_policy_mode", {})
            local rep = dispatch.dispatch(req)
            test.is_false(rep.ok)
            test.not_nil(rep.error)
            if rep.error then
                test.eq(rep.error.code, "DENIED")
            end
        end)

        test.it("enforces host ceiling denial when exposure policy is absent", function()
            local req = make_request("bee.hive.telemetry:stats", {})
            -- Scope has catalog access but NOT hive_exposure_policy
            local rep = call_scoped({"bee.security.hive:hive_catalog_policy", "bee.security.hive:hive_dispatch_policy"}, req)
            test.is_false(rep.ok)
            test.not_nil(rep.error)
            if rep.error then
                test.eq(rep.error.code, "DENIED")
            end
        end)

        test.it("enforces narrow dispatch policy requirement on funcs.call", function()
            local req = make_request("bee.hive.telemetry:stats", {})
            -- Scope has exposure policy and catalog policy, but NOT hive_dispatch_policy
            local rep = call_scoped({"bee.security.hive:hive_catalog_policy", "bee.security.hive:hive_exposure_policy"}, req)
            test.is_false(rep.ok)
            test.not_nil(rep.error)
            if rep.error then
                test.eq(rep.error.code, "INTERNAL")
            end
        end)

        test.it("succeeds under explicitly scoped narrow policies", function()
            local req = make_request("bee.hive.telemetry:stats", {})
            -- Scope has exactly the necessary policies
            local rep = call_scoped({"bee.security.hive:hive_catalog_policy", "bee.security.hive:hive_exposure_policy", "bee.security.hive:hive_dispatch_policy"}, req)
            test.is_true(rep.ok)
            test.is_nil(rep.error)
        end)

        test.it("admits an operation an install grant joins to the exposure scope", function()
            -- No direct exposure grant in scope: the fixture grant policy
            -- joins the exposure scope, and the facade loads it.
            local req = make_request("bee.hive:probe_open", {name = "node-1", count = 2})
            local rep = call_scoped(GROUP_SCOPE, req)
            test.is_true(rep.ok)
            test.is_nil(rep.error)
        end)

        test.it("admits the host ceiling through the exposure scope", function()
            local req = make_request("bee.hive.telemetry:stats", {})
            local scope = {"bee.security.hive:hive_catalog_policy", "bee.security.hive:hive_exposure_facade_policy",
                "bee.security.hive:hive_dispatch_policy"}
            local rep = call_scoped(scope, req)
            test.is_true(rep.ok)
            test.is_nil(rep.error)
        end)

        test.it("refuses callers outside the listed audience", function()
            with_audiences({{operation_ref = "bee.hive:probe_open", peers = {"forge"}}}, function()
                local req = make_request("bee.hive:probe_open", {name = "node-1", count = 2})
                local rep = call_scoped(GROUP_SCOPE, req)
                test.is_false(rep.ok)
                test.not_nil(rep.error)
                if rep.error then
                    test.eq(rep.error.code, "DENIED")
                end
            end)
        end)

        test.it("admits listed peers and the owner's own callers", function()
            with_audiences({{operation_ref = "bee.hive:probe_open", peers = {"laptop"}}}, function()
                local req = make_request("bee.hive:probe_open", {name = "node-1", count = 2})
                local rep = call_scoped(GROUP_SCOPE, req)
                test.is_true(rep.ok)
                local local_req = make_request("bee.hive:probe_open", {name = "node-1", count = 2})
                local_req.caller_node_id = "forge"
                local_req.principal_ref = {issuer = "forge", subject_id = "user-1"}
                local local_rep = call_scoped(GROUP_SCOPE, local_req)
                test.is_true(local_rep.ok)
            end)
        end)

        test.it("refuses dispatch while the audience table is broken", function()
            with_audiences("broken", function()
                local req = make_request("bee.hive:probe_open", {name = "node-1", count = 2})
                local rep = call_scoped(GROUP_SCOPE, req)
                test.is_false(rep.ok)
                if rep.error then
                    test.eq(rep.error.code, "DENIED")
                end
            end)
        end)
    end)

    test.describe("Hive output result validator", function()
        local schema: {[string]: unknown} = {
            type = "object",
            additionalProperties = false,
            properties = {
                count = {type = "integer"},
                name = {type = "string"},
            },
        }

        test.it("validates compliant output against advertised schema and byte limits", function()
            local ok, err = dispatch.validate_output(schema, 1024, {count = 42, name = "test"})
            test.is_true(ok)
            test.is_nil(err)
        end)

        test.it("rejects non-table output", function()
            local ok, err = dispatch.validate_output(schema, 1024, "not_a_table")
            test.is_false(ok)
            test.not_nil(err)
        end)

        test.it("rejects output violating property types", function()
            local ok, err = dispatch.validate_output(schema, 1024, {count = "not_an_integer", name = "test"})
            test.is_false(ok)
            test.not_nil(err)
        end)

        test.it("rejects output violating additionalProperties", function()
            local ok, err = dispatch.validate_output(schema, 1024, {count = 1, name = "test", rogue = "data"})
            test.is_false(ok)
            test.not_nil(err)
        end)

        test.it("rejects oversized output exceeding max_output_bytes", function()
            local ok, err = dispatch.validate_output(schema, 15, {count = 1, name = "this_string_makes_it_far_too_large"})
            test.is_false(ok)
            test.not_nil(err)
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
