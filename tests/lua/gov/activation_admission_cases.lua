-- MIT. Focused activation owner test cases.
local test = require("test")
local principals = require("principals")
local bounds = require("bounds")
local artifact = require("artifact")
local plan_store = require("plan_store")
local activation_store = require("activation_store")
local owner = require("activation_owner")
local preflight = require("preflight")
local application_admission = require("application_admission")
local capability_grants = require("capability_grants")
local capability_model = require("capability_model")
local support = require("support")
local SHA = support.SHA
local SHA_B = support.SHA_B
type ResolverWorld = support.ResolverWorld
local blob = support.blob
local expect_code = support.expect_code
local ok = support.ok
local migration_effect = support.migration_effect
local selected_plan = support.selected_plan
local admission = support.admission
local shifting_resolver = support.shifting_resolver
local resolver = support.resolver
local approvals = support.approvals
local function admission_tests()
    test.describe("Destination activation admission", function()
        test.it("establishes only the approved desired version and ignores a newer selection", function()
            local plans, plan_error = plan_store.open("bee:db", "node-owner", "workspace-owner")
            if not plans then error(tostring(plan_error)) end
            local activations, activation_error = activation_store.open("bee:db", "node-owner", "workspace-owner")
            if not activations then error(tostring(activation_error)) end
            local entry = {id = "demo:run", kind = "function.lua", data = {source = "return 'v1'"}}
            local exact = assert(artifact.create({entry}))
            selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
            local applied = false
            local config: owner.Config = {plans = plans, activations = activations, resolver = resolver(entry),
                approvals = approvals(), actor_id = "host-a", consumer_id = "destination-host",
                overlay_owner = "bee.gov:test-overlay", approval_policy = "local-install", migrations = migration_effect(),
                matches = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): (boolean?, string?, boolean?) return applied, nil end,
                apply = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): ({[string]: unknown}?, string?, boolean?)
                    applied = true
                    return {changed = true}, nil
                end}
            local prepared = owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                version = "v1", intent_id = "intent-v1", receipt_key = "activation-v1"})
            test.eq(ok(prepared).phase, "approval_bound")
            test.eq(ok(owner.step(config, "intent-v1", "activation-v1")).phase, "consuming")
            test.eq(ok(owner.step(config, "intent-v1", "activation-v1")).phase, "authorized")
            test.eq(ok(owner.desired(config)).intent_id, "intent-v1")
            local v2 = assert(artifact.create({{id = "demo:run", kind = "function.lua", data = {source = "return 'v2'"}}}))
            selected_plan(plans, "v2", {bytes = v2.bytes, digest = v2.digest})
            local desired = ok(owner.desired(config))
            test.eq(desired.intent_id, "intent-v1")
            test.eq(desired.version, "v1")
            test.eq(ok(owner.recover(config, "activation-v1")).phase, "applying")
            local settled = ok(owner.recover(config, "activation-v1"))
            test.eq(settled.outcome, "applied")
            test.eq(settled.version, "v1")
            test.is_true(applied)
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)
        test.it("advances an approved activation to applied in one call", function()
            local plans = assert(plan_store.open("bee:db", "node-owner", "workspace-advance"))
            local activations = assert(activation_store.open("bee:db", "node-owner", "workspace-advance"))
            local entry = {id = "demo:run", kind = "function.lua", data = {source = "return 'advanced'"}}
            local exact = assert(artifact.create({entry}))
            selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
            local applied = 0
            local config: owner.Config = {plans = plans, activations = activations, resolver = resolver(entry),
                approvals = approvals(), actor_id = "host-a", consumer_id = "destination-host",
                overlay_owner = "bee.gov:advance-overlay", approval_policy = "local-install", migrations = migration_effect(),
                matches = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): (boolean?, string?, boolean?) return applied > 0, nil end,
                apply = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): ({[string]: unknown}?, string?, boolean?)
                    applied = applied + 1
                    return {changed = true}, nil
                end}
            test.eq(ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                version = "v1", intent_id = "intent-advance", receipt_key = "advance-v1"})).phase, "approval_bound")
            local settled = ok(owner.advance(config, "intent-advance", "advance-v1"))
            test.eq(settled.phase, "settled")
            test.eq(settled.outcome, "applied")
            test.eq(applied, 1)
            local again = ok(owner.advance(config, "intent-advance", "advance-v1"))
            test.eq(again.outcome, "applied")
            test.eq(applied, 1)
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)
        test.it("settles exact materialization after remeasurement even with an unchanged base revision", function()
            local workspace = "workspace-activation-yield"
            local plans = assert(plan_store.open("bee:db", "node-owner", workspace))
            local activations = assert(activation_store.open("bee:db", "node-owner", workspace))
            local entry = {id = "demo:yield", kind = "function.lua", data = {source = "return 'v1'"}}
            local exact = assert(artifact.create({entry}))
            selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
            local world: ResolverWorld = {revision = 4, digest = SHA}
            local applied, apply_count = false, 0
            local config: owner.Config = {plans = plans, activations = activations,
                resolver = shifting_resolver(entry, world), approvals = approvals(), actor_id = "host-a",
                consumer_id = "destination-host", overlay_owner = "bee.gov:test-overlay",
                approval_policy = "local-install", migrations = migration_effect(),
                matches = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): (boolean?, string?, boolean?)
                    return applied, nil
                end,
                apply = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): ({[string]: unknown}?, string?, boolean?)
                    applied, apply_count = true, apply_count + 1
                    return {changed = true}, nil
                end}
            ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                version = "v1", intent_id = "intent-yield", receipt_key = "activation-yield"}))
            test.eq(ok(owner.step(config, "intent-yield", "activation-yield")).phase, "consuming")
            test.eq(ok(owner.step(config, "intent-yield", "activation-yield")).phase, "authorized")
            test.eq(ok(owner.step(config, "intent-yield", "activation-yield")).phase, "applying")
            local materialized = ok(owner.step(config, "intent-yield", "activation-yield"))
            test.eq(materialized.phase, "settled")
            test.eq(materialized.outcome, "applied")
            test.is_true(applied)
            test.eq(apply_count, 1)
            local settled = ok(owner.step(config, "intent-yield", "activation-yield"))
            test.eq(settled.outcome, "applied")
            test.eq(apply_count, 1)
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)
        test.it("refuses application admission drift after approval binding", function()
            local workspace = "workspace-admission-drift"
            local plans = assert(plan_store.open("bee:db", "node-owner", workspace))
            local activations = assert(activation_store.open("bee:db", "node-owner", workspace))
            local entry = {id = "demo:admission-drift", kind = "function.lua", data = {source = "return 'v1'"}}
            local exact = assert(artifact.create({entry}))
            selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
            local world: ResolverWorld = {revision = 4, digest = SHA,
                application_admission = admission(exact.digest, SHA, nil, workspace)}
            local config: owner.Config = {plans = plans, activations = activations,
                resolver = shifting_resolver(entry, world), approvals = approvals(), actor_id = "host-a",
                consumer_id = "destination-host", overlay_owner = "bee.gov:test-overlay",
                approval_policy = "local-install", migrations = migration_effect(),
                matches = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): (boolean?, string?, boolean?) return false, nil end,
                apply = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): ({[string]: unknown}?, string?, boolean?) return {changed = true}, nil end}
            local prepared = ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                version = "v1", intent_id = "intent-admission-drift", receipt_key = "admission-drift"}))
            test.eq(prepared.application_admission_digest, (assert(bounds.object(world.application_admission))).digest)
            world.application_admission = admission(exact.digest, string.rep("b", 64), nil, workspace)
            local refused = owner.step(config, "intent-admission-drift", "admission-drift")
            test.is_false(refused.ok)
            expect_code(refused, "CONFLICT")
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)
        test.it("rebuilds the composed admission from immutable intent for apply and cold recovery", function()
            local workspace = "workspace-admission-recovery"
            local plans = assert(plan_store.open("bee:db", "node-owner", workspace))
            local activations = assert(activation_store.open("bee:db", "node-owner", workspace))
            local entry = {id = "demo:admission-recovery", kind = "function.lua", data = {source = "return 'v1'"}}
            local exact = assert(artifact.create({entry}))
            selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
            local frozen = admission(exact.digest, SHA, nil, workspace)
            local applied = false
            local apply_count = 0
            local function config(): owner.Config
                return {plans = plans, activations = activations,
                    resolver = shifting_resolver(entry, {revision = 4, digest = SHA, application_admission = frozen}),
                    approvals = approvals(), actor_id = "host-a", consumer_id = "destination-host",
                    overlay_owner = "bee.gov:test-overlay", approval_policy = "local-install", migrations = migration_effect(),
                    matches = function(_overlay: string, entries: unknown, admission_blob: unknown?, _intent: unknown): (boolean?, string?, boolean?)
                        test.eq(#(principals.items(entries)), 1)
                        local blob = assert(bounds.object(admission_blob))
                        test.eq(blob.bytes, frozen.bytes)
                        test.eq(blob.digest, frozen.digest)
                        return applied, nil
                    end,
                    apply = function(_overlay: string, entries: unknown, admission_blob: unknown?, _intent: unknown): ({[string]: unknown}?, string?, boolean?)
                        test.eq(#(principals.items(entries)), 1)
                        local blob = assert(bounds.object(admission_blob))
                        test.eq(blob.bytes, frozen.bytes)
                        test.eq(blob.digest, frozen.digest)
                        applied, apply_count = true, apply_count + 1
                        return {changed = true}, nil
                    end}
            end
            ok(owner.prepare(config(), {source_node = "source-a", source_workspace = "app-a",
                version = "v1", intent_id = "intent-admission-recovery", receipt_key = "admission-recovery"}))
            test.eq(ok(owner.step(config(), "intent-admission-recovery", "admission-recovery")).phase, "consuming")
            test.eq(ok(owner.step(config(), "intent-admission-recovery", "admission-recovery")).phase, "authorized")
            test.eq(ok(owner.step(config(), "intent-admission-recovery", "admission-recovery")).phase, "applying")
            test.eq(ok(owner.step(config(), "intent-admission-recovery", "admission-recovery")).outcome, "applied")
            test.eq(apply_count, 1)
            applied = false
            local recovered = ok(owner.recover(config(), "admission-recovery"))
            test.is_true(recovered.recovered == true)
            test.eq(apply_count, 2)
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)
        test.it("restores approved capability admission after partial and cold overlay loss", function()
            local workspace = "workspace-partial-grant-recovery"
            local plans = assert(plan_store.open("bee:db", "node-owner", workspace))
            local activations = assert(activation_store.open("bee:db", "node-owner", workspace))
            local entry = {id = "demo:grant-recovery", kind = "function.lua", data = {source = "return 'v1'"}}
            local exact = assert(artifact.create({entry}))
            selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
            local vocabulary: capability_model.Vocabulary = {revision = 1, never = {}, capabilities = {}}
            local proposal, proposal_error = capability_grants.propose(vocabulary, "bee.gov:test-overlay",
                "demo:grant-recovery", {}, nil)
            if not proposal then error(tostring(proposal_error)) end
            local review, review_error = capability_grants.diff(vocabulary, nil, proposal)
            if not review then error(tostring(review_error)) end
            local frozen = admission(exact.digest, SHA, nil, workspace)
            local world: ResolverWorld = {revision = 4, digest = SHA, application_admission = frozen,
                capability = {kind = "new", proposal = proposal, review = review}}
            local application_entry_present, apply_count = false, 0
            local installed_evidence: preflight.CapabilityEvidence? = nil
            local config: owner.Config = {plans = plans, activations = activations,
                resolver = shifting_resolver(entry, world), approvals = approvals(), actor_id = "host-a",
                consumer_id = "destination-host", overlay_owner = "bee.gov:test-overlay",
                approval_policy = "local-install", migrations = migration_effect(),
                matches = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): (boolean?, string?, boolean?)
                    return application_entry_present, nil
                end,
                apply = function(_overlay: string, _entries: unknown, _admission: unknown?, intent_raw: unknown): ({[string]: unknown}?, string?, boolean?)
                    if installed_evidence == nil then
                        local intent = assert(bounds.object(intent_raw))
                        local record, record_error = capability_grants.record("bee.gov:test-overlay", workspace,
                            "demo:grant-recovery", proposal, intent.approval_id, 1, intent.artifact_digest,
                            intent.version)
                        if not record then return nil, tostring(record_error) end
                        local installed, decode_error = capability_grants.decode(record, "bee.gov:test-overlay",
                            workspace, "demo:grant-recovery", vocabulary)
                        if not installed then return nil, tostring(decode_error) end
                        local installed_review, installed_review_error = capability_grants.diff(vocabulary, installed, proposal)
                        if not installed_review then return nil, tostring(installed_review_error) end
                        installed_evidence = {kind = "installed", proposal = proposal, installed = installed,
                            review = installed_review}
                        world.capability = installed_evidence
                    end
                    application_entry_present, apply_count = true, apply_count + 1
                    return {changed = true}, nil
                end}
            ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                version = "v1", intent_id = "intent-partial-grant", receipt_key = "partial-grant"}))
            test.eq(ok(owner.step(config, "intent-partial-grant", "partial-grant")).phase, "consuming")
            test.eq(ok(owner.step(config, "intent-partial-grant", "partial-grant")).phase, "authorized")
            test.eq(ok(owner.step(config, "intent-partial-grant", "partial-grant")).phase, "applying")
            test.eq(ok(owner.step(config, "intent-partial-grant", "partial-grant")).outcome, "applied")
            test.is_true(installed_evidence ~= nil)
            application_entry_present = false
            local restored = ok(owner.recover(config, "partial-grant"))
            test.is_true(restored.recovered == true)
            test.is_true(application_entry_present)
            test.eq(apply_count, 2)
            application_entry_present = false
            local live = installed_evidence
            if not live or live.kind ~= "installed" then error("installed grant evidence is missing") end
            local approved_id = live.installed.approval_id
            live.installed.approval_id = "another-approval"
            test.eq(owner.recover(config, "cold-grant-conflicting").code, "CONFLICT")
            test.eq(apply_count, 2)
            live.installed.approval_id = approved_id
            world.capability = {kind = "new", proposal = proposal, review = review}
            world.application_admission = admission(exact.digest, SHA_B, nil, workspace)
            test.eq(owner.recover(config, "cold-grant-changed").code, "CONFLICT")
            test.eq(apply_count, 2)
            world.application_admission = nil
            test.eq(owner.recover(config, "cold-grant-unmeasured").code, "CONFLICT")
            test.eq(apply_count, 2)
            world.application_admission = frozen
            local cold = ok(owner.recover(config, "cold-grant"))
            test.is_true(cold.recovered == true)
            test.is_true(application_entry_present)
            test.eq(apply_count, 3)
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)
        test.it("refuses an application admission for another overlay before storing or requesting approval", function()
            local workspace = "workspace-admission-owner"
            local plans = assert(plan_store.open("bee:db", "node-owner", workspace))
            local activations = assert(activation_store.open("bee:db", "node-owner", workspace))
            local entry = {id = "demo:admission-owner", kind = "function.lua", data = {source = "return 'v1'"}}
            local exact = assert(artifact.create({entry}))
            selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
            local world: ResolverWorld = {revision = 4, digest = SHA,
                application_admission = admission(exact.digest, SHA, "bee.gov:other-overlay", workspace)}
            local config: owner.Config = {plans = plans, activations = activations,
                resolver = shifting_resolver(entry, world), approvals = approvals(), actor_id = "host-a",
                consumer_id = "destination-host", overlay_owner = "bee.gov:test-overlay",
                approval_policy = "local-install", migrations = migration_effect(),
                matches = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): (boolean?, string?, boolean?) return false, nil end,
                apply = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): ({[string]: unknown}?, string?, boolean?) return {changed = true}, nil end}
            local refused = owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                version = "v1", intent_id = "intent-admission-owner", receipt_key = "admission-owner"})
            test.is_false(refused.ok)
            expect_code(refused, "CONFLICT")
            expect_code(activation_store.get(activations, "intent-admission-owner"), "NOT_FOUND")
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)
    end)
end

return {define = admission_tests}
