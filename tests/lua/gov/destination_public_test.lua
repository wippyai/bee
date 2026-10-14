-- MIT. The public facade reaches only destination-owned local state.
local funcs = require("funcs")
local test = require("test")
local principals = require("principals")
local bounds = require("bounds")
local registry = require("registry")
local caller = require("caller")

local function call(request: unknown): {[string]: unknown}
    local result, err = funcs.call("bee.gov.binding:destination_call", request)
    if type(result) ~= "table" then error(tostring(err or "destination call returned no result")) end
    return assert(bounds.object(result))
end

local function define_tests()
    test.describe("destination delivery public facade", function()
        test.it("lists one authorized local workspace without selecting or activating", function()
            local result = call({operation = "list", workspace_id = "public-delivery-test"})
            test.is_true(result.ok == true)
            local value = assert(bounds.object(result.value))
            test.eq(value.workspace_id, "public-delivery-test")
            test.eq(#(principals.items(value.plans)), 0)
        end)

        test.it("lists the activations of one authorized local workspace", function()
            local result = call({operation = "activations", workspace_id = "public-delivery-test"})
            test.is_true(result.ok == true)
            local value = assert(bounds.object(result.value))
            test.eq(value.workspace_id, "public-delivery-test")
            test.eq(#(principals.items(value.activations)), 0)
        end)

        test.it("preserves a committed uncertainty fault through the application decoder", function()
            local original = assert(registry.get("bee.gov.binding:destination_backend_call"))
            local data = assert(bounds.object(original.data))
            local replacement: {[string]: unknown} = {}
            for field, value in pairs(data) do replacement[field] = value end
            replacement.source = [[return {handle = function(_request)
                return {ok = false, replayed = false, code = "UNCERTAIN",
                    message = "not allowed to shadow durable entry: bee.settings.app:view",
                    value = {phase = "settled", outcome = "uncertain", revision = 6}, commit = true}
            end}]]
            replacement.method = "handle"
            local changes = registry.snapshot():changes()
            assert(changes:update({id = original.id, kind = original.kind, meta = original.meta, data = replacement}))
            assert(changes:apply())
            local raw, err = funcs.call("bee.gov.binding:destination_call", {
                operation = "step", workspace_id = "public-delivery-test"})
            local restore = registry.snapshot():changes()
            assert(restore:update(original)); assert(restore:apply())
            test.is_nil(err, tostring(err))
            local result = caller.decode(raw)
            test.not_nil(result, "destination fault rejected by application decoder")
            assert(result)
            test.is_false(result.ok)
            local fault = assert(result.error)
            test.eq(fault.code, "UNCERTAIN")
            test.eq(fault.message, "not allowed to shadow durable entry: bee.settings.app:view")
        end)
        test.it("fails closed when no host activation profile exists", function()
            local result = call({operation = "prepare", workspace_id = "public-delivery-test",
                source_node = "source-node", source_workspace = "vendor/app", version = "1.0.0",
                intent_id = "intent-1", receipt_key = "prepare-1"})
            test.is_false(result.ok == true)
            -- The facade names the owner's fault the way an application reads it.
            local fault = assert(bounds.object(result.error))
            test.eq(fault.code, "BLOCKED")
            test.is_true((fault.message):find("activation profile", 1, true) ~= nil)
        end)
    end)
end

return test.run_cases(define_tests)
