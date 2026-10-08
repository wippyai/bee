-- MIT. Destination-local following consent and immutable progress.
local test = require("test")
local bounds = require("bounds")
local activations = require("activation_store")
local store = require("follow_store")
local delivery = require("delivery")
local artifact = require("artifact")

local identity = {source_node = "source-a", source_workspace = "shared-app", component = "shared/app"}
local function descriptor(version: string, source: string?): delivery.Descriptor
    local exact = assert(artifact.create({{id = "shared:run", kind = "function.lua", data = {source = source or "return true"}}}))
    local item = assert(delivery.create({schema_revision = delivery.SCHEMA, source_node = identity.source_node,
        source_workspace = identity.source_workspace, component = identity.component, version = version, artifact = {bytes = exact.bytes, digest = exact.digest}}))
    return assert(delivery.descriptor(item))
end
local function value(result: {[string]: unknown}): {[string]: unknown}
    if result.ok ~= true then error(tostring(result.code) .. ": " .. tostring(result.message)) end
    return assert(bounds.object(result.value))
end
local function define_tests()
    test.describe("Following source ledger", function()
        test.it("defaults off and persists consent, cursor and an interrupted reservation", function()
            local handle = assert(activations.open("bee:db", "node-follow", "workspace-follow"))
            local baseline = descriptor("1.0.0")
            test.eq(value(store.get(handle, identity)).mode, "off")
            test.eq(store.reserve(handle, identity, descriptor("1.0.1")).code, "PAUSED")
            value(store.consent(handle, identity, "following", baseline.version_id, baseline.manifest.artifact_digest))
            local pending = value(store.reserve(handle, identity, descriptor("1.0.1")))
            test.eq(pending.version, "1.0.1")
            test.eq(pending.last_outcome, "staging")
            test.not_nil(pending.pending)
            assert(activations.close(handle))
            handle = assert(activations.open("bee:db", "node-follow", "workspace-follow"))
            local restored = value(store.get(handle, identity))
            test.eq(restored.intent_id, pending.intent_id)
            test.eq(restored.version, "1.0.1")
            test.eq(store.reserve(handle, identity, descriptor("1.0.2")).code, "BUSY")
            value(store.finish(handle, identity, pending.intent_id, "applied", "Applied 1.0.1"))
            test.eq(value(store.get(handle, identity)).last_outcome, "applied")
            test.is_nil(value(store.get(handle, identity)).pending)
            assert(activations.close(handle))
        end)
        test.it("rejects rollback and equivocation and stops while paused or pinned", function()
            local handle = assert(activations.open("bee:db", "node-follow", "workspace-follow-refusal"))
            local baseline = descriptor("2.0.0")
            value(store.consent(handle, identity, "following", baseline.version_id, baseline.manifest.artifact_digest))
            test.eq(store.reserve(handle, identity, descriptor("1.9.9")).code, "ROLLBACK")
            test.eq(store.reserve(handle, identity, descriptor("2.0.0", "return false")).code, "EQUIVOCATION")
            test.is_true(store.reserve(handle, identity, baseline).replayed == true)
            for _, mode in ipairs({"paused", "pinned"}) do
                value(store.consent(handle, identity, mode, baseline.version_id, baseline.manifest.artifact_digest))
                test.eq(store.reserve(handle, identity, descriptor("2.0.1")).code, "PAUSED")
            end
            value(store.consent(handle, identity, "following", "1.0.0", baseline.manifest.artifact_digest))
            test.eq(value(store.get(handle, identity)).version, "2.0.0")
            test.eq(value(store.get(handle, {source_node = "other", source_workspace = identity.source_workspace,
                component = identity.component})).mode, "off")
            assert(activations.close(handle))
        end)
    end)
end
return test.run_cases(define_tests)
