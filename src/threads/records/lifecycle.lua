-- MIT. Decoders for the work lifecycle bodies the authority commits.
local types = require("types")
local bounds = require("bounds")
local values = require("values")
local M = {}
function M.admitted(value: unknown): (types.Admitted?, string?)
    local object = bounds.object(value)
    if not object then return nil, "admission must be an object" end
    local unknown_field = bounds.fields(object, {"request_id", "principal_id", "binding_ref", "binding_digest", "grant_refs", "budget_ref", "input"})
    if unknown_field then return nil, unknown_field end
    local request_id, principal_id = bounds.id(object.request_id), bounds.id(object.principal_id)
    local binding_ref, binding_digest = bounds.id(object.binding_ref), bounds.id(object.binding_digest)
    local budget_ref = bounds.id(object.budget_ref)
    if not request_id then return nil, "request_id is not an identifier" end
    if not principal_id then return nil, "principal_id is not an identifier" end
    if not binding_ref then return nil, "binding_ref is not an identifier" end
    if not binding_digest then return nil, "binding_digest is not an identifier" end
    if not budget_ref then return nil, "budget_ref is not an identifier" end
    local grants, grants_error = bounds.ids(object.grant_refs, true)
    if not grants then return nil, "grant_refs: " .. tostring(grants_error) end
    local input, input_error = values.content(object.input)
    if not input then return nil, input_error end
    return {request_id = request_id, principal_id = principal_id, binding_ref = binding_ref, binding_digest = binding_digest,
        grant_refs = grants, budget_ref = budget_ref, input = input}, nil
end
function M.prepared(value: unknown): (types.Prepared?, string?)
    local object = bounds.object(value)
    if not object then return nil, "preparation must be an object" end
    local unknown_field = bounds.fields(object, {"binding_ref", "binding_digest", "profile_id", "profile_digest", "placement_binding", "placement_attempt_id", "plan_digest"})
    if unknown_field then return nil, unknown_field end
    local binding_ref, binding_digest = bounds.id(object.binding_ref), bounds.id(object.binding_digest)
    local profile_id, profile_digest = bounds.id(object.profile_id), bounds.id(object.profile_digest)
    local placement_binding, placement_attempt_id = bounds.id(object.placement_binding), bounds.id(object.placement_attempt_id)
    local plan_digest = bounds.id(object.plan_digest)
    if not binding_ref then return nil, "binding_ref is not an identifier" end
    if not binding_digest then return nil, "binding_digest is not an identifier" end
    if not profile_id then return nil, "profile_id is not an identifier" end
    if not profile_digest then return nil, "profile_digest is not an identifier" end
    if not placement_binding then return nil, "placement_binding is not an identifier" end
    if not placement_attempt_id then return nil, "placement_attempt_id is not an identifier" end
    if not plan_digest then return nil, "plan_digest is not an identifier" end
    return {binding_ref = binding_ref, binding_digest = binding_digest, profile_id = profile_id, profile_digest = profile_digest,
        placement_binding = placement_binding, placement_attempt_id = placement_attempt_id, plan_digest = plan_digest}, nil
end
function M.started(value: unknown): (types.Started?, string?)
    local object = bounds.object(value)
    if not object then return nil, "start must be an object" end
    local unknown_field = bounds.fields(object, {"execution_kind", "execution_ref", "owner_epoch"})
    if unknown_field then return nil, unknown_field end
    local kind = bounds.member(object.execution_kind, {"process", "runner"})
    local ref = bounds.id(object.execution_ref)
    local epoch = bounds.integer(object.owner_epoch)
    if not kind then return nil, "execution_kind is not process or runner" end
    if not ref then return nil, "execution_ref is not an identifier" end
    if not epoch or epoch < 1 then return nil, "owner_epoch must be a positive integer" end
    return {execution_kind = kind :: types.ExecutionKind, execution_ref = ref, owner_epoch = epoch}, nil
end
function M.turn_request(value: unknown): (types.TurnRequest?, string?)
    local object = bounds.object(value)
    if not object then return nil, "turn request must be an object" end
    local unknown_field = bounds.fields(object, {"input_message_ids", "input", "resume_ref", "delivery_ids"})
    if unknown_field then return nil, unknown_field end
    local inputs, inputs_error = bounds.ids(object.input_message_ids, true)
    if not inputs then return nil, "input_message_ids: " .. tostring(inputs_error) end
    local input, input_error = values.content(object.input)
    if not input then return nil, input_error end
    local deliveries, deliveries_error = bounds.ids(object.delivery_ids, true)
    if not deliveries then return nil, "delivery_ids: " .. tostring(deliveries_error) end
    if #deliveries > 0 then return nil, "delivery_ids must be empty until delivery exists" end
    local request: types.TurnRequest = {input_message_ids = inputs, input = input, delivery_ids = deliveries}
    local resume, valid = values.optional_id(object, "resume_ref")
    if not valid then return nil, "resume_ref is not an identifier" end
    request.resume_ref = resume
    return request, nil
end
function M.turn_end(value: unknown): (types.TurnEnd?, string?)
    local object = bounds.object(value)
    if not object then return nil, "turn end must be an object" end
    local unknown_field = bounds.fields(object, {"outcome", "answer_message_ids", "evidence_refs", "usage", "error"})
    if unknown_field then return nil, unknown_field end
    local outcome = values.outcome(object.outcome)
    if not outcome then return nil, "turn outcome is not an outcome" end
    local answers, answers_error = bounds.ids(object.answer_message_ids, true)
    if not answers then return nil, "answer_message_ids: " .. tostring(answers_error) end
    local evidence, evidence_error = bounds.ids(object.evidence_refs, true)
    if not evidence then return nil, "evidence_refs: " .. tostring(evidence_error) end
    local turn_end: types.TurnEnd = {outcome = outcome, answer_message_ids = answers, evidence_refs = evidence}
    if object.usage ~= nil then
        local usage, usage_error = values.usage(object.usage)
        if not usage then return nil, usage_error end
        turn_end.usage = usage
    end
    if object.error ~= nil then
        local fault, fault_error = values.fault(object.error)
        if not fault then return nil, fault_error end
        turn_end.error = fault
    end
    if outcome == "succeeded" and turn_end.error then return nil, "a succeeded turn carries no error" end
    if outcome ~= "succeeded" and not turn_end.error then return nil, "a turn that did not succeed names its error" end
    return turn_end, nil
end
function M.receipt(value: unknown): (types.Receipt?, string?)
    local object = bounds.object(value)
    if not object then return nil, "receipt must be an object" end
    local unknown_field = bounds.fields(object, {"scope", "outcome", "evidence_refs", "error"})
    if unknown_field then return nil, unknown_field end
    local scope = bounds.member(object.scope, {"attempt", "action"})
    local outcome = values.outcome(object.outcome)
    if not scope then return nil, "receipt scope is not attempt or action" end
    if not outcome then return nil, "receipt outcome is not an outcome" end
    local evidence, evidence_error = bounds.ids(object.evidence_refs, true)
    if not evidence then return nil, "evidence_refs: " .. tostring(evidence_error) end
    local receipt: types.Receipt = {scope = scope :: types.ReceiptScope, outcome = outcome, evidence_refs = evidence}
    if object.error ~= nil then
        local fault, fault_error = values.fault(object.error)
        if not fault then return nil, fault_error end
        receipt.error = fault
    end
    if outcome == "succeeded" and receipt.error then return nil, "a succeeded receipt carries no error" end
    if outcome ~= "succeeded" and not receipt.error then return nil, "a receipt that did not succeed names its error" end
    return receipt, nil
end
return M
