-- MIT. Focused activation owner test cases.
local test = require("test")
local bounds = require("bounds")
local artifact = require("artifact")
local plan_store = require("plan_store")
local activation_store = require("activation_store")
local owner = require("activation_owner")
local lease_store = require("lease_store")
local application_admission = require("application_admission")
local capability_grants = require("capability_grants")
local support = require("support")
local SHA = support.SHA
type ResolverWorld = support.ResolverWorld
local expect_code = support.expect_code
local ok = support.ok
local migration_effect = support.migration_effect
local selected_plan = support.selected_plan
local admission = support.admission
local installed_capability = support.installed_capability
local shifting_resolver = support.shifting_resolver
local resolver = support.resolver
local migration_resolver = support.migration_resolver
local approvals = support.approvals
local LEASE_NARROW = support.LEASE_NARROW
local widening_capability = support.widening_capability
local grant_lease = support.grant_lease
local function follow_tests()
    local follower = require("follow_source")
    local follow_store = require("follow_store")
    local delivery = require("delivery")
    test.describe("Following source activation", function()
        for _, scenario in ipairs({"equal", "shorthand", "widened", "lease", "migration", "restart", "uncertain", "superseded", "paused", "failed"}) do
            test.it("reconciles a " .. scenario .. " source update", function()
                local workspace = "workspace-follow-" .. scenario
                local plans = assert(plan_store.open("bee:db", "node-owner", workspace))
                local activations = assert(activation_store.open("bee:db", "node-owner", workspace))
                local entry: {[string]: unknown} = {id = "demo:run", kind = "function.lua", data = {source = "return true"}}
                if scenario == "migration" then
                    entry = {id = "demo:001", kind = "function.lua", meta = {type = "migration", target_db = "host:db", ordinal = 1},
                        data = {source = "return true", modules = {}}}
                end
                local exact = assert(artifact.create({entry}))
                local identity = {source_node = "source-a", source_workspace = "app-a", component = "demo/app"}
                local release = scenario == "shorthand" and "v2" or "1.0.1"
                local published = assert(delivery.create({schema_revision = delivery.SCHEMA, source_node = identity.source_node,
                    source_workspace = identity.source_workspace, component = identity.component, version = release,
                    artifact = {bytes = exact.bytes, digest = exact.digest}}))
                local descriptor = assert(delivery.descriptor(published))
                local review: capability_grants.Review? = nil
                if scenario == "widened" then
                    review = {added = {}, widened = {}, narrowed = {}, removed = {}, changed = {}, requires_approval = true,
                        revocation = {grants = {}, fenced_attempts = {}}, lines = {"widened authority"}, resolved = {"widened authority"}, delta = {"widened authority"}}
                end
                local world: ResolverWorld = {revision = 4, digest = SHA, capability = installed_capability(review),
                    application_admission = admission(exact.digest, SHA, nil, workspace), blocked = scenario == "failed"}
                local lease_handle: lease_store.Store? = nil
                if scenario == "lease" then
                    world.capability = widening_capability({LEASE_NARROW})
                    lease_handle = assert(lease_store.open("bee:db", "node-owner", workspace))
                    grant_lease(lease_handle, 2)
                end
                local requests, effects = 0, 0
                local working = scenario == "shorthand" and "v1" or "1.0.0"
                local interrupted = false
                local executor = {}
                function executor.call(self: owner.Executor, method: string, request: unknown): (unknown?, unknown?)
                    if method == "bee.approvals.binding:request" then requests = requests + 1 end
                    return approvals():call(method, request)
                end
                local function configuration(): owner.Config
                    return {plans = plans, activations = activations, resolver = scenario == "migration" and migration_resolver(entry, {}) or shifting_resolver(entry, world),
                        approvals = executor, actor_id = "host-a", consumer_id = "destination-host", overlay_owner = "bee.gov:test-overlay",
                        approval_policy = "local-install", migrations = migration_effect(), leases = lease_handle,
                        matches = function(_overlay: string, _entries: unknown, _admission: unknown?, intent: unknown): (boolean?, string?)
                            if scenario == "uncertain" and effects > 0 and not interrupted then
                                interrupted = true
                                return nil, "Effect observation is interrupted"
                            end
                            return working == (assert(bounds.object(intent))).version, nil
                        end,
                        apply = function(_overlay: string, _entries: unknown, _admission: unknown?, intent: unknown): ({[string]: unknown}?, string?, boolean?)
                            local release = (assert(bounds.object(intent))).version
                            assert(type(release) == "string")
                            working, effects = release, effects + 1
                            return {changed = true}, nil
                        end}
                end
                expect_code(follower.reconcile(configuration(), identity, descriptor, published.bytes, 1), "PAUSED")
                ok(follow_store.consent(activations, identity, "following", working, exact.digest))
                if scenario == "restart" or scenario == "paused" or scenario == "superseded" then
                    ok(follow_store.reserve(activations, identity, descriptor, 1))
                end
                if scenario == "restart" then
                    assert(activation_store.close(activations)); assert(plan_store.close(plans))
                    plans = assert(plan_store.open("bee:db", "node-owner", workspace))
                    activations = assert(activation_store.open("bee:db", "node-owner", workspace))
                elseif scenario == "superseded" then
                    working = "1.0.2"
                    selected_plan(plans, working, {bytes = exact.bytes, digest = exact.digest})
                    ok(owner.prepare(configuration(), {source_node = identity.source_node,
                        source_workspace = identity.source_workspace, version = working,
                        intent_id = "manual-current", receipt_key = "manual-current"}))
                    test.eq(ok(owner.advance(configuration(), "manual-current", "manual-current")).outcome, "applied")
                elseif scenario == "paused" then
                    ok(follow_store.consent(activations, identity, "paused", "1.0.0", exact.digest))
                end
                local result = follower.reconcile(configuration(), identity, descriptor, published.bytes, 1)
                if scenario == "paused" then
                    expect_code(result, "PAUSED")
                    test.eq(effects, 0); test.eq(working, "1.0.0")
                elseif scenario == "superseded" then
                    expect_code(result, "ROLLBACK")
                    test.eq(working, "1.0.2"); test.eq(effects, 0); test.eq(requests, 0)
                elseif scenario == "uncertain" then
                    expect_code(result, "UNCERTAIN")
                    test.eq(working, "1.0.1"); test.eq(effects, 1)
                    test.not_nil(ok(follow_store.get(activations, identity)).pending)
                    assert(activation_store.close(activations)); assert(plan_store.close(plans))
                    plans = assert(plan_store.open("bee:db", "node-owner", workspace))
                    activations = assert(activation_store.open("bee:db", "node-owner", workspace))
                    test.eq(ok(follower.reconcile(configuration(), identity, descriptor, published.bytes, 1)).outcome, "applied")
                    test.eq(effects, 1); test.eq(requests, 0)
                elseif scenario == "failed" then
                    expect_code(result, "BLOCKED")
                    test.eq(effects, 0); test.eq(working, "1.0.0")
                    test.eq(ok(follow_store.get(activations, identity)).last_outcome, "failed")
                elseif scenario == "widened" or scenario == "lease" or scenario == "migration" then
                    test.eq(ok(result).phase, "approval_bound")
                    test.eq(ok(follow_store.get(activations, identity)).last_outcome, "needs_you")
                    test.eq(working, "1.0.0"); test.eq(effects, 0); test.eq(requests, 1)
                    test.eq(ok(follower.reconcile(configuration(), identity, descriptor, published.bytes, 1)).phase, "approval_bound")
                    test.eq(requests, 1)
                else
                    test.eq(ok(result).outcome, "applied")
                    test.eq(working, release); test.eq(effects, 1); test.eq(requests, 0)
                    test.eq(ok(follow_store.get(activations, identity)).last_outcome, "applied")
                    ok(follower.reconcile(configuration(), identity, descriptor, published.bytes, 1))
                    test.eq(effects, 1); test.eq(requests, 0)
                end
                if lease_handle then
                    test.eq(ok(lease_store.get(lease_handle, "lease-1")).applies_used, 0)
                    assert(lease_store.close(lease_handle))
                end
                assert(activation_store.close(activations)); assert(plan_store.close(plans))
            end)
        end
    end)
end

return {define = follow_tests}
