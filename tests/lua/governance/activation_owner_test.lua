-- MIT. Destination orchestration keeps selection, approval, desired state and
-- overlay observation in their separate owners.
local test = require("test")
local hash = require("hash")
local canonical = require("canonical")
local artifact = require("artifact")
local plan_store = require("plan_store")
local activation_store = require("activation_store")
local owner = require("activation_owner")
local preflight = require("preflight")

local SHA = string.rep("a", 64)

local function blob(bytes: string): {[string]: string}
    local digest, err = hash.sha256(bytes)
    if not digest then error(tostring(err)) end
    return {bytes = bytes, digest = digest}
end

local function ok(result: {[string]: unknown}): {[string]: unknown}
    if result.ok ~= true then
        local failure = result.error :: {[string]: unknown}?
        error(tostring(result.code or (failure and failure.code)) .. ": "
            .. tostring(result.message or (failure and failure.message)))
    end
    return result.value :: {[string]: unknown}
end

local function selected_plan(store: plan_store.Store, version: string, entry_blob: {[string]: unknown}): {[string]: unknown}
    local identity = {source_node = "source-a", source_workspace = "app-a", version = version}
    local staged = ok(plan_store.call(store, "host-a", {operation = "stage", expected_revision = 0,
        idempotency_key = "stage-" .. version, source_node = identity.source_node,
        source_workspace = identity.source_workspace, version = version,
        candidate = blob("candidate-" .. version), artifact = entry_blob,
        preflight = blob("source-preflight-" .. version)}))
    local reviewed = ok(plan_store.call(store, "host-a", {operation = "record_review",
        expected_revision = staged.revision, idempotency_key = "review-" .. version,
        source_node = identity.source_node, source_workspace = identity.source_workspace,
        version = version, review_status = "accepted", review_reason = "reviewed exact bytes"}))
    return ok(plan_store.call(store, "host-a", {operation = "select",
        expected_revision = reviewed.revision, idempotency_key = "select-" .. version,
        source_node = identity.source_node, source_workspace = identity.source_workspace,
        version = version}))
end

local SHA_B = string.rep("b", 64)

local function shifting_resolver(entry: {[string]: unknown}, world: {revision: integer, digest: string}): owner.Resolver
    local entry_bytes, encode_error = canonical.encode(entry)
    if not entry_bytes then error(tostring(encode_error)) end
    local selected_digest, digest_error = hash.sha256(entry_bytes)
    if not selected_digest then error(tostring(digest_error)) end
    local value = {}
    function value:resolve(plan: unknown): (preflight.Candidate?, preflight.Context?, string?)
        local selected = plan :: {[string]: unknown}
        local version = selected.version :: string
        local entry_id, entry_kind = entry.id :: string, entry.kind :: string
        local candidate: preflight.Candidate = {destination_node = "node-owner", source_node = "source-a",
            base_revision = world.revision, base_digest = world.digest,
            artifacts = {{component = "demo/app", version = version,
                digest = SHA, dependencies = {}, namespaces = {"demo"}}},
            entries = {{id = entry_id, kind = entry_kind, package = "demo/app",
                digest = selected_digest, references = {}, auto_start = false,
                grants = {}, modules = {}, config_objects = {}, config_lists = {}, config_empty = {}}}, requirements = {}, migrations = {}}
        local context: preflight.Context = {node_id = "node-owner", registry_revision = world.revision,
                registry_digest = world.digest,
                policy_digest = SHA, packages = {["demo/app"] = true}, namespaces = {demo = true},
                kinds = {[entry_kind] = true}, databases = {}, grants = {}, modules = {},
                entries = {}, applied = {}, exact_expansion = true, migration_barrier = false}
        return candidate, context, nil
    end
    return value :: owner.Resolver
end

local function resolver(entry: {[string]: unknown}): owner.Resolver
    return shifting_resolver(entry, {revision = 4, digest = SHA})
end

local function approvals(): owner.Executor
    local value = {}
    function value:call(method: string, request: unknown): (unknown?, unknown?)
        local input = request :: {[string]: unknown}
        if method == "bee.approvals:request" then
            local proposal = input.proposal :: {[string]: unknown}
            return {ok = true, value = {approval_id = "approval-v1", proposal = proposal,
                proposal_digest = assert(hash.sha256(assert(canonical.encode(proposal)))),
                owner_incarnation = 3}}, nil
        end
        return {ok = true, value = {approval_id = input.approval_id,
            proposal_digest = input.proposal_digest, consumer_id = "destination-host",
            consumed_effect = input.effect_key}}, nil
    end
    return value :: owner.Executor
end

local function lossy_approvals(): owner.Executor
    local value = {}
    local consumed = false
    function value:call(method: string, request: unknown): (unknown?, unknown?)
        local input = request :: {[string]: unknown}
        if method == "bee.approvals:request" then
            local proposal = input.proposal :: {[string]: unknown}
            return {ok = true, value = {approval_id = "approval-crash", proposal = proposal,
                proposal_digest = assert(hash.sha256(assert(canonical.encode(proposal)))),
                owner_incarnation = 3}}, nil
        end
        if not consumed then
            consumed = true
            return nil, "approval reply was lost after commit"
        end
        return {ok = true, value = {approval_id = input.approval_id,
            proposal_digest = input.proposal_digest, consumer_id = "destination-host",
            consumed_effect = input.effect_key}}, nil
    end
    return value :: owner.Executor
end

local function define_tests()
    test.describe("Governance activation owner", function()
        test.it("establishes only the approved desired version and ignores a newer selection", function()
            local plans, plan_error = plan_store.open("bee.governance:plan_test_db", "node-owner", "workspace-owner")
            if not plans then error(tostring(plan_error)) end
            local activations, activation_error = activation_store.open("bee.governance:activation_test_db", "node-owner", "workspace-owner")
            if not activations then error(tostring(activation_error)) end
            local entry = {id = "demo:run", kind = "function.lua", data = {source = "return 'v1'"}}
            local exact = assert(artifact.create({entry}))
            selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
            local applied = false
            local config: owner.Config = {plans = plans, activations = activations, resolver = resolver(entry),
                approvals = approvals(), actor_id = "host-a", consumer_id = "destination-host",
                overlay_owner = "bee.governance:test-overlay", approval_policy = "local-install",
                matches = function(_overlay: string, _entries: unknown): (boolean?, string?) return applied, nil end,
                apply = function(_overlay: string, _entries: unknown): ({[string]: unknown}?, string?)
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
        test.it("reconciles lost consume and apply replies without following a newer plan", function()
            local plans, plan_error = plan_store.open("bee.governance:plan_test_db", "node-owner", "workspace-crash")
            if not plans then error(tostring(plan_error)) end
            local activations, activation_error = activation_store.open("bee.governance:activation_test_db", "node-owner", "workspace-crash")
            if not activations then error(tostring(activation_error)) end
            local entry = {id = "demo:run", kind = "function.lua", data = {source = "return 'v1'"}}
            local exact = assert(artifact.create({entry}))
            selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
            local applied = false
            local first_apply = true
            local fail_restore = false
            local config: owner.Config = {plans = plans, activations = activations, resolver = resolver(entry),
                approvals = lossy_approvals(), actor_id = "host-a", consumer_id = "destination-host",
                overlay_owner = "bee.governance:test-overlay", approval_policy = "local-install",
                matches = function(_overlay: string, _entries: unknown): (boolean?, string?) return applied, nil end,
                apply = function(_overlay: string, _entries: unknown): ({[string]: unknown}?, string?)
                    if fail_restore then return nil, "overlay restore failed" end
                    applied = true
                    if first_apply then first_apply = false; return nil, "overlay reply was lost" end
                    return {changed = false}, nil
                end}
            ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                version = "v1", intent_id = "intent-crash", receipt_key = "activation-crash"}))
            test.eq(ok(owner.step(config, "intent-crash", "activation-crash")).phase, "consuming")
            test.eq(owner.step(config, "intent-crash", "activation-crash").code, "UNAVAILABLE")
            local v2 = assert(artifact.create({{id = "demo:run", kind = "function.lua", data = {source = "return 'v2'"}}}))
            selected_plan(plans, "v2", {bytes = v2.bytes, digest = v2.digest})
            test.eq(ok(owner.step(config, "intent-crash", "activation-crash")).phase, "authorized")
            test.eq(ok(owner.recover(config, "activation-crash")).phase, "applying")
            local uncertain = owner.recover(config, "activation-crash")
            test.eq(uncertain.code, "UNCERTAIN")
            local settled = ok(owner.recover(config, "activation-crash"))
            test.eq(settled.outcome, "applied")
            test.eq(settled.version, "v1")
            applied = false
            local restored = ok(owner.recover(config, "activation-crash"))
            test.is_true(restored.recovered == true)
            test.is_true(applied)
            applied, fail_restore = false, true
            test.eq(owner.recover(config, "activation-crash").code, "UNCERTAIN")
            fail_restore = false
            local recovered_again = ok(owner.recover(config, "activation-crash"))
            test.eq(recovered_again.outcome, "applied")
            test.is_true(applied)
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)

        test.it("settles an in-flight effect before authorizing v2 and fences historical v1 recovery", function()
            local plans, plan_error = plan_store.open("bee.governance:plan_test_db", "node-owner", "workspace-version-fence")
            if not plans then error(tostring(plan_error)) end
            local activations, activation_error = activation_store.open("bee.governance:activation_test_db", "node-owner", "workspace-version-fence")
            if not activations then error(tostring(activation_error)) end
            local entry = {id = "demo:run", kind = "function.lua", data = {source = "return 'stable'"}}
            local exact = assert(artifact.create({entry}))
            local applied = false
            local apply_count = 0
            local config: owner.Config = {plans = plans, activations = activations, resolver = resolver(entry),
                approvals = approvals(), actor_id = "host-a", consumer_id = "destination-host",
                overlay_owner = "bee.governance:test-overlay", approval_policy = "local-install",
                matches = function(_overlay: string, _entries: unknown): (boolean?, string?) return applied, nil end,
                apply = function(_overlay: string, _entries: unknown): ({[string]: unknown}?, string?)
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
            test.eq(overlap.code, "CONFLICT")
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
            test.eq(historical.code, "CONFLICT")
            test.is_false(applied)
            test.eq(apply_count, 2)
            test.eq(ok(owner.desired(config)).intent_id, "intent-fenced-v2")
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)

        test.it("refuses an authorized apply when the composed base changed under review", function()
            local plans, plan_error = plan_store.open("bee.governance:plan_test_db", "node-owner", "workspace-composed-refusal")
            if not plans then error(tostring(plan_error)) end
            local activations, activation_error = activation_store.open("bee.governance:activation_test_db", "node-owner", "workspace-composed-refusal")
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
                overlay_owner = "bee.governance:test-overlay", approval_policy = "local-install",
                matches = function(_overlay: string, _entries: unknown): (boolean?, string?) return applied, nil end,
                apply = function(_overlay: string, _entries: unknown): ({[string]: unknown}?, string?)
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
            test.eq(refused.code, "CONFLICT")
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

        test.it("leaves an apply uncertain when the base moves during the apply", function()
            local plans, plan_error = plan_store.open("bee.governance:plan_test_db", "node-owner", "workspace-composed-apply")
            if not plans then error(tostring(plan_error)) end
            local activations, activation_error = activation_store.open("bee.governance:activation_test_db", "node-owner", "workspace-composed-apply")
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
                overlay_owner = "bee.governance:test-overlay", approval_policy = "local-install",
                matches = function(_overlay: string, _entries: unknown): (boolean?, string?) return applied, nil end,
                apply = function(_overlay: string, _entries: unknown): ({[string]: unknown}?, string?)
                    applied, apply_count = true, apply_count + 1
                    world.revision, world.digest = 5, SHA_B
                    return {changed = true}, nil
                end}
            ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                version = "v1", intent_id = "intent-composed-apply", receipt_key = "composed-apply-v1"}))
            test.eq(ok(owner.step(config, "intent-composed-apply", "composed-apply-v1")).phase, "consuming")
            test.eq(ok(owner.step(config, "intent-composed-apply", "composed-apply-v1")).phase, "authorized")
            test.eq(ok(owner.step(config, "intent-composed-apply", "composed-apply-v1")).phase, "applying")
            local outcome = owner.step(config, "intent-composed-apply", "composed-apply-v1")
            test.eq(outcome.code, "UNCERTAIN")
            test.is_true(tostring(outcome.message):find("composed registry base", 1, true) ~= nil)
            test.is_true(applied)
            test.eq(apply_count, 1)
            local later = owner.recover(config, "composed-apply-v1")
            test.eq(later.code, "CONFLICT")
            test.is_true(tostring(later.message):find("composed registry base", 1, true) ~= nil)
            test.eq(apply_count, 1)
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)

        test.it("reconciles an interrupted apply after a restart without duplicating it", function()
            local plans, plan_error = plan_store.open("bee.governance:plan_test_db", "node-owner", "workspace-composed-restart")
            if not plans then error(tostring(plan_error)) end
            local activations, activation_error = activation_store.open("bee.governance:activation_test_db", "node-owner", "workspace-composed-restart")
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
                    overlay_owner = "bee.governance:test-overlay", approval_policy = "local-install",
                    matches = function(_overlay: string, _entries: unknown): (boolean?, string?) return applied, nil end,
                    apply = function(_overlay: string, _entries: unknown): ({[string]: unknown}?, string?)
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
            local reopened_plans, reopen_error = plan_store.open("bee.governance:plan_test_db", "node-owner", "workspace-composed-restart")
            if not reopened_plans then error(tostring(reopen_error)) end
            local reopened_activations, reopen_activation_error = activation_store.open("bee.governance:activation_test_db", "node-owner", "workspace-composed-restart")
            if not reopened_activations then error(tostring(reopen_activation_error)) end
            local settled = ok(owner.recover(config_with(reopened_plans, reopened_activations), "composed-restart-v1"))
            test.eq(settled.outcome, "applied")
            test.eq(apply_count, 1)
            assert(activation_store.close(reopened_activations))
            assert(plan_store.close(reopened_plans))
            local again_plans = assert(plan_store.open("bee.governance:plan_test_db", "node-owner", "workspace-composed-restart"))
            local again_activations = assert(activation_store.open("bee.governance:activation_test_db", "node-owner", "workspace-composed-restart"))
            local replayed = ok(owner.recover(config_with(again_plans, again_activations), "composed-restart-v1"))
            test.eq(replayed.outcome, "applied")
            test.eq(apply_count, 1)
            world.revision, world.digest = 5, SHA_B
            local refused = owner.recover(config_with(again_plans, again_activations), "composed-restart-v1")
            test.eq(refused.code, "CONFLICT")
            test.is_true(tostring(refused.message):find("composed registry base", 1, true) ~= nil)
            test.eq(apply_count, 1)
            assert(activation_store.close(again_activations))
            assert(plan_store.close(again_plans))
        end)
    end)
end

return test.run_cases(define_tests)
