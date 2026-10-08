-- MIT. Reconciles one destination-consented immutable publication.
local bounds = require("bounds")
local store = require("follow_store")
local plans = require("plan_store")
local activations = require("activation_store")
local owner = require("activation_owner")
local destination = require("destination")
local delivery = require("delivery")
local preflight = require("preflight")
local transaction = require("transaction")
local M = {}
type Identity = store.Identity
type Result = transaction.Result
local function failure(code: string, message: string): Result
    return transaction.failure(code, message)
end
local function without_lease(config: owner.Config): owner.Config
    return {plans = config.plans, activations = config.activations, resolver = config.resolver,
        approvals = config.approvals, actor_id = config.actor_id, consumer_id = config.consumer_id,
        overlay_owner = config.overlay_owner, approval_policy = config.approval_policy,
        apply = config.apply, matches = config.matches, migrations = config.migrations}
end
local function execute(config: owner.Config, identity: Identity, item: delivery.Delivery,
    intent_id: string): Result
    local current = activations.get(config.activations, intent_id)
    local intent = current.ok and bounds.object(current.value) or nil
    if not intent and current.code ~= "NOT_FOUND" then return current end
    if not intent then
        local found = plans.call(config.plans, config.actor_id, {operation = "get",
            source_node = identity.source_node, source_workspace = identity.source_workspace, version = item.value.version})
        if not found.ok and found.code ~= "NOT_FOUND" then return found end
        if found.code == "NOT_FOUND" then
            found = destination.stage_artifact(config.plans, config.actor_id, {source_node = identity.source_node,
                source_workspace = identity.source_workspace, version = item.value.version, artifact = item.value.artifact,
                author = item.value.author, idempotency_key = intent_id .. ":stage"}, config.resolver)
        end
        if not found.ok then return found end
        found = plans.call(config.plans, config.actor_id, {operation = "get", source_node = identity.source_node,
            source_workspace = identity.source_workspace, version = item.value.version})
        if not found.ok then return found end
        local plan = bounds.object(found.value)
        if not plan or plan.artifact_digest ~= item.value.artifact.digest then return failure("CONFLICT", "Staged source bytes changed") end
        local report, report_error = preflight.decode_report(plan.preflight_bytes, plan.preflight_digest)
        if not report or not report.ready then return failure("BLOCKED", report_error or "Source update fails destination checks") end
        if plan.review_status == "rejected" then return failure("BLOCKED", "Source update is locally rejected") end
        if plan.review_status ~= "accepted" then
            found = plans.call(config.plans, config.actor_id, {operation = "record_review",
                source_node = identity.source_node, source_workspace = identity.source_workspace, version = item.value.version,
                expected_revision = plan.revision, idempotency_key = intent_id .. ":review",
                review_status = "accepted", review_reason = "Destination consents to follow this source; preflight passes"})
            if not found.ok then return found end
            plan = bounds.object(found.value)
        end
        if not plan then return failure("INTERNAL", "Source update plan is missing") end
        if plan.selected ~= true then
            found = plans.call(config.plans, config.actor_id, {operation = "select",
                source_node = identity.source_node, source_workspace = identity.source_workspace, version = item.value.version,
                expected_revision = plan.revision, idempotency_key = intent_id .. ":select"})
            if not found.ok then return found end
        end
    end
    if not intent or intent.phase == "prepared" then
        current = owner.prepare(without_lease(config), {source_node = identity.source_node,
            source_workspace = identity.source_workspace, version = item.value.version,
            intent_id = intent_id, receipt_key = intent_id})
        if not current.ok then return current end
        intent = bounds.object(current.value)
    end
    if not intent then return failure("INTERNAL", "Source activation is missing") end
    if intent.phase == "approval_bound" then return current end
    return owner.advance(config, intent_id, intent_id)
end
function M.reconcile(config: owner.Config, identity: Identity, descriptor_raw: unknown,
    content: string, cursor: integer): Result
    local read = store.get(config.activations, identity)
    if not read.ok then return read end
    local row = bounds.object(read.value)
    if not row or row.mode ~= "following" then return failure("PAUSED", "Following is off, paused or pinned") end
    local descriptor = bounds.object(descriptor_raw)
    local item, decode_error = delivery.decode(content, descriptor and descriptor.content_digest)
    if not item then return failure("INVALID", decode_error or "Source publication is invalid") end
    local verified, verification_error = delivery.verify_descriptor(descriptor_raw, item)
    if not verified or item.value.source_node ~= identity.source_node or item.value.source_workspace ~= identity.source_workspace
        or item.value.component ~= identity.component then return failure("INVALID", verification_error or "Source identity changed") end
    local pending = bounds.object(row.pending)
    if not pending then
        local reserved = store.reserve(config.activations, identity, descriptor_raw, cursor)
        if not reserved.ok then return reserved end
        row = bounds.object(reserved.value)
        if not row then return failure("INTERNAL", "Follow reservation is missing") end
        pending = bounds.object(row.pending)
        if not pending then return reserved end
    end
    if pending.digest ~= (assert(descriptor)).digest then return failure("BUSY", "Another source update is in progress") end
    local intent_id = bounds.id(row.intent_id)
    if not intent_id then return failure("INTERNAL", "Follow activation identity is missing") end
    local result = execute(config, identity, item, intent_id)
    local intent = result.ok and bounds.object(result.value) or nil
    local outcome = intent and bounds.id(intent.outcome) or nil
    local last_outcome: string
    local message: string
    if not result.ok then
        last_outcome = (result.code == "UNCERTAIN" or result.code == "BUSY" or result.code == "UNAVAILABLE" or result.code == "APPROVAL") and "activating" or "failed"
        message = result.message or "Source update failed"
    elseif intent and intent.phase == "approval_bound" then
        last_outcome, message = "needs_you", "Approve " .. item.value.version .. " in Needs you"
    elseif outcome then
        last_outcome, message = outcome, outcome == "applied" and ("Applied " .. item.value.version) or ("Source update " .. outcome)
    else
        last_outcome, message = "activating", "Installing " .. item.value.version
    end
    local finished = store.finish(config.activations, identity, intent_id, last_outcome, message)
    if not finished.ok then return finished end
    return result
end
return M
