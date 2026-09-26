local test = require("test")
local transaction = require("transaction")
local headless_revert = require("headless_revert")

local OWNER = "bee.super_edit:0123456789abcdef0123456789abcdef.vendor.alpha.00000000-0000-7000-8000-000000000000"
local function define_tests()
    test.describe("headless governance revert", function()
        test.it("runs revert_activation under the fixed recovery actor", function()
            local seen_actor = ""
            local seen_request: {[string]: unknown}? = nil
            local activations = {
                applied = function(_: unknown, component: string): transaction.Result
                    test.eq(component, "vendor/app")
                    return transaction.success({migrations = {}}, false)
                end,
                revert_activation = function(_: unknown, actor: string, request: {[string]: unknown}): transaction.Result
                    seen_actor, seen_request = actor, request
                    return transaction.success({intent_id = "baseline"}, false)
                end,
            }
            local result = headless_revert.revert(activations, {}, OWNER,
                {overlay_owner = OWNER, component = "vendor/app", slot_revision = 7},
                {overlay_owner = OWNER, component = "vendor/app"}, "revert-1")
            test.is_true(result.ok)
            test.eq(seen_actor, "bee.gov.recovery")
            local request = seen_request :: {[string]: unknown}
            test.eq(request.operation, "revert_activation")
            test.eq(request.overlay_owner, OWNER)
            test.eq(request.expected_revision, 7)
            local compensation = request.compensation :: {[string]: unknown}
            test.is_true(#(compensation.bytes :: string) > 0)
            test.eq(#(compensation.digest :: string), 64)
        end)

        test.it("refuses migration facts without an applied compensation plan", function()
            local called = false
            local activations = {
                applied = function(_: unknown, _: string): transaction.Result
                    return transaction.success({migrations = {migration = {id = "vendor:001"}}}, false)
                end,
                revert_activation = function(_: unknown, _: string, _: {[string]: unknown}): transaction.Result
                    called = true
                    return transaction.success({}, false)
                end,
            }
            local result = headless_revert.revert(activations, {}, OWNER,
                {overlay_owner = OWNER, component = "vendor/app", slot_revision = 7},
                {overlay_owner = OWNER, component = "vendor/app"}, "revert-2")
            test.is_false(result.ok)
            test.eq(result.code, "BLOCKED")
            test.is_false(called)
        end)
    end)
end

return test.run_cases(define_tests)
