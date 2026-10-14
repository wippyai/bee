-- MIT. The activation owner removes an installed application: it records the
-- person, empties the owner's overlay and leaves the intents as history.
local test = require("test")
local bounds = require("bounds")
local canonical = require("canonical")
local hash = require("hash")
local uuid = require("uuid")
local activation_store = require("activation_store")
local uninstall = require("activation_uninstall")

local OWNER = "bee.gov.apps:workspace.notes"

local function blob(bytes: string): {[string]: string}
    return {bytes = bytes, digest = assert(hash.sha256(bytes))}
end

local function ok(result: {[string]: unknown}): {[string]: unknown}
    test.is_true(result.ok == true, tostring(result.code) .. ": " .. tostring(result.message))
    return assert(bounds.object(result.value))
end

-- install walks one intent to an applied, observed generation.
local function install(state: activation_store.Store, intent_id: string, version: string): {[string]: unknown}
    local work = blob(assert(canonical.encode({schema_revision = "bee.governance-migration-work@2",
        destination_node = "node-a", source_node = "source-a", base_revision = 0,
        base_digest = string.rep("a", 64), policy_digest = string.rep("b", 64),
        candidate_digest = string.rep("c", 64), artifact_digest = string.rep("d", 64),
        plan_digest = string.rep("e", 64), migrations = {}, databases = {}})))
    local prepared = ok(activation_store.call(state, "host", {operation = "prepare_activation", intent_id = intent_id,
        expected_revision = 0, idempotency_key = intent_id .. "-prepare", overlay_owner = OWNER, source_node = "source-a",
        source_workspace = "notes", version = version, plan_digest = string.rep("a", 64), plan_revision = 1,
        selection_revision = 1, artifact = blob("artifact-" .. intent_id), resolution = blob("resolution-" .. intent_id),
        preflight = blob("preflight-" .. intent_id), migration_work = work}))
    ok(activation_store.call(state, "host", {operation = "bind_approval", intent_id = intent_id, expected_revision = 1,
        idempotency_key = intent_id .. "-bind", approval_id = "approval-" .. intent_id,
        approval_proposal_digest = string.rep("d", 64), approval_owner_incarnation = 1}))
    ok(activation_store.call(state, "host", {operation = "begin_consume", intent_id = intent_id, expected_revision = 2,
        idempotency_key = intent_id .. "-consume"}))
    ok(activation_store.call(state, "host", {operation = "record_consumption", intent_id = intent_id, expected_revision = 3,
        idempotency_key = intent_id .. "-record", consumer_id = "host", proposal_digest = string.rep("d", 64),
        effect_key = prepared.effect_key}))
    ok(activation_store.call(state, "host", {operation = "begin_apply", intent_id = intent_id, expected_revision = 4,
        idempotency_key = intent_id .. "-apply"}))
    return ok(activation_store.call(state, "host", {operation = "record_outcome", intent_id = intent_id,
        expected_revision = 5, idempotency_key = intent_id .. "-outcome", outcome = "applied", diagnostics = "observed"}))
end

local function define_tests()
    test.describe("activation owner uninstall", function()
        test.it("records the person, empties the overlay and leaves the version as history", function()
            local state = assert(activation_store.open("bee:db", "node-a", "workspace-" .. assert(uuid.v7())))
            install(state, "intent-1", "1.0.0")
            local emptied = false
            local config: uninstall.Config = {activations = state, overlay_owner = OWNER, actor_id = "person-1",
                clear = function(): ({[string]: unknown}?, string?) emptied = true; return {changed = true}, nil end,
                cleared = function(): (boolean?, string?) return emptied, nil end}
            local removed = ok(uninstall.uninstall(config, "remove-1"))
            test.eq(removed.intent_id, "intent-1")
            test.is_true(emptied)
            test.eq(activation_store.desired(state, OWNER).code, "NOT_FOUND")
            local rows = assert(bounds.array(ok(activation_store.listing(state)).activations))
            test.eq(#rows, 1)
            test.is_nil(assert(bounds.object(rows[1])).observed_intent_id)
            local again = uninstall.uninstall(config, "remove-2")
            test.eq(again.code, "NOT_FOUND")
            assert(activation_store.close(state))
        end)

        test.it("says when the emptied overlay cannot be observed, after the removal is recorded", function()
            local state = assert(activation_store.open("bee:db", "node-a", "workspace-" .. assert(uuid.v7())))
            install(state, "intent-1", "1.0.0")
            local config: uninstall.Config = {activations = state, overlay_owner = OWNER, actor_id = "person-1",
                clear = function(): ({[string]: unknown}?, string?) return {changed = true}, nil end,
                cleared = function(): (boolean?, string?) return false, nil end}
            test.eq(uninstall.uninstall(config, "remove-1").code, "UNCERTAIN")
            test.eq(activation_store.desired(state, OWNER).code, "NOT_FOUND")
            assert(activation_store.close(state))
        end)

        test.it("refuses while the application has a version on its way and an invalid receipt", function()
            local state = assert(activation_store.open("bee:db", "node-a", "workspace-" .. assert(uuid.v7())))
            install(state, "intent-1", "1.0.0")
            local pending = {operation = "prepare_activation", intent_id = "intent-2", expected_revision = 0,
                idempotency_key = "intent-2-prepare", overlay_owner = OWNER, source_node = "source-a",
                source_workspace = "notes", version = "1.0.1", plan_digest = string.rep("a", 64), plan_revision = 1,
                selection_revision = 1, artifact = blob("artifact-2"), resolution = blob("resolution-2"),
                preflight = blob("preflight-2"), migration_work = blob(assert(canonical.encode({
                    schema_revision = "bee.governance-migration-work@2", destination_node = "node-a", source_node = "source-a",
                    base_revision = 0, base_digest = string.rep("a", 64), policy_digest = string.rep("b", 64),
                    candidate_digest = string.rep("c", 64), artifact_digest = string.rep("d", 64),
                    plan_digest = string.rep("e", 64), migrations = {}, databases = {}})))}
            ok(activation_store.call(state, "host", pending))
            ok(activation_store.call(state, "host", {operation = "bind_approval", intent_id = "intent-2", expected_revision = 1,
                idempotency_key = "intent-2-bind", approval_id = "approval-2", approval_proposal_digest = string.rep("d", 64),
                approval_owner_incarnation = 1}))
            ok(activation_store.call(state, "host", {operation = "begin_consume", intent_id = "intent-2", expected_revision = 2,
                idempotency_key = "intent-2-consume"}))
            local second = ok(activation_store.get(state, "intent-2"))
            ok(activation_store.call(state, "host", {operation = "record_consumption", intent_id = "intent-2", expected_revision = 3,
                idempotency_key = "intent-2-record", consumer_id = "host", proposal_digest = string.rep("d", 64),
                effect_key = second.effect_key}))
            local called = false
            local config: uninstall.Config = {activations = state, overlay_owner = OWNER, actor_id = "person-1",
                clear = function(): ({[string]: unknown}?, string?) called = true; return {changed = true}, nil end,
                cleared = function(): (boolean?, string?) return false, nil end}
            test.eq(uninstall.uninstall(config, "remove-1").code, "CONFLICT")
            test.eq(uninstall.uninstall(config, "bad key\n").code, "INVALID")
            test.is_false(called)
            assert(activation_store.close(state))
        end)
    end)
end

return test.run_cases(define_tests)
