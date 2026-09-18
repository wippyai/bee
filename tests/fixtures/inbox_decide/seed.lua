-- MIT. Seed the inbox decide acceptance: stage, review and select one plan
-- in the governance plan store, then request a decision on its exact
-- proposal under the host approver policy that names the local viewer.
local funcs = require("funcs")
local logger = require("logger")
local helper = require("helper")

type Object = {[string]: unknown}

local function call(target: string, request: unknown): Object
    local raw, err = funcs.new():call(target, request)
    if err then error(target .. ": " .. tostring(err)) end
    local reply = helper.object(raw, target .. " returned no reply")
    if reply.ok ~= true then
        local fault = helper.object(reply.error, target .. " answered without a fault")
        error(target .. ": " .. tostring(fault.code) .. ": " .. tostring(fault.message))
    end
    return helper.object(reply.value, target .. " returned no value")
end

local function main()
    local plans = helper.open_plans()
    local plan = helper.selected_plan(plans)
    helper.close(plans)
    local proposal, proposal_digest = helper.proposal(plan)
    local requested = call("bee.approvals:request", {workspace_id = helper.WORKSPACE,
        idempotency_key = "inbox-decide-request", request_kind = "permission", policy = helper.POLICY,
        proposal = proposal, prompt = {text = helper.PROMPT}})
    if requested.proposal_digest ~= proposal_digest then
        error("owner recorded another proposal digest: " .. tostring(requested.proposal_digest))
    end
    logger:info("INBOX_DECIDE_SEEDED", {approval_id = requested.approval_id,
        plan_digest = plan.plan_digest, proposal_digest = proposal_digest})
end

return {main = main}
