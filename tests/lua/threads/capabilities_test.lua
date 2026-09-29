-- MIT. The capabilities report describes this implementation exactly: its
-- contracts match the registry definitions, its limits are the constants
-- the operations enforce, and the interim delivery limits are stated.
local test = require("test")
local funcs = require("funcs")
local registry = require("registry")
local security = require("security")
local capabilities = require("capabilities")
local bounds = require("bounds")
local migrations = require("migrations")
local waits = require("waits")
local function names(id: string): {string}
    local entry, err = registry.get(id)
    if err or not entry then error("contract " .. id .. ": " .. tostring(err)) end
    local data = entry.data :: {[string]: unknown}
    local result: {string} = {}
    for index, method in ipairs(data.methods :: {{[string]: unknown}}) do
        result[index] = method.name :: string
    end
    return result
end
local function same(left: {string}, right: {string})
    test.eq(#left, #right)
    for index, item in ipairs(left) do test.eq(item, right[index]) end
end
local function define_tests()
    test.describe("Threads capabilities", function()
        test.it("lists every bound contract with the methods the registry defines", function()
            local described = capabilities.describe()
            test.eq(described.revision, "bee.threads.capabilities@1")
            test.eq(#described.contracts, 7)
            for _, declared in ipairs(described.contracts) do
                same(declared.methods, names(declared.contract))
            end
        end)
        test.it("reports schema revisions, carried migrations and enforced limits", function()
            local described = capabilities.describe()
            test.eq(described.record_schema, bounds.SCHEMA_REVISION)
            test.eq(described.recap_schema, "bee.recap@1")
            same(described.record_kinds, bounds.KINDS)
            same(described.record_sources, bounds.SOURCES)
            same(described.outcomes, bounds.OUTCOMES)
            test.eq(#described.migrations, #migrations.all())
            test.eq(described.migrations[4].name, "delivery")
            test.is_true(described.migrations[4].rebuild)
            test.is_false(described.migrations[5].rebuild)
            test.eq(described.limits.max_thread_records, bounds.MAX_THREAD_RECORDS)
            test.eq(described.limits.max_thread_obligations, bounds.MAX_THREAD_OBLIGATIONS)
            test.eq(described.limits.max_page_records, bounds.MAX_PAGE_RECORDS)
            test.eq(described.limits.claim_ttl_seconds, 300)
            test.eq(described.limits.max_wait_ms, waits.MAX_WAIT_MS)
            test.eq(described.limits.max_waiters_per_thread, waits.MAX_WAITERS_PER_THREAD)
            test.eq(described.limits.max_waiters, waits.MAX_WAITERS)
            test.eq(described.limits.max_thread_subscriptions, 128)
            test.eq(described.limits.max_pending_notices_per_thread, 64)
            test.eq(described.delivery.transport_budget.ceiling_ms, waits.MAX_WAIT_MS)
            test.is_true(described.delivery.transport_budget.caller_may_shorten)
            test.is_false(described.delivery.transport_budget.caller_may_extend)
            test.is_true(described.delivery.self_service_only)
            test.is_false(described.delivery.delegated_replies)
            test.is_false(described.delivery.cross_node_send)
            test.is_false(described.delivery.telemetry_subscribe)
            test.eq(described.delivery.outstanding_pages_per_subscription, 1)
            same(described.delivery.channels, {"wait", "push", "mcp", "native"})
            local kinds = described.record_kinds
            kinds[1] = "changed"
            test.eq(bounds.KINDS[1], "observation")
        end)
        test.it("answers the same report to any caller without storage access", function()
            local caller = funcs.new():with_actor(security.new_actor("bee.test.nobody")):with_scope(security.new_scope({"bee.threads:client_test_policy"}))
            local reply, err = caller:call("bee.threads:capabilities", {})
            if err then error(tostring(err)) end
            local described = reply :: capabilities.Report
            test.eq(described.revision, "bee.threads.capabilities@1")
            test.eq(described.limits.max_thread_records, bounds.MAX_THREAD_RECORDS)
            test.eq(#described.contracts, 7)
        end)
    end)
end
return test.run_cases(define_tests)
