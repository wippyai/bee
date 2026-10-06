local test = require("test")
local bounds = require("bounds")
local transaction = require("transaction")
local headless_revert = require("headless_revert")
local activation_store = require("activation_store")

local OWNER = "bee.super_edit:0123456789abcdef0123456789abcdef.vendor.alpha.00000000-0000-7000-8000-000000000000"
local function define_tests()
    test.describe("headless governance revert", function()
        test.it("runs revert_activation under the fixed recovery actor", function()
            local seen_actor = ""
            local seen_request: {[string]: unknown}? = nil
            local activations: headless_revert.Activations = {
                applied = function(_: activation_store.Store, component: string): transaction.Result
                    test.eq(component, "vendor/app")
                    return transaction.success({migrations = {}}, false)
                end,
                revert_activation = function(_: activation_store.Store, actor: string, request: activation_store.Request): transaction.Result
                    seen_actor, seen_request = actor, request
                    return transaction.success({intent_id = "baseline"}, false)
                end,
            }
            local store = assert(activation_store.open("bee:db", "node-headless", "headless-revert-success"))
            local result = headless_revert.revert(activations, store, OWNER,
                {overlay_owner = OWNER, component = "vendor/app", slot_revision = 7},
                {overlay_owner = OWNER, component = "vendor/app"}, "revert-1")
            assert(activation_store.close(store))
            test.is_true(result.ok)
            test.eq(seen_actor, "bee.gov.recovery")
            local request = assert(bounds.object(seen_request))
            test.eq(request.operation, "revert_activation")
            test.eq(request.overlay_owner, OWNER)
            test.eq(request.expected_revision, 7)
            local compensation = assert(bounds.object(request.compensation))
            test.is_true(#(compensation.bytes) > 0)
            test.eq(#(compensation.digest), 64)
        end)

        test.it("records the revert under the person who asked for it", function()
            local seen_actor = ""
            local activations: headless_revert.Activations = {
                applied = function(_: activation_store.Store, _: string): transaction.Result
                    return transaction.success({migrations = {}}, false)
                end,
                revert_activation = function(_: activation_store.Store, actor: string, _: activation_store.Request): transaction.Result
                    seen_actor = actor
                    return transaction.success({intent_id = "baseline"}, false)
                end,
            }
            local store = assert(activation_store.open("bee:db", "node-headless", "headless-revert-person"))
            local current = {overlay_owner = OWNER, component = "vendor/app", slot_revision = 7}
            local baseline = {overlay_owner = OWNER, component = "vendor/app"}
            test.is_true(headless_revert.revert(activations, store, OWNER, current, baseline, "revert-person", "person-1").ok)
            test.eq(seen_actor, "person-1")
            test.eq(headless_revert.revert(activations, store, OWNER, current, baseline, "revert-person-2", "bad actor\n").code, "INVALID")
            assert(activation_store.close(store))
        end)

        test.it("refuses migration facts without an applied compensation plan", function()
            local called = false
            local activations: headless_revert.Activations = {
                applied = function(_: activation_store.Store, _: string): transaction.Result
                    return transaction.success({migrations = {migration = {id = "vendor:001"}}}, false)
                end,
                revert_activation = function(_: activation_store.Store, _: string, _: activation_store.Request): transaction.Result
                    called = true
                    return transaction.success({}, false)
                end,
            }
            local store = assert(activation_store.open("bee:db", "node-headless", "headless-revert-blocked"))
            local result = headless_revert.revert(activations, store, OWNER,
                {overlay_owner = OWNER, component = "vendor/app", slot_revision = 7},
                {overlay_owner = OWNER, component = "vendor/app"}, "revert-2")
            assert(activation_store.close(store))
            test.is_false(result.ok)
            test.eq(result.code, "BLOCKED")
            test.is_false(called)
        end)
    end)
end

return test.run_cases(define_tests)
