-- MIT. Destination-owner orchestration for one reviewed overlay version.
-- Remote publication and Sync can make bytes available; only this local owner
-- can measure them, request approval and establish its configured overlay.
local bounds = require("bounds")
local transaction = require("transaction")
local plans = require("plan_store")
local activations = require("activation_store")
local measure = require("activation_measure")
local approval = require("approval")
local preflight = require("preflight")
local json = require("json")
local migration_work = require("migration_work")
local artifact = require("artifact")
local application_admission = require("application_admission")

local M = {}
type Object = {[string]: unknown}
type Result = transaction.Result
type Resolver = {resolve: (Resolver, unknown) -> (preflight.Candidate?, preflight.Context?, string?)}
type Executor = approval.Executor
type Apply = (string, unknown, unknown?, unknown) -> ({[string]: unknown}?, string?)
type Observe = (string, unknown, unknown?, unknown) -> (boolean?, string?)
type Config = {plans: plans.Store, activations: activations.Store, resolver: Resolver,
    approvals: Executor, actor_id: string, consumer_id: string, overlay_owner: string,
    approval_policy: string, apply: Apply, matches: Observe, migrations: any}

local function failure(code: string, message: string, value: unknown?): Result
    return transaction.failure(code, message, value)
end

local function object(value: unknown): Object?
    return bounds.object(value)
end

local function key(prefix: string, operation: string): string?
    return bounds.id(prefix .. ":" .. operation)
end

local function configuration(raw: Config): (Config?, string?)
    if type(raw) ~= "table" then return nil, "activation owner dependencies are invalid" end
    local approval_kind = type(raw.approvals)
    if type(raw.resolver) ~= "table" or type(raw.resolver.resolve) ~= "function"
        or (approval_kind ~= "table" and approval_kind ~= "userdata") or type(raw.approvals.call) ~= "function"
        or type(raw.apply) ~= "function" or type(raw.matches) ~= "function" or type(raw.migrations) ~= "table"
        or type(raw.migrations.matches) ~= "function" or type(raw.migrations.prepare) ~= "function"
        or type(raw.migrations.clear) ~= "function" or type(raw.migrations.cleared) ~= "function"
        or type(raw.migrations.execute) ~= "function" then
        return nil, "activation owner dependencies are invalid"
    end
    if not bounds.id(raw.actor_id) or not bounds.id(raw.consumer_id)
        or not bounds.id(raw.overlay_owner) or not bounds.id(raw.approval_policy) then
        return nil, "activation owner identity is invalid"
    end
    return raw, nil
end

local function selected(config: Config, identity: Object): (Object?, Result?)
    local found = plans.call(config.plans, config.actor_id, {operation = "get",
        source_node = identity.source_node, source_workspace = identity.source_workspace,
        version = identity.version})
    if not found.ok then return nil, found end
    local plan = object(found.value)
    if not plan then return nil, failure("INTERNAL", "plan store returned no selected plan") end
    if plan.selected ~= true or plan.review_status ~= "accepted" then
        return nil, failure("CONFLICT", "activation requires the current accepted selection")
    end
    return plan, nil
end

local function approved_spec(intent: Object): Object
    return {owner_node = intent.owner_node, workspace_id = intent.workspace_id,
        source_node = intent.source_node, source_workspace = intent.source_workspace,
        version = intent.version, plan_digest = intent.plan_digest,
        revision = intent.plan_revision, selection_revision = intent.selection_revision,
        selected = true, review_status = "accepted", artifact_bytes = intent.artifact_bytes,
        artifact_digest = intent.artifact_digest}
end

local function measured(config: Config, spec: Object): (Object?, Result?)
    local candidate, context, resolve_error = config.resolver:resolve(spec)
    if candidate == nil or context == nil then
        return nil, failure("BLOCKED", tostring(resolve_error or "resolve activation on this node"))
    end
    local result, measurement_error = measure.measure(spec, candidate, context)
    if not result then return nil, failure("BLOCKED", tostring(measurement_error)) end
    return result, nil
end

local function admission_owner(config: Config, facts: Object): Result?
    local admission = object(facts.application_admission)
    if not admission then return nil end
    local record = object(admission.record)
    if not record or record.overlay_owner ~= config.overlay_owner then
        return failure("CONFLICT", "application admission does not match the activation overlay owner")
    end
    return nil
end

-- Effects replay from durable intent, never from a newly resolved candidate.
-- The optional admission record is decoded independently from the portable
-- artifact and checked against every identity that ties it to this owner.
local function desired_intent(config: Config, intent: Object): ({unknown}?, Object?, Result?)
    local entries, artifact_error = artifact.decode(intent.artifact_bytes, intent.artifact_digest)
    if not entries then return nil, nil, failure("CONFLICT", tostring(artifact_error or "decode immutable artifact")) end
    for _, entry in ipairs(entries) do
        if application_admission.reserved(entry.id) then
            return nil, nil, failure("CONFLICT", "portable artifact entry uses a reserved application admission identity")
        end
    end
    local bytes, digest = intent.application_admission_bytes, intent.application_admission_digest
    if bytes == nil and digest == nil then return entries :: {unknown}, nil, nil end
    if type(bytes) ~= "string" or type(digest) ~= "string" then
        return nil, nil, failure("CONFLICT", "immutable application admission blob is incomplete")
    end
    local measured, admission_error = application_admission.decode(bytes, digest)
    if not measured then return nil, nil, failure("CONFLICT", tostring(admission_error)) end
    local record = measured.record
    if record.workspace_id ~= intent.workspace_id or record.overlay_owner ~= config.overlay_owner
        or record.overlay_owner ~= intent.overlay_owner or record.source_node ~= intent.source_node
        or record.source_workspace ~= intent.source_workspace or record.artifact_digest ~= intent.artifact_digest then
        return nil, nil, failure("CONFLICT", "immutable application admission does not match activation identity")
    end
    return entries :: {unknown}, {bytes = measured.bytes, digest = measured.digest}, nil
end

local function composed_base_diagnostic(intent: Object, current: Object): string?
    local prior = type(intent.resolution_bytes) == "string"
        and object(json.decode(intent.resolution_bytes :: string)) or nil
    local next_candidate = type(current.candidate) == "table" and (current.candidate :: Object) or nil
    local before = prior and prior.base_digest or nil
    local after = next_candidate and next_candidate.base_digest or nil
    if type(before) == "string" and type(after) == "string" and before ~= after then
        return "composed registry base changed since review; prepare again against the current composed registry"
    end
    return nil
end

local function unchanged(intent: Object, current: Object): Result?
    local fields = {"owner_node", "workspace_id", "source_node", "source_workspace", "version",
        "plan_digest", "artifact_digest", "resolution_digest", "preflight_digest", "migration_work_digest",
        "application_admission_digest", "grant_predecessor_digest"}
    for _, field in ipairs(fields) do
        if intent[field] ~= current[field] then
            if field == "resolution_digest" then
                local named = composed_base_diagnostic(intent, current)
                if named then return failure("CONFLICT", named) end
                local prior = type(intent.resolution_bytes) == "string"
                    and object(json.decode(intent.resolution_bytes :: string)) or nil
                local next_candidate = type(current.candidate) == "table" and (current.candidate :: Object) or nil
                if prior and next_candidate then
                    for _, candidate_field in ipairs({"destination_node", "source_node", "base_revision", "base_digest"}) do
                        if prior[candidate_field] ~= next_candidate[candidate_field] then
                            return failure("CONFLICT", "activation resolution changed: " .. candidate_field)
                        end
                    end
                end
            end
            return failure("CONFLICT", "activation measurement changed: " .. field)
        end
    end
    if intent.plan_revision ~= current.plan_revision
        or intent.selection_revision ~= current.selection_revision then
        return failure("CONFLICT", "selected plan changed before activation")
    end
    return nil
end

local function status(config: Config, intent_id: unknown): (Object?, Result?)
    local result = activations.get(config.activations, intent_id)
    if not result.ok then return nil, result end
    local intent = object(result.value)
    if not intent then return nil, failure("INTERNAL", "activation store returned no intent") end
    return intent, nil
end

local function require_desired(config: Config, intent: Object): Result?
    local current = activations.desired(config.activations, intent.overlay_owner)
    if not current.ok then return current end
    local desired = object(current.value)
    if not desired then return failure("INTERNAL", "activation store returned no desired intent") end
    if desired.intent_id ~= intent.intent_id then
        return failure("CONFLICT", "activation is no longer the desired slot")
    end
    return nil
end

-- Prepare performs local resolution and measurement before it creates an
-- approval request. It never consumes the decision or changes the registry.
function M.prepare(raw_config: Config, raw: unknown): Result
    local config, config_error = configuration(raw_config)
    local request = object(raw)
    if not config or not request then return failure("INVALID", config_error or "activation request is invalid") end
    local extra = bounds.fields(request, {"source_node", "source_workspace", "version", "intent_id", "receipt_key"})
    local identity: Object = {source_node = bounds.id(request.source_node),
        source_workspace = bounds.id(request.source_workspace), version = bounds.id(request.version)}
    local intent_id, prefix = bounds.id(request.intent_id), bounds.id(request.receipt_key)
    if extra or not identity.source_node or not identity.source_workspace or not identity.version
        or not intent_id or not prefix then return failure("INVALID", extra or "activation identity is invalid") end
    local prepare_key, request_key, bind_key = key(prefix, "prepare"), key(prefix, "request"), key(prefix, "bind")
    if not prepare_key or not request_key or not bind_key then return failure("INVALID", "activation receipt_key is too long") end
    local plan, plan_error = selected(config, identity)
    if not plan then return plan_error :: Result end
    local facts, facts_error = measured(config, plan)
    if not facts then return facts_error :: Result end
    local admission_error = admission_owner(config, facts)
    if admission_error then return admission_error end
    local prepared = activations.call(config.activations, config.actor_id, {operation = "prepare_activation",
        intent_id = intent_id, expected_revision = 0, idempotency_key = prepare_key,
        overlay_owner = config.overlay_owner, source_node = facts.source_node,
        source_workspace = facts.source_workspace, version = facts.version,
        plan_digest = facts.plan_digest, plan_revision = facts.plan_revision,
        selection_revision = facts.selection_revision, artifact = facts.artifact,
        resolution = facts.resolution, preflight = facts.preflight,
        migration_work = facts.migration_work, application_admission = facts.application_admission,
        grant_predecessor_digest = facts.grant_predecessor_digest})
    if not prepared.ok then return prepared end
    local intent = object(prepared.value)
    if not intent then return failure("INTERNAL", "activation store returned no prepared intent") end
    if intent.phase ~= "prepared" then return prepared end
    local review = object(facts.capability_review)
    local installed = object(facts.capability_installed)
    if review and review.requires_approval == false and installed then
        local prior_digest = bounds.text(installed.record_digest, 64)
        local prior_approval = bounds.id(installed.approval_id)
        if not prior_digest or not prior_approval then
            return failure("CONFLICT", "installed grant cannot authorize reuse")
        end
        local bound = activations.call(config.activations, config.actor_id, {operation = "bind_approval",
            intent_id = intent_id, expected_revision = intent.revision, idempotency_key = bind_key,
            approval_id = prior_approval, approval_proposal_digest = prior_digest,
            approval_owner_incarnation = 1, grant_reuse_digest = prior_digest})
        if not bound.ok then return bound end
        local linked = object(bound.value)
        if not linked then return failure("INTERNAL", "grant reuse has no bound intent") end
        local consume_key = key(prefix, "reuse-start")
        local record_key = key(prefix, "reuse-record")
        if not consume_key or not record_key then return failure("INVALID", "activation receipt_key is too long") end
        local started = activations.call(config.activations, config.actor_id, {operation = "begin_consume",
            intent_id = intent_id, expected_revision = linked.revision, idempotency_key = consume_key})
        if not started.ok then return started end
        local consuming = object(started.value)
        if not consuming then return failure("INTERNAL", "grant reuse has no consuming intent") end
        return activations.call(config.activations, config.actor_id, {operation = "record_consumption",
            intent_id = intent_id, expected_revision = consuming.revision, idempotency_key = record_key,
            consumer_id = "bee.governance.grant_reuse", proposal_digest = prior_digest,
            effect_key = consuming.effect_key})
    end
    local bound, approval_error = approval.request_activation(config.approvals, intent,
        config.approval_policy, request_key, review)
    if not bound then return failure("APPROVAL", tostring(approval_error)) end
    return activations.call(config.activations, config.actor_id, {operation = "bind_approval",
        intent_id = intent_id, expected_revision = intent.revision, idempotency_key = bind_key,
        approval_id = bound.approval_id, approval_proposal_digest = bound.approval_proposal_digest,
        approval_owner_incarnation = bound.owner_incarnation})
end

local function remeasure_selected(config: Config, intent: Object): Result?
    local plan, plan_error = selected(config, intent)
    if not plan then return plan_error :: Result end
    local current, measurement_error = measured(config, plan)
    if not current then return measurement_error :: Result end
    local admission_error = admission_owner(config, current)
    if admission_error then return admission_error end
    return unchanged(intent, current)
end

local function remeasure_authorized(config: Config, intent: Object): (Object?, Result?)
    local current, measurement_error = measured(config, approved_spec(intent))
    if not current then return nil, measurement_error end
    local admission_error = admission_owner(config, current)
    if admission_error then return nil, admission_error end
    local changed = unchanged(intent, current)
    if changed then return nil, changed end
    return current, nil
end

-- Once migration execution starts, the approved pending set is expected to
-- shrink.  The exact artifact and composed candidate must remain unchanged;
-- preflight independently refuses changed/removed applied definitions.
local function remeasure_progress(config: Config, intent: Object): (Object?, Result?)
    local current, measurement_error = measured(config, approved_spec(intent))
    if not current then return nil, measurement_error end
    local admission_error = admission_owner(config, current)
    if admission_error then return nil, admission_error end
    for _, field in ipairs({"owner_node", "workspace_id", "source_node", "source_workspace", "version",
        "plan_digest", "artifact_digest", "resolution_digest", "application_admission_digest"}) do
        if intent[field] ~= current[field] then
            if field == "resolution_digest" then
                local named = composed_base_diagnostic(intent, current)
                if named then return nil, failure("CONFLICT", named) end
            end
            return nil, failure("CONFLICT", "activation measurement changed during migration: " .. field)
        end
    end
    if intent.plan_revision ~= current.plan_revision or intent.selection_revision ~= current.selection_revision then
        return nil, failure("CONFLICT", "selected plan changed during migration")
    end
    local current_blob = object(current.migration_work)
    local prior_work, prior_error = migration_work.decode(intent.migration_work_bytes, intent.migration_work_digest)
    local current_work, current_error = migration_work.decode(current_blob and current_blob.bytes,
        current_blob and current_blob.digest)
    if not prior_work or not current_work then
        return nil, failure("INTERNAL", tostring(prior_error or current_error or "decode migration policy measurement"))
    end
    if prior_work.policy_digest ~= current_work.policy_digest then
        return nil, failure("CONFLICT", "activation database policy changed during migration")
    end
    return current, nil
end

-- One step performs at most one durable transition around an external effect.
-- Calling it again after interruption resumes from the stored phase.
function M.step(raw_config: Config, intent_raw: unknown, receipt_raw: unknown): Result
    local config, config_error = configuration(raw_config)
    local intent_id, prefix = bounds.id(intent_raw), bounds.id(receipt_raw)
    if not config or not intent_id or not prefix then return failure("INVALID", config_error or "activation resume identity is invalid") end
    local intent, status_error = status(config, intent_id)
    if not intent then return status_error :: Result end
    if intent.overlay_owner ~= config.overlay_owner then return failure("DENIED", "activation belongs to another overlay owner") end

    if intent.phase == "approval_bound" then
        local changed = remeasure_selected(config, intent)
        if changed then return changed end
        local operation_key = key(prefix, "consume-start")
        if not operation_key then return failure("INVALID", "activation receipt key is too long") end
        return activations.call(config.activations, config.actor_id, {operation = "begin_consume",
            intent_id = intent_id, expected_revision = intent.revision, idempotency_key = operation_key})
    end

    if intent.phase == "consuming" then
        if intent.grant_reuse_digest ~= nil then
            local current, current_error = remeasure_authorized(config, intent)
            if not current then return current_error :: Result end
            local installed = object(current.capability_installed)
            if not installed or installed.record_digest ~= intent.grant_reuse_digest
                or installed.approval_id ~= intent.approval_id then
                return failure("CONFLICT", "installed grant changed before reuse")
            end
            local reuse_key = key(prefix, "reuse-record")
            if not reuse_key then return failure("INVALID", "activation receipt key is too long") end
            return activations.call(config.activations, config.actor_id, {operation = "record_consumption",
                intent_id = intent_id, expected_revision = intent.revision, idempotency_key = reuse_key,
                consumer_id = "bee.governance.grant_reuse",
                proposal_digest = installed.record_digest, effect_key = intent.effect_key})
        end
        -- begin_consume was written only after the last current-selection
        -- check. From here the exact effect may already have happened, so
        -- recovery must replay/reconcile it before consulting newer plans.
        local consumed, consume_error = approval.consume_activation(config.approvals, intent, config.consumer_id)
        if not consumed and consume_error and consume_error.code == "REVALIDATE" then
            local value = object(consume_error.value)
            local incarnation = value and bounds.count(value.current_incarnation) or nil
            if incarnation and incarnation > 0 then
                local validated, validation_error = approval.revalidate_activation(config.approvals, intent, incarnation)
                if validated then
                    consumed, consume_error = approval.consume_activation(config.approvals, intent,
                        config.consumer_id, incarnation)
                else
                    consume_error = validation_error
                end
            end
        end
        if not consumed then
            return failure(consume_error and consume_error.code or "APPROVAL",
                consume_error and consume_error.message or "consume activation approval",
                consume_error and consume_error.value or nil)
        end
        local operation_key = key(prefix, "consume-record")
        if not operation_key then return failure("INVALID", "activation receipt key is too long") end
        return activations.call(config.activations, config.actor_id, {operation = "record_consumption",
            intent_id = intent_id, expected_revision = intent.revision, idempotency_key = operation_key,
            consumer_id = consumed.consumer_id, proposal_digest = consumed.proposal_digest,
            effect_key = consumed.consumed_effect})
    end

    if intent.phase == "authorized" then
        local current, measurement_error = remeasure_authorized(config, intent)
        if not current then return measurement_error :: Result end
        if intent.grant_reuse_digest ~= nil then
            local installed = object(current.capability_installed)
            if not installed or installed.record_digest ~= intent.grant_reuse_digest then
                return failure("CONFLICT", "installed grant changed before no-widen activation")
            end
        end
        local operation_key = key(prefix, "apply-start")
        if not operation_key then return failure("INVALID", "activation receipt key is too long") end
        return activations.call(config.activations, config.actor_id, {operation = "begin_apply",
            intent_id = intent_id, expected_revision = intent.revision, idempotency_key = operation_key})
    end

    if intent.phase == "applying" or (intent.phase == "settled" and intent.outcome == "uncertain") then
        local superseded = require_desired(config, intent)
        if superseded then return superseded end
        local work, work_error = migration_work.decode(intent.migration_work_bytes, intent.migration_work_digest)
        if not work then return failure("INTERNAL", tostring(work_error or "decode activation migration work")) end
        if intent.migrations_completed ~= true then
            local staged, staged_error = config.migrations.matches(config.overlay_owner, work)
            if staged == nil then return failure("UNAVAILABLE", tostring(staged_error)) end
            local cleared, cleared_error = config.migrations.cleared(config.overlay_owner)
            if cleared == nil then return failure("UNAVAILABLE", tostring(cleared_error)) end
            if staged or not cleared then
                local removed, remove_error = config.migrations.clear(config.overlay_owner)
                if not removed then return failure("UNCERTAIN", tostring(remove_error or "clear migration prerequisites")) end
                local observed, observe_error = config.migrations.cleared(config.overlay_owner)
                if observed ~= true then return failure("UNCERTAIN", tostring(observe_error or "migration prerequisite cleanup is not observable")) end
                local result: Object = {}
                for field, value in pairs(intent) do result[field] = value end
                result.recovered = true
                result.diagnostics = "migration prerequisites cleared before recovery"
                return transaction.success(result, false)
            end
            local _, measurement_error = remeasure_progress(config, intent)
            if measurement_error then return measurement_error end
            local prepared, prepare_error = config.migrations.prepare(config.overlay_owner, work)
            if not prepared then return failure("UNCERTAIN", tostring(prepare_error or "prepare migration definitions")) end
            local exact, exact_error = config.migrations.matches(config.overlay_owner, work)
            if exact ~= true then return failure("UNCERTAIN", tostring(exact_error or "migration definitions are not exactly staged")) end
            local receipt, complete, execute_error = config.migrations.execute(work)
            if not receipt then return failure("UNCERTAIN", tostring(execute_error or "execute captured migrations")) end
            local operation_key = key(prefix, "migrations-" .. tostring(intent.revision))
            if not operation_key then return failure("INVALID", "activation receipt key is too long") end
            local recorded = activations.call(config.activations, config.actor_id, {operation = "record_migrations",
                intent_id = intent_id, expected_revision = intent.revision, idempotency_key = operation_key,
                receipt = receipt, complete = complete, diagnostics = execute_error or "captured migrations ledger-confirmed"})
            if not recorded.ok then return recorded end
            if not complete then return failure("UNCERTAIN", tostring(execute_error or "migration execution is incomplete"), object(recorded.value)) end
            return recorded
        end
        local cleared, cleanup_error = config.migrations.cleared(config.overlay_owner)
        if cleared == nil then return failure("UNAVAILABLE", tostring(cleanup_error)) end
        if not cleared then
            local removed, remove_error = config.migrations.clear(config.overlay_owner)
            if not removed then return failure("UNCERTAIN", tostring(remove_error or "clear migration prerequisites")) end
            local observed, observe_error = config.migrations.cleared(config.overlay_owner)
            if observed ~= true then return failure("UNCERTAIN", tostring(observe_error or "migration prerequisite cleanup is not observable")) end
            local result: Object = {}
            for field, value in pairs(intent) do result[field] = value end
            result.recovered = true
            result.diagnostics = "migration prerequisites cleared"
            return transaction.success(result, false)
        end
        local spec, measurement_error = remeasure_progress(config, intent)
        if not spec then return measurement_error :: Result end
        local desired_entries, desired_admission, desired_error = desired_intent(config, intent)
        if not desired_entries then return desired_error :: Result end
        local function uncertain(diagnostics: string): Result
            local outcome_key = key(prefix, "outcome-uncertain-" .. tostring(intent.revision))
            if not outcome_key then return failure("INVALID", "activation receipt key is too long") end
            local recorded = activations.call(config.activations, config.actor_id, {operation = "record_outcome",
                intent_id = intent_id, expected_revision = intent.revision, idempotency_key = outcome_key,
                outcome = "uncertain", diagnostics = diagnostics})
            if not recorded.ok then return recorded end
            return failure("UNCERTAIN", diagnostics, object(recorded.value))
        end
        local matches, observe_error = config.matches(config.overlay_owner, desired_entries, desired_admission, intent)
        if matches == nil then return failure("UNAVAILABLE", tostring(observe_error)) end
        if not matches then
            local applied, apply_error = config.apply(config.overlay_owner, desired_entries, desired_admission, intent)
            if not applied then return uncertain(tostring(apply_error)) end
            local observed, applied_observe_error = config.matches(config.overlay_owner, desired_entries, desired_admission, intent)
            if observed ~= true then
                return uncertain(observed == nil and tostring(applied_observe_error)
                    or "overlay apply completed without an exact observed match")
            end
            local reverified, reverify_error = remeasure_progress(config, intent)
            if not reverified then
                return uncertain(tostring((reverify_error :: Result).message
                    or "activation apply could not be remeasured against the current composed registry"))
            end
            if reverified.resolution_digest ~= spec.resolution_digest then
                local named = composed_base_diagnostic(intent, reverified)
                return uncertain(named or "activation measurement changed during apply; prepare again against the current composed registry")
            end
        end
        local outcome_key = key(prefix, "outcome-applied-" .. tostring(intent.revision))
        if not outcome_key then return failure("INVALID", "activation receipt key is too long") end
        return activations.call(config.activations, config.actor_id, {operation = "record_outcome",
            intent_id = intent_id, expected_revision = intent.revision, idempotency_key = outcome_key,
            outcome = "applied", diagnostics = "exact overlay observed"})
    end

    if intent.phase == "settled" and intent.outcome == "applied" then
        local superseded = require_desired(config, intent)
        if superseded then return superseded end
        local _, measurement_error = remeasure_progress(config, intent)
        if measurement_error then return measurement_error end
        local desired_entries, desired_admission, desired_error = desired_intent(config, intent)
        if not desired_entries then return desired_error :: Result end
        local matches, observe_error = config.matches(config.overlay_owner, desired_entries, desired_admission, intent)
        if matches == nil then return failure("UNAVAILABLE", tostring(observe_error)) end
        if matches then return transaction.success(intent, true) end
        local restored, restore_error = config.apply(config.overlay_owner, desired_entries, desired_admission, intent)
        if restored then
            local result: Object = {}
            for field, value in pairs(intent) do result[field] = value end
            result.recovered = true
            return transaction.success(result, false)
        end
        -- A settled activation may drift more than once during its lifetime.
        -- Fence each recovery observation by the execution revision while
        -- keeping retries of that same observation idempotent.
        local outcome_key = key(prefix, "recovery-uncertain-" .. tostring(intent.revision))
        if not outcome_key then return failure("INVALID", "activation receipt key is too long") end
        local recorded = activations.call(config.activations, config.actor_id, {operation = "record_outcome",
            intent_id = intent_id, expected_revision = intent.revision, idempotency_key = outcome_key,
            outcome = "uncertain", diagnostics = tostring(restore_error)})
        if not recorded.ok then return recorded end
        return failure("UNCERTAIN", tostring(restore_error), object(recorded.value))
    end

    return transaction.success(intent, true)
end

function M.desired(raw_config: Config): Result
    local config, config_error = configuration(raw_config)
    if not config then return failure("INVALID", config_error or "activation owner configuration is invalid") end
    return activations.desired(config.activations, config.overlay_owner)
end

function M.recover(raw_config: Config, receipt_raw: unknown): Result
    local config, config_error = configuration(raw_config)
    local prefix = bounds.id(receipt_raw)
    if not config or not prefix then return failure("INVALID", config_error or "activation recovery identity is invalid") end
    local desired = activations.desired(config.activations, config.overlay_owner)
    if not desired.ok then return desired end
    local intent = object(desired.value)
    if not intent then return failure("INTERNAL", "activation store returned no desired intent") end
    return M.step(config, intent.intent_id, prefix)
end

return M
