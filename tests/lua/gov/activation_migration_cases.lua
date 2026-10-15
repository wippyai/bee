-- MIT. Focused activation owner test cases.
local test = require("test")
local hash = require("hash")
local canonical = require("canonical")
local artifact = require("artifact")
local plan_store = require("plan_store")
local activation_store = require("activation_store")
local owner = require("activation_owner")
local migration_work = require("migration_work")

local support = require("support")
local SHA = support.SHA
local SHA_B = support.SHA_B
local expect_code = support.expect_code
local ok = support.ok
local selected_plan = support.selected_plan
local resolver = support.resolver
local migration_resolver = support.migration_resolver
local approvals = support.approvals
local function migration_tests()
    test.describe("Destination activation migration", function()
        test.it("completes captured migrations before exposing the application overlay", function()
            local plans = assert(plan_store.open("bee:db", "node-owner", "workspace-migration-owner"))
            local activations = assert(activation_store.open("bee:db", "node-owner", "workspace-migration-owner"))
            local entry = {id = "demo:001", kind = "function.lua",
                meta = {type = "migration", target_db = "host:db", ordinal = 1},
                data = {source = "return true", modules = {}}}
            local exact = assert(artifact.create({entry}))
            selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
            local state: {[string]: unknown} = {staged = false, executed = false, applied = false}
            local effect = {
                matches = function(_owner: string, _work: migration_work.Work, _intent: unknown): (boolean?, string?) return state.staged == true, nil end,
                prepare = function(_owner: string, _work: migration_work.Work, _intent: unknown): ({[string]: unknown}?, string?)
                    state.staged = true; return {changed = true}, nil
                end,
                clear = function(_owner: string): ({[string]: unknown}?, string?)
                    state.staged = false; return {changed = true}, nil
                end,
                cleared = function(_owner: string): (boolean?, string?) return state.staged ~= true, nil end,
                execute = function(_work: migration_work.Work, _intent: unknown): ({bytes: string, digest: string}?, boolean, string?)
                    state.executed = true
                    local bytes = assert(canonical.encode({schema_revision = "bee.governance-migration-receipt@1",
                        rows = {{id = "demo:001", target_db = "host:db", module = "demo/app", status = "applied"}}}))
                    return {bytes = bytes, digest = assert(hash.sha256(bytes))}, true, nil
                end,
            }
            local config: owner.Config = {plans = plans, activations = activations,
                resolver = migration_resolver(entry, state), approvals = approvals(), actor_id = "host-a",
                consumer_id = "destination-host", overlay_owner = "bee.gov:migration-overlay",
                approval_policy = "local-install", migrations = effect,
                matches = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): (boolean?, string?) return state.applied == true, nil end,
                apply = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): ({[string]: unknown}?, string?, boolean?)
                    test.is_true(state.executed == true)
                    test.is_true(state.staged ~= true)
                    state.applied = true
                    return {changed = true}, nil
                end}
            ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a", version = "v1",
                intent_id = "intent-migration", receipt_key = "migration"}))
            test.eq(ok(owner.step(config, "intent-migration", "migration")).phase, "consuming")
            test.eq(ok(owner.step(config, "intent-migration", "migration")).phase, "authorized")
            test.eq(ok(owner.step(config, "intent-migration", "migration")).phase, "applying")
            state.policy_digest = SHA_B
            local changed_policy = owner.step(config, "intent-migration", "migration")
            expect_code(changed_policy, "CONFLICT")
            test.is_true(tostring(changed_policy.message):find("database policy", 1, true) ~= nil)
            test.is_false(state.executed == true)
            state.policy_digest = SHA
            local migrated = ok(owner.step(config, "intent-migration", "migration"))
            test.is_true(migrated.migrations_completed == true)
            test.is_false(state.applied == true)
            test.is_true(ok(owner.step(config, "intent-migration", "migration")).recovered == true)
            test.is_false(state.staged == true)
            local settled = ok(owner.step(config, "intent-migration", "migration"))
            test.eq(settled.outcome, "applied")
            test.is_true(state.applied == true)
            state.applied, state.policy_digest = false, SHA_B
            local restored = ok(owner.recover(config, "migration-upgraded-host"))
            test.is_true(restored.recovered == true)
            test.is_true(state.applied == true)
            state.applied, state.executed = false, false
            local pending = owner.recover(config, "migration-missing-ledger")
            expect_code(pending, "CONFLICT")
            test.is_false(state.applied == true)
            test.is_false(state.executed == true)
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)
    end)
end

return {define = migration_tests}
