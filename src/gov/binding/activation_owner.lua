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
local lease_store = require("lease_store")
local resolution = require("resolution")

local M = {}
local LEASE_CONSUMER = "bee.gov.lease_apply"
type Object = {[string]: unknown}
type Result = transaction.Result
type Resolver = resolution.Resolver
type Executor = approval.Executor
type Apply = (string, unknown, unknown?, unknown) -> ({[string]: unknown}?, string?)
type Observe = (string, unknown, unknown?, unknown) -> (boolean?, string?)
-- Migration effects receive the intent so the destination can stage what
-- the intent's grants provision for the migrations: the application database
-- and the grant that lets its migrations reach it.
type MigrationEffects = {
    matches: (string, migration_work.Work, unknown) -> (boolean?, string?),
    prepare: (string, migration_work.Work, unknown) -> ({[string]: unknown}?, string?),
    clear: (string) -> ({[string]: unknown}?, string?),
    cleared: (string) -> (boolean?, string?),
    execute: (migration_work.Work, unknown) -> ({bytes: string, digest: string}?, boolean, string?)}
type Config = {plans: plans.Store, activations: activations.Store, resolver: Resolver,
    approvals: Executor, actor_id: string, consumer_id: string, overlay_owner: string,
    approval_policy: string, apply: Apply, matches: Observe, migrations: MigrationEffects,
    leases: lease_store.Store?}

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
    -- A refusal means the host no longer admits what was approved.
    local result, measurement_error, refused = measure.measure(spec, candidate, context)
    if not result then return nil, failure(refused and "CONFLICT" or "BLOCKED", tostring(measurement_error)) end
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
    if bytes == nil and digest == nil then return entries, nil, nil end
    if type(bytes) ~= "string" or type(digest) ~= "string" then
        return nil, nil, failure("CONFLICT", "immutable application admission blob is incomplete")
    end
    local measured, admission_error = application_admission.decode(bytes, digest, intent.application_admission_generation)
    if not measured then return nil, nil, failure("CONFLICT", tostring(admission_error)) end
    local record = measured.record
    if record.workspace_id ~= intent.workspace_id or record.overlay_owner ~= config.overlay_owner
        or record.overlay_owner ~= intent.overlay_owner or record.source_node ~= intent.source_node
        or record.source_workspace ~= intent.source_workspace or record.artifact_digest ~= intent.artifact_digest then
        return nil, nil, failure("CONFLICT", "immutable application admission does not match activation identity")
    end
    return entries, {bytes = measured.bytes, digest = measured.digest, identity_generation = intent.application_admission_generation}, nil
end

local function composed_base_diagnostic(intent: Object, current: Object): string?
    local prior = type(intent.resolution_bytes) == "string"
        and object(json.decode(intent.resolution_bytes)) or nil
    local next_candidate = type(current.candidate) == "table" and (current.candidate) or nil
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
                    and object(json.decode(intent.resolution_bytes)) or nil
                local next_candidate = type(current.candidate) == "table" and (current.candidate) or nil
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

-- What the person installs, as they know it: the application's own title, and
-- the node that shared it when another node made it.
local function presentation(config: Config, intent: Object, plan: Object): approval.Presentation
    local shown: approval.Presentation = {title = nil, maker = nil, tools = {}}
    local entries = artifact.decode(intent.artifact_bytes, intent.artifact_digest)
    for _, raw in ipairs(entries or {}) do
        local entry = object(raw)
        local meta = entry and object(entry.meta) or nil
        local id = entry and bounds.id(entry.id) or nil
        local alias = meta and meta.type == "tool" and bounds.line(meta.llm_alias, 80) or nil
        if id and alias and shown.tools then shown.tools[id] = alias end
        local declared = meta and meta.type == "bee.app" and object(meta.application) or nil
        local title = declared and bounds.line(declared.title, 80) or nil
        if title and title ~= "" then shown.title = title end
    end
    -- The person reads who made the version and, when another bee sent it,
    -- which one.
    local author = bounds.line(plan.author, 80)
    local source = bounds.id(intent.source_node)
    local made = author and author ~= "" and ("made by " .. author) or nil
    local place = source and source ~= config.activations.node and ("from bee " .. source) or "this bee"
    shown.maker = made and (made .. " · " .. place) or place
    return shown
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
    if not plan then return plan_error end
    local facts, facts_error = measured(config, plan)
    if not facts then return facts_error end
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
    -- Migrations change the database for good, so a version that runs any
    -- always asks the person, even when its grants are already approved.
    local work, work_error = migration_work.decode(intent.migration_work_bytes, intent.migration_work_digest)
    if not work then return failure("INTERNAL", tostring(work_error or "decode activation migration work")) end
    local pending: {approval.Migration} = {}
    for _, item in ipairs(work.migrations) do pending[#pending + 1] = {id = item.id, target_db = item.target_db} end
    if review and review.requires_approval == false and installed and #pending == 0 then
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
            consumer_id = "bee.gov.grant_reuse", proposal_digest = prior_digest,
            effect_key = consuming.effect_key})
    end
    local proposal = object(facts.capability_proposal)
    if review and review.requires_approval == true and installed and proposal and config.leases and #pending == 0 then
        local proposed = bounds.dense_list(proposal.capabilities, bounds.MAX_ARRAY_ITEMS, "capabilities")
        if not proposed then return failure("INVALID", "capability proposal is invalid") end
        local lease = lease_store.find_active(config.leases, config.overlay_owner, proposed)
        local lease_key = key(prefix, "lease-authorize")
        if lease and lease_key then
            -- The use, its proof and the intent's authorization commit together.
            -- A refusal leaves the intent prepared and falls to a person.
            local authorized = activations.call(config.activations, config.actor_id, {operation = "authorize_lease",
                intent_id = intent_id, expected_revision = intent.revision, idempotency_key = lease_key,
                lease_id = lease.lease_id, lease_expected_revision = lease.revision, proposal_capabilities = proposed})
            if authorized.ok then return authorized end
        end
    end
    local bound, approval_error = approval.request_activation(config.approvals, intent,
        config.approval_policy, request_key, review, pending, presentation(config, intent, plan))
    if not bound then return failure("APPROVAL", tostring(approval_error)) end
    return activations.call(config.activations, config.actor_id, {operation = "bind_approval",
        intent_id = intent_id, expected_revision = intent.revision, idempotency_key = bind_key,
        approval_id = bound.approval_id, approval_proposal_digest = bound.approval_proposal_digest,
        approval_owner_incarnation = bound.owner_incarnation})
end

local function remeasure_selected(config: Config, intent: Object): Result?
    local plan, plan_error = selected(config, intent)
    if not plan then return plan_error end
    local current, measurement_error = measured(config, plan)
    if not current then return measurement_error end
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
local function remeasure_migration_policy(intent: Object, current: Object, invalid_label: string,
    changed_message: string): Result?
    local current_blob = object(current.migration_work)
    local prior_work, prior_error = migration_work.decode(intent.migration_work_bytes, intent.migration_work_digest)
    local current_work, current_error = migration_work.decode(current_blob and current_blob.bytes,
        current_blob and current_blob.digest)
    if not prior_work or not current_work then
        return failure("INTERNAL", tostring(prior_error or current_error or invalid_label))
    end
    if prior_work.policy_digest ~= current_work.policy_digest then
        return failure("CONFLICT", changed_message)
    end
    return nil
end

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
    local migration_error = remeasure_migration_policy(intent, current, "decode migration policy measurement",
        "activation database policy changed during migration")
    if migration_error then return nil, migration_error end
    return current, nil
end

local function remeasure_restoration(config: Config, intent: Object): Result?
    local current, measurement_error = measured(config, approved_spec(intent))
    if not current then return measurement_error end
    local admission_error = admission_owner(config, current)
    if admission_error then return admission_error end
    for _, field in ipairs({"owner_node", "workspace_id", "source_node", "source_workspace", "version",
        "plan_digest", "artifact_digest", "application_admission_digest"}) do
        if intent[field] ~= current[field] then
            return failure("CONFLICT", "settled activation identity changed: " .. field)
        end
    end
    local proposal = object(current.capability_proposal)
    local installed = object(current.capability_installed)
    if proposal or installed or intent.grant_predecessor_digest ~= nil then
        -- The installed grant is this activation's own, or, after the person
        -- went back to it, the grant of the version that revert replaced.
        local owner_intent: Object = intent
        if installed and installed.artifact_digest ~= intent.artifact_digest then
            local replaced = activations.reverted_from(config.activations, config.overlay_owner, intent.intent_id)
            local from = replaced.ok and object(replaced.value) or nil
            if from then owner_intent = from end
        end
        local own = owner_intent == intent
        if not proposal or (not installed and intent.application_admission_digest == nil)
            or (installed and ((own and installed.digest ~= proposal.digest)
                or installed.artifact_digest ~= owner_intent.artifact_digest or installed.version ~= owner_intent.version
                or installed.approval_id ~= owner_intent.approval_id)) then
            return failure("CONFLICT", "settled activation grant no longer matches its artifact, version and approval")
        end
    end
    return remeasure_migration_policy(intent, current, "decode activation restoration policy",
        "activation database policy changed since apply")
end

-- One step performs at most one durable transition around an external effect.
-- Calling it again after interruption resumes from the stored phase.
function M.step(raw_config: Config, intent_raw: unknown, receipt_raw: unknown): Result
    local config, config_error = configuration(raw_config)
    local intent_id, prefix = bounds.id(intent_raw), bounds.id(receipt_raw)
    if not config or not intent_id or not prefix then return failure("INVALID", config_error or "activation resume identity is invalid") end
    local intent, status_error = status(config, intent_id)
    if not intent then return status_error end
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
            if not current then return current_error end
            local installed = object(current.capability_installed)
            if not installed or installed.record_digest ~= intent.grant_reuse_digest
                or installed.approval_id ~= intent.approval_id then
                return failure("CONFLICT", "installed grant changed before reuse")
            end
            local reuse_key = key(prefix, "reuse-record")
            if not reuse_key then return failure("INVALID", "activation receipt key is too long") end
            return activations.call(config.activations, config.actor_id, {operation = "record_consumption",
                intent_id = intent_id, expected_revision = intent.revision, idempotency_key = reuse_key,
                consumer_id = "bee.gov.grant_reuse",
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
        if not current then return measurement_error end
        if intent.consumed_consumer_id == LEASE_CONSUMER then
            local proof = config.leases and lease_store.authorized(config.leases, intent_id) or nil
            if not proof or proof.approval_id ~= intent.approval_id
                or proof.approval_proposal_digest ~= intent.approval_proposal_digest then
                return failure("CONFLICT", "lease proof does not match the intent's authorization")
            end
        end
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
            local staged, staged_error = config.migrations.matches(config.overlay_owner, work, intent)
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
            local prepared, prepare_error = config.migrations.prepare(config.overlay_owner, work, intent)
            if not prepared then return failure("UNCERTAIN", tostring(prepare_error or "prepare migration definitions")) end
            local exact, exact_error = config.migrations.matches(config.overlay_owner, work, intent)
            if exact ~= true then return failure("UNCERTAIN", tostring(exact_error or "migration definitions are not exactly staged")) end
            local receipt, complete, execute_error = config.migrations.execute(work, intent)
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
        if not spec then return measurement_error end
        local desired_entries, desired_admission, desired_error = desired_intent(config, intent)
        if not desired_entries then return assert(desired_error) end
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
            -- Owner overlays advance their own generation rather than the
            -- durable registry base revision. Exact effect observation permits
            -- fresh remeasurement now; revision equality cannot decide progress.
            local reverified, reverify_error = remeasure_progress(config, intent)
            if not reverified then
                return uncertain(tostring((reverify_error).message
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
        local desired_entries, desired_admission, desired_error = desired_intent(config, intent)
        if not desired_entries then return assert(desired_error) end
        -- The person went back to this generation: once its overlay holds, the
        -- slot observes it again.
        local function observed(result: Object): Result
            if intent.observed_intent_id == intent_id then return transaction.success(result, false) end
            local observe_key = key(prefix, "restored-" .. tostring(intent.revision))
            if not observe_key then return failure("INVALID", "activation receipt key is too long") end
            local recorded = activations.call(config.activations, config.actor_id, {operation = "record_outcome",
                intent_id = intent_id, expected_revision = intent.revision, idempotency_key = observe_key,
                outcome = "applied", diagnostics = "restored after going back"})
            if not recorded.ok then return recorded end
            local value = object(recorded.value)
            if value then value.recovered = result.recovered end
            return transaction.success(value or result, false)
        end
        local matches, observe_error = config.matches(config.overlay_owner, desired_entries, desired_admission, intent)
        if matches == nil then return failure("UNAVAILABLE", tostring(observe_error)) end
        if matches then
            if intent.observed_intent_id == intent_id then return transaction.success(intent, true) end
            return observed(intent)
        end
        local restoration_error = remeasure_restoration(config, intent)
        if restoration_error then return restoration_error end
        local restored, restore_error = config.apply(config.overlay_owner, desired_entries, desired_admission, intent)
        if restored then
            local result: Object = {}
            for field, value in pairs(intent) do result[field] = value end
            result.recovered = true
            return observed(result)
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

-- What the person reads about an activation whose approval request ended
-- without approval.
local ENDED: {[string]: string} = {
    denied = "The person denied this installation.",
    expired = "The approval request expired before the person answered; install again to ask anew.",
    withdrawn = "The approval request was withdrawn; install again to ask anew.",
}

-- close ends an activation whose approval request ended without approval:
-- the approval owner says how it ended, the intent settles so without ever
-- reaching its effect, and the request leaves the approval owner's queue.
function M.close(raw_config: Config, intent_raw: unknown, receipt_raw: unknown): Result
    local config, config_error = configuration(raw_config)
    local intent_id, prefix = bounds.id(intent_raw), bounds.id(receipt_raw)
    if not config or not intent_id or not prefix then return failure("INVALID", config_error or "activation close identity is invalid") end
    local intent, status_error = status(config, intent_id)
    if not intent then return status_error end
    if intent.overlay_owner ~= config.overlay_owner then return failure("DENIED", "activation belongs to another overlay owner") end
    local result: Result = transaction.success(intent, true)
    if intent.phase == "approval_bound" or intent.phase == "consuming" then
        local ending, ending_error = approval.activation_ending(config.approvals, intent)
        if ending_error then return failure("UNAVAILABLE", ending_error) end
        if not ending then return failure("CONFLICT", "the activation's approval request has not ended") end
        local close_key = key(prefix, "ended-" .. ending)
        if not close_key then return failure("INVALID", "activation receipt key is too long") end
        result = activations.call(config.activations, config.actor_id, {operation = "record_outcome",
            intent_id = intent_id, expected_revision = intent.revision, idempotency_key = close_key,
            outcome = ending, diagnostics = ENDED[ending]})
        if not result.ok then return result end
    elseif not (intent.phase == "settled" and ENDED[tostring(intent.outcome)] ~= nil) then
        return failure("CONFLICT", "the activation is not waiting for its approval")
    end
    local close_error = approval.close_activation(config.approvals, intent)
    if close_error then return failure("UNAVAILABLE", close_error) end
    return result
end

function M.desired(raw_config: Config): Result
    local config, config_error = configuration(raw_config)
    if not config then return failure("INVALID", config_error or "activation owner configuration is invalid") end
    return activations.desired(config.activations, config.overlay_owner)
end

-- Advance carries an intent through its remaining steps until it settles or
-- a step refuses. Each step is one durable transition, so an interrupted
-- advance resumes from the stored phase. An intent settled as applied answers
-- at once.
M.MAX_STEPS = 16
function M.advance(raw_config: Config, intent_raw: unknown, receipt_raw: unknown): Result
    local result: Result = failure("INVALID", "activation advance identity is invalid")
    for _ = 1, M.MAX_STEPS do
        result = M.step(raw_config, intent_raw, receipt_raw)
        if not result.ok then return result end
        local intent = object(result.value)
        if not intent or intent.phase == "settled" then return result end
    end
    return failure("INTERNAL", "activation did not settle within " .. tostring(M.MAX_STEPS) .. " steps")
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
