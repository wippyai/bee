local bounds = require("bounds")
local grants = require("grants")
local M = {}
function M.build(raw: unknown): grants.Grant
    local input = assert(bounds.object(raw))
    local proposal = assert(bounds.object(input.proposal))
    local payload = assert(bounds.object(proposal.payload))
    local policy = assert(bounds.object(input.policy_snapshot))
    assert(policy.allow_permanent == true,"Docker policy does not permit until_revoked authority")
    local owner, workspace = assert(bounds.id(input.owner_node)),assert(bounds.id(input.workspace_id))
    local approval = assert(bounds.id(input.approval_id))
    return {grant_id = approval .. ":grant",domain = "docker_environment",owner_node = owner,workspace_id = workspace,requester_id = assert(bounds.id(input.requester_id)),granted_by = assert(bounds.id(input.actor_id)),granted_definition = bounds.id(input.definition_id),
        subject = {principal_id = owner,audience = payload.network},scope = {type = "exact",parameters = proposal},terms = {kind = "until_revoked",time_basis = "absolute"},
        provenance = {kind = "decision",approval_id = approval,reviewed_digest = input.reviewed_digest},metadata = {selection_digest = proposal.input_digest,network = payload.network},
        state = "active",revision = 1,used = 0,reserved = 0,created_at = assert(bounds.timestamp(input.at)),approval_id = approval,decision_id = bounds.id(input.decision_id)}
end
return M
