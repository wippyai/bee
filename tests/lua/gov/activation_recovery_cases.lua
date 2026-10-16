-- MIT. Focused activation owner test cases.
local test = require("test")
local artifact = require("artifact")
local preflight = require("preflight")
local plan_store = require("plan_store")
local activation_store = require("activation_store")
local owner = require("activation_owner")
local support = require("support")
local SHA = support.SHA
local SHA_B = support.SHA_B
local expect_code = support.expect_code
local ok = support.ok
local migration_effect = support.migration_effect
local selected_plan = support.selected_plan
local shifting_resolver = support.shifting_resolver
local resolver = support.resolver
local approvals = support.approvals
local lossy_approvals = support.lossy_approvals
local function recovery_tests()
    test.describe("Destination activation recovery", function()
        test.it("reconciles lost consume and apply replies without following a newer plan", function()
            local plans, plan_error = plan_store.open("bee:db", "node-owner", "workspace-crash")
            if not plans then error(tostring(plan_error)) end
            local activations, activation_error = activation_store.open("bee:db", "node-owner", "workspace-crash")
            if not activations then error(tostring(activation_error)) end
            local entry = {id = "demo:run", kind = "function.lua", data = {source = "return 'v1'"}}
            local exact = assert(artifact.create({entry}))
            selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
            local applied = false
            local first_apply = true
            local fail_restore = false
            local config: owner.Config = {plans = plans, activations = activations, resolver = resolver(entry),
                approvals = lossy_approvals(), actor_id = "host-a", consumer_id = "destination-host",
                overlay_owner = "bee.gov:test-overlay", approval_policy = "local-install", migrations = migration_effect(),
                matches = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): (boolean?, string?, boolean?) return applied, nil end,
                apply = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): ({[string]: unknown}?, string?, boolean?)
                    if fail_restore then return nil, "overlay restore failed" end
                    applied = true
                    if first_apply then first_apply = false; return nil, "overlay reply was lost" end
                    return {changed = false}, nil
                end}
            ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                version = "v1", intent_id = "intent-crash", receipt_key = "activation-crash"}))
            test.eq(ok(owner.step(config, "intent-crash", "activation-crash")).phase, "consuming")
            expect_code(owner.step(config, "intent-crash", "activation-crash"), "UNAVAILABLE")
            local v2 = assert(artifact.create({{id = "demo:run", kind = "function.lua", data = {source = "return 'v2'"}}}))
            selected_plan(plans, "v2", {bytes = v2.bytes, digest = v2.digest})
            test.eq(ok(owner.step(config, "intent-crash", "activation-crash")).phase, "authorized")
            test.eq(ok(owner.recover(config, "activation-crash")).phase, "applying")
            local uncertain = owner.recover(config, "activation-crash")
            expect_code(uncertain, "UNCERTAIN")
            local settled = ok(owner.recover(config, "activation-crash"))
            test.eq(settled.outcome, "applied")
            test.eq(settled.version, "v1")
            applied = false
            local restored = ok(owner.recover(config, "activation-crash"))
            test.is_true(restored.recovered == true)
            test.is_true(applied)
            applied, fail_restore = false, true
            expect_code(owner.recover(config, "activation-crash"), "UNCERTAIN")
            fail_restore = false
            local recovered_again = ok(owner.recover(config, "activation-crash"))
            test.eq(recovered_again.outcome, "applied")
            test.is_true(applied)
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)

        test.it("settles an in-flight effect before authorizing v2 and fences historical v1 recovery", function()
            local plans, plan_error = plan_store.open("bee:db", "node-owner", "workspace-version-fence")
            if not plans then error(tostring(plan_error)) end
            local activations, activation_error = activation_store.open("bee:db", "node-owner", "workspace-version-fence")
            if not activations then error(tostring(activation_error)) end
            local entry = {id = "demo:run", kind = "function.lua", data = {source = "return 'stable'"}}
            local exact = assert(artifact.create({entry}))
            local applied = false
            local apply_count = 0
            local config: owner.Config = {plans = plans, activations = activations, resolver = resolver(entry),
                approvals = approvals(), actor_id = "host-a", consumer_id = "destination-host",
                overlay_owner = "bee.gov:test-overlay", approval_policy = "local-install", migrations = migration_effect(),
                matches = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): (boolean?, string?, boolean?) return applied, nil end,
                apply = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): ({[string]: unknown}?, string?, boolean?)
                    applied, apply_count = true, apply_count + 1
                    return {changed = true}, nil
                end}

            selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
            ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                version = "v1", intent_id = "intent-fenced-v1", receipt_key = "fenced-v1"}))
            test.eq(ok(owner.step(config, "intent-fenced-v1", "fenced-v1")).phase, "consuming")
            test.eq(ok(owner.step(config, "intent-fenced-v1", "fenced-v1")).phase, "authorized")
            test.eq(ok(owner.step(config, "intent-fenced-v1", "fenced-v1")).phase, "applying")

            selected_plan(plans, "v2", {bytes = exact.bytes, digest = exact.digest})
            ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                version = "v2", intent_id = "intent-fenced-v2", receipt_key = "fenced-v2"}))
            test.eq(ok(owner.step(config, "intent-fenced-v2", "fenced-v2")).phase, "consuming")
            local overlap = owner.step(config, "intent-fenced-v2", "fenced-v2")
            expect_code(overlap, "CONFLICT")
            test.eq(ok(owner.desired(config)).intent_id, "intent-fenced-v1")

            test.eq(ok(owner.step(config, "intent-fenced-v1", "fenced-v1")).outcome, "applied")
            test.eq(apply_count, 1)
            applied = false
            test.eq(ok(owner.step(config, "intent-fenced-v2", "fenced-v2")).phase, "authorized")
            test.eq(ok(owner.step(config, "intent-fenced-v2", "fenced-v2")).phase, "applying")
            test.eq(ok(owner.step(config, "intent-fenced-v2", "fenced-v2")).outcome, "applied")
            test.eq(apply_count, 2)

            applied = false
            local historical = owner.step(config, "intent-fenced-v1", "fenced-v1")
            expect_code(historical, "CONFLICT")
            test.is_false(applied)
            test.eq(apply_count, 2)
            test.eq(ok(owner.desired(config)).intent_id, "intent-fenced-v2")
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)

        test.it("refuses an authorized apply when the composed base changed under review", function()
            local plans, plan_error = plan_store.open("bee:db", "node-owner", "workspace-composed-refusal")
            if not plans then error(tostring(plan_error)) end
            local activations, activation_error = activation_store.open("bee:db", "node-owner", "workspace-composed-refusal")
            if not activations then error(tostring(activation_error)) end
            local entry = {id = "demo:run", kind = "function.lua", data = {source = "return 'v1'"}}
            local exact = assert(artifact.create({entry}))
            selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
            local world: {revision: integer, digest: string} = {revision = 4, digest = SHA}
            local applied = false
            local apply_count = 0
            local config: owner.Config = {plans = plans, activations = activations,
                resolver = shifting_resolver(entry, world),
                approvals = approvals(), actor_id = "host-a", consumer_id = "destination-host",
                overlay_owner = "bee.gov:test-overlay", approval_policy = "local-install", migrations = migration_effect(),
                matches = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): (boolean?, string?, boolean?) return applied, nil end,
                apply = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): ({[string]: unknown}?, string?, boolean?)
                    applied, apply_count = true, apply_count + 1
                    return {changed = true}, nil
                end}
            local prepared = owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                version = "v1", intent_id = "intent-composed", receipt_key = "composed-v1"})
            test.eq(ok(prepared).phase, "approval_bound")
            test.eq(ok(owner.step(config, "intent-composed", "composed-v1")).phase, "consuming")
            test.eq(ok(owner.step(config, "intent-composed", "composed-v1")).phase, "authorized")
            world.revision, world.digest = 5, SHA_B
            local refused = owner.step(config, "intent-composed", "composed-v1")
            expect_code(refused, "CONFLICT")
            test.is_true(tostring(refused.message):find("composed registry base", 1, true) ~= nil)
            test.is_false(applied)
            test.eq(apply_count, 0)
            world.revision, world.digest = 4, SHA
            test.eq(ok(owner.step(config, "intent-composed", "composed-v1")).phase, "applying")
            test.eq(ok(owner.step(config, "intent-composed", "composed-v1")).outcome, "applied")
            test.eq(apply_count, 1)
            local again = ok(owner.step(config, "intent-composed", "composed-v1"))
            test.eq(again.outcome, "applied")
            test.eq(apply_count, 1)
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)

        test.it("refuses success when the approved overlay effect cannot be observed", function()
            local plans = assert(plan_store.open("bee:db", "node-owner", "workspace-unobserved-effect"))
            local activations = assert(activation_store.open("bee:db", "node-owner", "workspace-unobserved-effect"))
            local entry = {id = "demo:run", kind = "function.lua", data = {source = "return 'v1'"}}
            local exact = assert(artifact.create({entry}))
            selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
            local applications = 0
            local observations = 0
            local config: owner.Config = {plans = plans, activations = activations, resolver = resolver(entry),
                approvals = approvals(), actor_id = "host-a", consumer_id = "destination-host",
                overlay_owner = "bee.gov:test-overlay", approval_policy = "local-install", migrations = migration_effect(),
                matches = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): (boolean?, string?, boolean?)
                    observations = observations + 1
                    return false, nil
                end,
                apply = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): ({[string]: unknown}?, string?, boolean?)
                    applications = applications + 1
                    return {changed = true}, nil
                end}
            ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a", version = "v1",
                intent_id = "intent-unobserved", receipt_key = "unobserved"}))
            local result = owner.advance(config, "intent-unobserved", "unobserved")
            expect_code(result, "UNCERTAIN")
            test.eq(applications, 1)
            test.eq(observations, 2)
            test.eq(ok(activation_store.get(activations, "intent-unobserved")).outcome, "uncertain")
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)

        test.it("leaves an apply uncertain when the base digest changes without advancing its revision", function()
            local plans, plan_error = plan_store.open("bee:db", "node-owner", "workspace-composed-apply")
            if not plans then error(tostring(plan_error)) end
            local activations, activation_error = activation_store.open("bee:db", "node-owner", "workspace-composed-apply")
            if not activations then error(tostring(activation_error)) end
            local entry = {id = "demo:run", kind = "function.lua", data = {source = "return 'v1'"}}
            local exact = assert(artifact.create({entry}))
            selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
            local world: {revision: integer, digest: string} = {revision = 4, digest = SHA}
            local applied = false
            local apply_count = 0
            local config: owner.Config = {plans = plans, activations = activations,
                resolver = shifting_resolver(entry, world),
                approvals = approvals(), actor_id = "host-a", consumer_id = "destination-host",
                overlay_owner = "bee.gov:test-overlay", approval_policy = "local-install", migrations = migration_effect(),
                matches = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): (boolean?, string?, boolean?) return applied, nil end,
                apply = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): ({[string]: unknown}?, string?, boolean?)
                    applied, apply_count = true, apply_count + 1
                    world.digest = SHA_B
                    return {changed = true}, nil
                end}
            ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                version = "v1", intent_id = "intent-composed-apply", receipt_key = "composed-apply-v1"}))
            test.eq(ok(owner.step(config, "intent-composed-apply", "composed-apply-v1")).phase, "consuming")
            test.eq(ok(owner.step(config, "intent-composed-apply", "composed-apply-v1")).phase, "authorized")
            test.eq(ok(owner.step(config, "intent-composed-apply", "composed-apply-v1")).phase, "applying")
            local outcome = owner.step(config, "intent-composed-apply", "composed-apply-v1")
            expect_code(outcome, "UNCERTAIN")
            test.is_true(tostring(outcome.message):find("composed registry base", 1, true) ~= nil)
            test.is_true(applied)
            test.eq(apply_count, 1)
            local later = owner.recover(config, "composed-apply-v1")
            expect_code(later, "CONFLICT")
            test.is_true(tostring(later.message):find("composed registry base", 1, true) ~= nil)
            test.eq(apply_count, 1)
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)

        test.it("reconciles an interrupted apply after a restart without duplicating it", function()
            local plans, plan_error = plan_store.open("bee:db", "node-owner", "workspace-composed-restart")
            if not plans then error(tostring(plan_error)) end
            local activations, activation_error = activation_store.open("bee:db", "node-owner", "workspace-composed-restart")
            if not activations then error(tostring(activation_error)) end
            local entry = {id = "demo:run", kind = "function.lua", data = {source = "return 'v1'"}}
            local exact = assert(artifact.create({entry}))
            selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
            local world: {revision: integer, digest: string} = {revision = 4, digest = SHA}
            local applied = false
            local apply_count = 0
            local function config_with(plan_handle: plan_store.Store, activation_handle: activation_store.Store): owner.Config
                return {plans = plan_handle, activations = activation_handle,
                    resolver = shifting_resolver(entry, world),
                    approvals = approvals(), actor_id = "host-a", consumer_id = "destination-host",
                    overlay_owner = "bee.gov:test-overlay", approval_policy = "local-install", migrations = migration_effect(),
                    matches = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): (boolean?, string?, boolean?) return applied, nil end,
                    apply = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): ({[string]: unknown}?, string?, boolean?)
                        applied, apply_count = true, apply_count + 1
                        return {changed = true}, nil
                    end}
            end
            ok(owner.prepare(config_with(plans, activations), {source_node = "source-a",
                source_workspace = "app-a", version = "v1", intent_id = "intent-composed-restart",
                receipt_key = "composed-restart-v1"}))
            test.eq(ok(owner.step(config_with(plans, activations), "intent-composed-restart", "composed-restart-v1")).phase, "consuming")
            test.eq(ok(owner.step(config_with(plans, activations), "intent-composed-restart", "composed-restart-v1")).phase, "authorized")
            test.eq(ok(owner.step(config_with(plans, activations), "intent-composed-restart", "composed-restart-v1")).phase, "applying")
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
            local reopened_plans, reopen_error = plan_store.open("bee:db", "node-owner", "workspace-composed-restart")
            if not reopened_plans then error(tostring(reopen_error)) end
            local reopened_activations, reopen_activation_error = activation_store.open("bee:db", "node-owner", "workspace-composed-restart")
            if not reopened_activations then error(tostring(reopen_activation_error)) end
            local settled = ok(owner.recover(config_with(reopened_plans, reopened_activations), "composed-restart-v1"))
            test.eq(settled.outcome, "applied")
            test.eq(apply_count, 1)
            assert(activation_store.close(reopened_activations))
            assert(plan_store.close(reopened_plans))
            local again_plans = assert(plan_store.open("bee:db", "node-owner", "workspace-composed-restart"))
            local again_activations = assert(activation_store.open("bee:db", "node-owner", "workspace-composed-restart"))
            local replayed = ok(owner.recover(config_with(again_plans, again_activations), "composed-restart-v1"))
            test.eq(replayed.outcome, "applied")
            test.eq(apply_count, 1)
            world.revision, world.digest = 5, SHA_B
            local preserved = ok(owner.recover(config_with(again_plans, again_activations), "composed-restart-v1"))
            test.eq(preserved.outcome, "applied")
            test.eq(apply_count, 1)
            applied = false
            local restored = ok(owner.recover(config_with(again_plans, again_activations), "composed-restart-v1"))
            test.eq(restored.outcome, "applied")
            test.is_true(restored.recovered == true)
            test.eq(apply_count, 2)
            applied = false
            world.blocked = true
            local blocked = owner.recover(config_with(again_plans, again_activations), "composed-restart-v1")
            expect_code(blocked, "CONFLICT")
            test.eq(apply_count, 2)
            assert(activation_store.close(again_activations))
            assert(plan_store.close(again_plans))
        end)

        test.it("refuses an overlay the host rules no longer admit and keeps an unobservable overlay unavailable", function()
            local plans = assert(plan_store.open("bee:db", "node-owner", "workspace-stale-rules"))
            local activations = assert(activation_store.open("bee:db", "node-owner", "workspace-stale-rules"))
            local entry = {id = "demo:run", kind = "function.lua", data = {source = "return 'v1'"}}
            local exact = assert(artifact.create({entry}))
            selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
            local applied = false
            local observation: string? = nil
            local applications = 0
            local config: owner.Config = {plans = plans, activations = activations, resolver = resolver(entry),
                approvals = approvals(), actor_id = "host-a", consumer_id = "destination-host",
                overlay_owner = "bee.gov:test-overlay", approval_policy = "local-install", migrations = migration_effect(),
                matches = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): (boolean?, string?, boolean?)
                    if observation == "refused" then return nil, "artifact breaks a host rule", true end
                    if observation == "unavailable" then return nil, "registry is unavailable" end
                    return applied, nil
                end,
                apply = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): ({[string]: unknown}?, string?, boolean?)
                    applied, applications = true, applications + 1
                    return {changed = true}, nil
                end}
            ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a", version = "v1",
                intent_id = "intent-stale-rules", receipt_key = "stale-rules"}))
            test.eq(ok(owner.step(config, "intent-stale-rules", "stale-rules")).phase, "consuming")
            test.eq(ok(owner.step(config, "intent-stale-rules", "stale-rules")).phase, "authorized")
            test.eq(ok(owner.step(config, "intent-stale-rules", "stale-rules")).phase, "applying")
            observation = "refused"
            local applying = owner.step(config, "intent-stale-rules", "stale-rules")
            expect_code(applying, "CONFLICT")
            test.eq(applying.message, "artifact breaks a host rule")
            observation = "unavailable"
            expect_code(owner.step(config, "intent-stale-rules", "stale-rules"), "UNAVAILABLE")
            observation = nil
            test.eq(ok(owner.step(config, "intent-stale-rules", "stale-rules")).outcome, "applied")
            test.eq(applications, 1)
            applied, observation = false, "refused"
            local restoring = owner.recover(config, "stale-rules")
            expect_code(restoring, "CONFLICT")
            test.eq(restoring.message, "artifact breaks a host rule")
            observation = "unavailable"
            expect_code(owner.recover(config, "stale-rules"), "UNAVAILABLE")
            test.eq(applications, 1)
            test.eq(ok(activation_store.get(activations, "intent-stale-rules")).outcome, "applied")
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)

        test.it("refuses an authorized overlay its resolution rejects and keeps a failed resolution blocked", function()
            local plans = assert(plan_store.open("bee:db", "node-owner", "workspace-stale-resolution"))
            local activations = assert(activation_store.open("bee:db", "node-owner", "workspace-stale-resolution"))
            local entry = {id = "demo:run", kind = "function.lua", data = {source = "return 'v1'"}}
            local exact = assert(artifact.create({entry}))
            selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
            local resolution: string? = nil
            local measured = resolver(entry)
            local applications = 0
            local config: owner.Config = {plans = plans, activations = activations,
                resolver = {resolve = function(_self: owner.Resolver, plan: unknown): (preflight.Candidate?, preflight.Context?, string?, boolean?)
                    if resolution == "refused" then return nil, nil, "artifact breaks a host rule", true end
                    if resolution == "failed" then return nil, nil, "registry snapshot is unavailable" end
                    return measured:resolve(plan)
                end},
                approvals = approvals(), actor_id = "host-a", consumer_id = "destination-host",
                overlay_owner = "bee.gov:test-overlay", approval_policy = "local-install", migrations = migration_effect(),
                matches = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): (boolean?, string?, boolean?) return false, nil end,
                apply = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): ({[string]: unknown}?, string?, boolean?)
                    applications = applications + 1
                    return {changed = true}, nil
                end}
            ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a", version = "v1",
                intent_id = "intent-stale-resolution", receipt_key = "stale-resolution"}))
            test.eq(ok(owner.step(config, "intent-stale-resolution", "stale-resolution")).phase, "consuming")
            test.eq(ok(owner.step(config, "intent-stale-resolution", "stale-resolution")).phase, "authorized")
            resolution = "refused"
            local refused = owner.recover(config, "stale-resolution")
            expect_code(refused, "CONFLICT")
            test.eq(refused.message, "artifact breaks a host rule")
            resolution = "failed"
            expect_code(owner.recover(config, "stale-resolution"), "BLOCKED")
            test.eq(applications, 0)
            test.eq(ok(activation_store.get(activations, "intent-stale-resolution")).phase, "authorized")
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)

    end)
end

return {define = recovery_tests}
