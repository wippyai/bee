-- MIT. Persistence and fencing checks for destination activation state.
local test = require("test")
local hash = require("hash")
local canonical = require("canonical")
local store = require("activation_store")

local function blob(bytes: string): {[string]: string}
    local digest, err = hash.sha256(bytes)
    if not digest then error(tostring(err)) end
    return {bytes = bytes, digest = digest}
end
local function ok(result: {[string]: unknown}): {[string]: unknown}
    test.is_true(result.ok == true, tostring(result.code) .. ": " .. tostring(result.message))
    return result.value :: {[string]: unknown}
end
local function base(operation: string, revision: integer, key: string): {[string]: unknown}
    return {operation = operation, intent_id = "intent-v1", expected_revision = revision, idempotency_key = key}
end
local function prepare(): {[string]: unknown}
    local input = base("prepare_activation", 0, "prepare-1")
    input.overlay_owner = "bee.gov:overlay"
    input.source_node, input.source_workspace, input.version = "source-a", "source-w", "v1"
    input.plan_digest = string.rep("a", 64)
    input.plan_revision, input.selection_revision = 4, 2
    input.artifact, input.resolution, input.preflight = blob("artifact-v1"), blob("resolved-v1"), blob("preflight-v1")
    input.migration_work = blob(assert(canonical.encode({schema_revision = "bee.governance-migration-work@2",
        destination_node = "node-a", source_node = "source-a", base_revision = 0,
        base_digest = string.rep("a", 64), policy_digest = string.rep("b", 64),
        candidate_digest = string.rep("c", 64), artifact_digest = string.rep("d", 64),
        plan_digest = string.rep("e", 64), migrations = {}, databases = {}})))
    return input
end
local function migration_blob(): ({[string]: string}, string)
    local definition: {[string]: unknown} = {id = "demo:001", kind = "function.lua",
        meta = {type = "migration", target_db = "demo:db", ordinal = 1},
        data = {source = "return true"}}
    local definition_bytes = assert(canonical.encode(definition))
    local checksum = assert(hash.sha256(definition_bytes))
    local bytes = assert(canonical.encode({schema_revision = "bee.governance-migration-work@2",
        destination_node = "node-a", source_node = "source-a", base_revision = 0,
        base_digest = string.rep("a", 64), policy_digest = string.rep("b", 64),
        candidate_digest = string.rep("c", 64), artifact_digest = string.rep("d", 64),
        plan_digest = string.rep("e", 64), migrations = {{id = "demo:001", target_db = "demo:db",
            ordinal = 1, checksum = checksum, package = "demo/app", definition = definition}},
        databases = {{id = "demo:db", kind = "db.sql.sqlite", package = "base/db",
            digest = string.rep("f", 64), planned = false}}}))
    return blob(bytes), checksum
end
local function define_tests()
    test.describe("Governance activation store", function()
        test.it("keeps immutable facts and separates authorized from observed state", function()
            local state, open_error = store.open("bee.gov:activation_test_db", "node-a", "workspace-a")
            if not state then error(tostring(open_error)) end
            local prepared = ok(store.call(state, "actor-a", prepare()))
            test.eq(prepared.phase, "prepared")
            test.eq(prepared.revision, 1)
            test.is_true(type(prepared.effect_key) == "string")
            test.is_true(type(prepared.authorization_digest) == "string")
            test.eq(prepared.overlay_owner, "bee.gov:overlay")
            test.is_nil(prepared.application_admission_bytes)
            test.is_nil(prepared.application_admission_digest)
            local altered = prepare()
            altered.idempotency_key, altered.overlay_owner = "prepare-altered", "bee.gov:other"
            test.eq(store.call(state, "actor-a", altered).code, "CONFLICT")
            local bound = base("bind_approval", 1, "bind-1")
            bound.approval_id, bound.approval_proposal_digest, bound.approval_owner_incarnation = "approval-1", string.rep("d", 64), 8
            bound = ok(store.call(state, "actor-a", bound))
            test.eq(bound.phase, "approval_bound")
            local consuming = ok(store.call(state, "actor-a", base("begin_consume", 2, "consume-1")))
            test.eq(consuming.phase, "consuming")
            local consumed = base("record_consumption", 3, "receipt-1")
            consumed.consumer_id, consumed.proposal_digest, consumed.effect_key = "governance-host", string.rep("d", 64), prepared.effect_key
            consumed = ok(store.call(state, "actor-a", consumed))
            test.eq(consumed.phase, "authorized")
            test.eq(consumed.desired_intent_id, "intent-v1")
            test.eq(consumed.observed_intent_id, nil)
            local desired = ok(store.desired(state, "bee.gov:overlay"))
            test.eq(desired.intent_id, "intent-v1")
            test.eq(desired.phase, "authorized")
            local applying = ok(store.call(state, "actor-a", base("begin_apply", 4, "apply-1")))
            test.eq(applying.phase, "applying")
            test.is_true(applying.migrations_completed == true)
            local outcome = base("record_outcome", 5, "outcome-1")
            outcome.outcome, outcome.diagnostics = "uncertain", "apply reply was lost"
            local uncertain = ok(store.call(state, "actor-a", outcome))
            test.eq(uncertain.phase, "settled")
            test.eq(uncertain.outcome, "uncertain")
            test.eq(uncertain.observed_intent_id, nil)
            local reconciled = base("record_outcome", 6, "outcome-2")
            reconciled.outcome, reconciled.diagnostics = "applied", "definitions observed"
            local applied = ok(store.call(state, "actor-a", reconciled))
            test.eq(applied.phase, "settled")
            test.eq(applied.outcome, "applied")
            test.eq(applied.desired_intent_id, "intent-v1")
            test.eq(applied.observed_intent_id, "intent-v1")
            test.eq(applied.observed_artifact_digest, prepared.artifact_digest)
            assert(store.close(state))
        end)
        test.it("persists optional application admission bytes and rejects partial evidence", function()
            local state, open_error = store.open("bee.gov:activation_test_db", "node-a", "workspace-admission")
            if not state then error(tostring(open_error)) end
            local input = prepare()
            input.intent_id, input.idempotency_key = "intent-admission", "admission-prepare"
            input.application_admission = blob("canonical application admission")
            local prepared = ok(store.call(state, "actor-a", input))
            test.eq(prepared.application_admission_bytes, input.application_admission.bytes)
            test.eq(prepared.application_admission_digest, input.application_admission.digest)
            local changed = prepare()
            changed.intent_id, changed.idempotency_key = "intent-admission-changed", "admission-changed"
            changed.application_admission = blob("changed canonical application admission")
            local changed_prepared = ok(store.call(state, "actor-a", changed))
            test.is_true(prepared.authorization_digest ~= changed_prepared.authorization_digest)
            test.is_true(prepared.effect_key ~= changed_prepared.effect_key)
            assert(store.close(state))
            local reopened = assert(store.open("bee.gov:activation_test_db", "node-a", "workspace-admission"))
            local restored = ok(store.get(reopened, "intent-admission"))
            test.eq(restored.application_admission_bytes, input.application_admission.bytes)
            test.eq(restored.application_admission_digest, input.application_admission.digest)
            assert(store.close(reopened))

            local partial = prepare()
            partial.intent_id, partial.idempotency_key = "intent-partial", "admission-partial"
            partial.application_admission = {bytes = "only bytes"}
            local partial_store = assert(store.open("bee.gov:activation_test_db", "node-a", "workspace-partial"))
            local refused = store.call(partial_store, "actor-a", partial)
            test.eq(refused.code, "INVALID")
            assert(store.close(partial_store))
        end)
        test.it("persists the exact predecessor digest for grant reuse", function()
            local state = assert(store.open("bee.gov:activation_test_db", "node-a", "workspace-reuse"))
            local input = prepare()
            input.intent_id, input.idempotency_key = "intent-reuse", "reuse-prepare"
            input.grant_predecessor_digest = string.rep("b", 64)
            local prepared = ok(store.call(state, "actor-a", input))
            test.eq(prepared.grant_predecessor_digest, string.rep("b", 64))
            local bound = {operation = "bind_approval", intent_id = "intent-reuse",
                expected_revision = prepared.revision, idempotency_key = "reuse-bind",
                approval_id = "prior-approval", approval_proposal_digest = string.rep("b", 64),
                approval_owner_incarnation = 1, grant_reuse_digest = string.rep("b", 64)}
            local reused = ok(store.call(state, "actor-a", bound))
            test.eq(reused.grant_reuse_digest, string.rep("b", 64))
            local changed = {operation = "bind_approval", intent_id = "intent-other",
                expected_revision = 1, idempotency_key = "reuse-invalid",
                approval_id = "prior-approval", approval_proposal_digest = string.rep("b", 64),
                approval_owner_incarnation = 1, grant_reuse_digest = string.rep("c", 64)}
            test.eq(store.call(state, "actor-a", changed).code, "INVALID")
            assert(store.close(state))
            local reopened = assert(store.open("bee.gov:activation_test_db", "node-a", "workspace-reuse"))
            test.eq(ok(store.get(reopened, "intent-reuse")).grant_reuse_digest, string.rep("b", 64))
            test.eq(ok(store.get(reopened, "intent-reuse")).grant_predecessor_digest, string.rep("b", 64))
            assert(store.close(reopened))
        end)
        test.it("fences stale revisions, receipt actors and changed retries", function()
            local state, open_error = store.open("bee.gov:activation_test_db", "node-a", "workspace-a")
            if not state then error(tostring(open_error)) end
            local status = ok(store.call(state, "reader", {operation = "activation_status", intent_id = "intent-v1"}))
            test.eq(status.phase, "settled")
            test.eq(ok(store.desired(state, "bee.gov:overlay")).intent_id, "intent-v1")
            local stale = base("begin_apply", 4, "stale")
            local stale_result = store.call(state, "actor-a", stale)
            test.eq(stale_result.code, "CONFLICT")
            local replay_request = {operation = "record_outcome", intent_id = "intent-v1", expected_revision = 6,
                idempotency_key = "outcome-2", outcome = "applied", diagnostics = "definitions observed"}
            local replay = store.call(state, "actor-a", replay_request)
            test.is_true(replay.ok == true and replay.replayed == true)
            test.eq(store.call(state, "actor-b", replay_request).code, "DENIED")
            local changed_retry = store.call(state, "actor-a", {operation = "record_outcome", intent_id = "intent-v1", expected_revision = 6, idempotency_key = "outcome-2", outcome = "failed", diagnostics = "changed"})
            test.eq(changed_retry.code, "CONFLICT")
            local drift = base("record_outcome", 7, "outcome-drift")
            drift.outcome, drift.diagnostics = "uncertain", "desired overlay was not observable"
            local uncertain = ok(store.call(state, "actor-a", drift))
            test.eq(uncertain.outcome, "uncertain")
            test.eq(uncertain.observed_outcome, "uncertain")
            local restored = base("record_outcome", 8, "outcome-restored")
            restored.outcome, restored.diagnostics = "applied", "desired overlay restored"
            local applied = ok(store.call(state, "actor-a", restored))
            test.eq(applied.outcome, "applied")
            test.eq(applied.observed_outcome, "applied")
            assert(store.close(state))
        end)
        test.it("keeps independent desired versions for two application overlays", function()
            local state, open_error = store.open("bee.gov:activation_test_db", "node-a", "workspace-multi")
            if not state then error(tostring(open_error)) end
            local function authorize(intent_id: string, overlay_owner: string, source_workspace: string, prefix: string)
                local input = {operation = "prepare_activation", intent_id = intent_id,
                    expected_revision = 0, idempotency_key = prefix .. "-prepare",
                    overlay_owner = overlay_owner, source_node = "source-a",
                    source_workspace = source_workspace, version = "v1",
                    plan_digest = string.rep("a", 64), plan_revision = 2, selection_revision = 2,
                    artifact = blob("artifact-" .. intent_id), resolution = blob("resolution-" .. intent_id),
                    preflight = blob("preflight-" .. intent_id), migration_work = prepare().migration_work}
                local prepared = ok(store.call(state, "actor-a", input))
                local bound = ok(store.call(state, "actor-a", {operation = "bind_approval", intent_id = intent_id,
                    expected_revision = 1, idempotency_key = prefix .. "-bind", approval_id = "approval-" .. prefix,
                    approval_proposal_digest = string.rep("d", 64), approval_owner_incarnation = 1}))
                test.eq(bound.phase, "approval_bound")
                ok(store.call(state, "actor-a", {operation = "begin_consume", intent_id = intent_id,
                    expected_revision = 2, idempotency_key = prefix .. "-consume"}))
                local authorized = ok(store.call(state, "actor-a", {operation = "record_consumption", intent_id = intent_id,
                    expected_revision = 3, idempotency_key = prefix .. "-record", consumer_id = "host",
                    proposal_digest = string.rep("d", 64), effect_key = prepared.effect_key}))
                test.eq(authorized.phase, "authorized")
            end
            authorize("intent-app-a", "bee.apps:app-a", "application-a", "app-a")
            authorize("intent-app-b", "bee.apps:app-b", "application-b", "app-b")
            test.eq(ok(store.desired(state, "bee.apps:app-a")).intent_id, "intent-app-a")
            test.eq(ok(store.desired(state, "bee.apps:app-b")).intent_id, "intent-app-b")
            test.eq(store.desired(state, "bee.apps:missing").code, "NOT_FOUND")
            assert(store.close(state))
        end)
        test.it("records exact partial migration progress before overlay settlement", function()
            local state, open_error = store.open("bee.gov:activation_test_db", "node-a", "workspace-migrations")
            if not state then error(tostring(open_error)) end
            local input = prepare()
            input.intent_id, input.idempotency_key = "intent-migrations", "migrations-prepare"
            local work, checksum = migration_blob()
            input.migration_work = work
            local prepared = ok(store.call(state, "actor-a", input))
            ok(store.call(state, "actor-a", {operation = "bind_approval", intent_id = input.intent_id,
                expected_revision = prepared.revision, idempotency_key = "migrations-bind", approval_id = "approval-migrations",
                approval_proposal_digest = string.rep("d", 64), approval_owner_incarnation = 1}))
            ok(store.call(state, "actor-a", {operation = "begin_consume", intent_id = input.intent_id,
                expected_revision = 2, idempotency_key = "migrations-consume"}))
            local authorized = ok(store.call(state, "actor-a", {operation = "record_consumption", intent_id = input.intent_id,
                expected_revision = 3, idempotency_key = "migrations-authorized", consumer_id = "host",
                proposal_digest = string.rep("d", 64), effect_key = prepared.effect_key}))
            local applying = ok(store.call(state, "actor-a", {operation = "begin_apply", intent_id = input.intent_id,
                expected_revision = authorized.revision, idempotency_key = "migrations-apply"}))
            test.is_false(applying.migrations_completed)
            local premature = store.call(state, "actor-a", {operation = "record_outcome", intent_id = input.intent_id,
                expected_revision = applying.revision, idempotency_key = "migrations-premature",
                outcome = "applied", diagnostics = "must refuse"})
            test.is_false(premature.ok)
            test.eq(premature.code, "CONFLICT")
            local receipt = blob(assert(canonical.encode({schema_revision = "bee.governance-migration-receipt@1",
                rows = {{id = "demo:001", target_db = "demo:db", module = "demo/app", status = "applied"}}})))
            local completed = ok(store.call(state, "actor-a", {operation = "record_migrations", intent_id = input.intent_id,
                expected_revision = applying.revision, idempotency_key = "migrations-record", receipt = receipt,
                complete = true, diagnostics = "ledger confirmed"}))
            test.is_true(completed.migrations_completed)
            test.eq(completed.phase, "applying")
            local facts = ok(store.applied(state, "demo/app"))
            test.eq(((facts.migrations :: {[string]: unknown})["demo:db\ndemo:001"] :: {[string]: unknown}).checksum, checksum)
            local database = (facts.databases :: {[string]: unknown})["demo:db"] :: {[string]: unknown}
            test.eq(database.database_id, "demo:db")
            test.is_nil(database.table_prefix)
            assert(store.close(state))
        end)
        test.it("reverts one applied generation and retains the compensating migration", function()
            local state, open_error = store.open("bee.gov:activation_test_db", "node-a", "workspace-rollback")
            if not state then error(tostring(open_error)) end
            local function apply_generation(intent_id: string, version: string, artifact: string): {[string]: unknown}
                local input = prepare()
                input.intent_id, input.idempotency_key, input.version = intent_id, intent_id .. "-prepare", version
                input.artifact = blob(artifact)
                local prepared = ok(store.call(state, "actor-a", input))
                ok(store.call(state, "actor-a", {operation = "bind_approval", intent_id = intent_id,
                    expected_revision = prepared.revision, idempotency_key = intent_id .. "-bind",
                    approval_id = "approval-" .. intent_id, approval_proposal_digest = string.rep("d", 64),
                    approval_owner_incarnation = 1}))
                ok(store.call(state, "actor-a", {operation = "begin_consume", intent_id = intent_id,
                    expected_revision = 2, idempotency_key = intent_id .. "-consume"}))
                local authorized = ok(store.call(state, "actor-a", {operation = "record_consumption", intent_id = intent_id,
                    expected_revision = 3, idempotency_key = intent_id .. "-record", consumer_id = "host",
                    proposal_digest = string.rep("d", 64), effect_key = prepared.effect_key}))
                local applying = ok(store.call(state, "actor-a", {operation = "begin_apply", intent_id = intent_id,
                    expected_revision = authorized.revision, idempotency_key = intent_id .. "-apply"}))
                return ok(store.call(state, "actor-a", {operation = "record_outcome", intent_id = intent_id,
                    expected_revision = applying.revision, idempotency_key = intent_id .. "-applied",
                    outcome = "applied", diagnostics = version .. " applied"}))
            end
            apply_generation("intent-gen-1", "v1", "artifact-v1")
            local second = apply_generation("intent-gen-2", "v2", "artifact-v2")
            test.eq(second.observed_intent_id, "intent-gen-2")
            local baseline = ok(store.baseline(state, "bee.gov:overlay"))
            test.eq(baseline.intent_id, "intent-gen-1")
            test.eq(baseline.artifact_digest, blob("artifact-v1").digest)
            local compensation = blob(assert(canonical.encode({schema_revision = "bee.governance-migration-receipt@1",
                rows = {{id = "demo:001", target_db = "demo:db", module = "demo/app", status = "applied"}}})))
            local reverted = ok(store.call(state, "actor-a", {operation = "revert_activation",
                overlay_owner = "bee.gov:overlay", expected_revision = second.slot_revision,
                idempotency_key = "rollback-1", compensation = compensation, diagnostics = "boot failed on v2"}))
            test.eq(reverted.intent_id, "intent-gen-1")
            test.eq(reverted.desired_intent_id, "intent-gen-1")
            test.eq(reverted.observed_intent_id, nil)
            test.eq(reverted.reverted_from_intent_id, "intent-gen-2")
            test.eq(reverted.compensation_digest, compensation.digest)
            local replayed = ok(store.call(state, "actor-a", {operation = "revert_activation",
                overlay_owner = "bee.gov:overlay", expected_revision = second.slot_revision,
                idempotency_key = "rollback-1", compensation = compensation, diagnostics = "boot failed on v2"}))
            test.eq(replayed.reverted_from_intent_id, "intent-gen-2")
            assert(store.close(state))
        end)
        test.it("refuses a revert without a retained baseline generation", function()
            local state = assert(store.open("bee.gov:activation_test_db", "node-a", "workspace-rollback-empty"))
            local input = prepare()
            input.intent_id, input.idempotency_key = "intent-only", "only-prepare"
            local prepared = ok(store.call(state, "actor-a", input))
            ok(store.call(state, "actor-a", {operation = "bind_approval", intent_id = "intent-only",
                expected_revision = prepared.revision, idempotency_key = "only-bind",
                approval_id = "approval-only", approval_proposal_digest = string.rep("d", 64),
                approval_owner_incarnation = 1}))
            ok(store.call(state, "actor-a", {operation = "begin_consume", intent_id = "intent-only",
                expected_revision = 2, idempotency_key = "only-consume"}))
            local authorized = ok(store.call(state, "actor-a", {operation = "record_consumption", intent_id = "intent-only",
                expected_revision = 3, idempotency_key = "only-record", consumer_id = "host",
                proposal_digest = string.rep("d", 64), effect_key = prepared.effect_key}))
            local applying = ok(store.call(state, "actor-a", {operation = "begin_apply", intent_id = "intent-only",
                expected_revision = authorized.revision, idempotency_key = "only-apply"}))
            local applied = ok(store.call(state, "actor-a", {operation = "record_outcome", intent_id = "intent-only",
                expected_revision = applying.revision, idempotency_key = "only-applied", outcome = "applied",
                diagnostics = "first and only generation"}))
            test.eq(store.baseline(state, "bee.gov:overlay").code, "NOT_FOUND")
            local refused = store.call(state, "actor-a", {operation = "revert_activation",
                overlay_owner = "bee.gov:overlay", expected_revision = applied.slot_revision,
                idempotency_key = "rollback-none", compensation = blob("none"), diagnostics = "nothing to revert to"})
            test.eq(refused.code, "CONFLICT")
            assert(store.close(state))
        end)
    end)
end
return test.run_cases(define_tests)
