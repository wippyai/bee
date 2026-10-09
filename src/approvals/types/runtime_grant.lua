local bounds = require("bounds")
local grants = require("grants")
local lease = require("runtime_lease")
local M = {}
function M.build(raw: unknown): grants.Grant
    local input = assert(bounds.object(raw))
    local proposal = assert(bounds.object(input.proposal))
    local ceiling = assert(lease.decode(proposal.payload))
    local approval = assert(bounds.id(input.approval_id))
    return {grant_id = approval .. ":grant",domain = "runtime_lease",owner_node = assert(bounds.id(input.owner_node)),workspace_id = ceiling.workspace_id,requester_id = ceiling.subject,granted_by = assert(bounds.id(input.actor_id)),granted_definition = bounds.id(input.definition_id),
        subject = {principal_id = ceiling.subject},scope = {type = "exact",parameters = {tool = ceiling.tool,input_digest = ceiling.input_digest}},
        terms = {kind = "bounded",time_basis = "absolute"},provenance = {kind = "decision",approval_id = approval,reviewed_digest = input.reviewed_digest},metadata = {lease_ref = approval,ceiling = ceiling},
        state = "active",revision = 1,used = 0,reserved = 0,until_ms = ceiling.expires_ms,max_uses = ceiling.max_uses,created_at = assert(bounds.timestamp(input.at)),approval_id = approval,decision_id = bounds.id(input.decision_id)}
end
return M
