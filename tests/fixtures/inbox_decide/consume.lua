-- MIT. Consume the inbox decision: bind the approved proposal to one
-- effect identity and prove a second effect is refused.
local funcs = require("funcs")
local logger = require("logger")
local helper = require("helper")

type Object = {[string]: unknown}

-- On a fault the reply still carries value: for REVALIDATE the current
-- authority incarnation lives there, not on the fault itself.
local function call(target: string, request: unknown): (Object?, Object?, unknown)
    local raw, err = funcs.new():call(target, request)
    if err then error(target .. ": " .. tostring(err)) end
    local reply = helper.object(raw, target .. " returned no reply")
    if reply.ok ~= true then
        return nil, helper.object(reply.error, target .. " answered without a fault"), reply.value
    end
    return helper.object(reply.value, target .. " returned no value"), nil, nil
end

local function main()
    local plans = helper.open_plans()
    local plan = helper.get_selected(plans)
    helper.close(plans)
    local proposal, proposal_digest = helper.proposal(plan)
    if proposal.revision ~= plan.plan_digest or proposal.input_digest ~= plan.plan_digest then
        error("decision proposal does not bind the exact plan digest")
    end
    local listed, list_error = call("bee.approvals.binding:list", {workspace_id = helper.WORKSPACE})
    if not listed then error("list requests: " .. tostring((list_error :: Object).message)) end
    local approval_id: string? = nil
    local incarnation: integer? = nil
    local decider_id: string? = nil
    for _, raw in ipairs(helper.object(listed, "request list is malformed").requests :: {unknown}) do
        local item = helper.object(raw, "request list holds a malformed request")
        if item.state == "decided" and item.decision == "approved" and item.proposal_digest == proposal_digest then
            approval_id = item.approval_id :: string
            incarnation = math.floor(item.owner_incarnation :: number)
            decider_id = item.decider_id :: string
        end
    end
    if not approval_id or not incarnation then error("approved decision for the staged plan is missing") end
    if not decider_id or not decider_id:match("^bee%.application:[0-9a-f]+:[^:]+$") then
        error("decision was not recorded under the broker application actor: " .. tostring(decider_id))
    end
    -- The consume probe boots its own authority, so the incarnation the list
    -- call observed is already behind the one this process just started
    -- under; revalidate against the fault's current incarnation and retry,
    -- the same recovery the activation owner performs in production.
    local receipt, consume_error, consume_fault_value = call("bee.approvals.binding:consume", {approval_id = approval_id,
        proposal_digest = proposal_digest, owner_incarnation = incarnation, effect_key = helper.EFFECT_KEY})
    if not receipt and (consume_error :: Object).code == "REVALIDATE" then
        local fault_value = helper.object(consume_fault_value, "revalidate fault carries no value")
        local current = math.floor(fault_value.current_incarnation :: number)
        local revalidated, revalidate_error = call("bee.approvals.binding:revalidate", {approval_id = approval_id,
            proposal_digest = proposal_digest, owner_incarnation = current})
        if not revalidated then
            error("revalidate decision: " .. tostring((revalidate_error :: Object).code) .. ": " .. tostring((revalidate_error :: Object).message))
        end
        incarnation = current
        receipt, consume_error = call("bee.approvals.binding:consume", {approval_id = approval_id,
            proposal_digest = proposal_digest, owner_incarnation = incarnation, effect_key = helper.EFFECT_KEY})
    end
    if not receipt then
        error("consume decision: " .. tostring((consume_error :: Object).code) .. ": " .. tostring((consume_error :: Object).message))
    end
    if receipt.proposal_digest ~= proposal_digest then
        error("consumption bound another proposal digest: " .. tostring(receipt.proposal_digest))
    end
    if receipt.consumed_effect ~= helper.EFFECT_KEY or receipt.consumer_id == nil then
        error("consumption recorded another effect")
    end
    logger:info("INBOX_DECIDE_CONSUMED", {approval_id = approval_id, plan_digest = plan.plan_digest,
        proposal_digest = proposal_digest, effect = receipt.consumed_effect, decider_id = decider_id})
    local _, second_error = call("bee.approvals.binding:consume", {approval_id = approval_id,
        proposal_digest = proposal_digest, owner_incarnation = incarnation, effect_key = helper.RETRY_EFFECT_KEY})
    if second_error == nil then error("a second effect consumed the same decision") end
    if (second_error :: Object).code ~= "CONFLICT" then
        error("second consume refused with " .. tostring((second_error :: Object).code) .. " instead of CONFLICT")
    end
    logger:info("INBOX_DECIDE_SECOND_REFUSED", {approval_id = approval_id, code = (second_error :: Object).code})
end

return {main = main}
