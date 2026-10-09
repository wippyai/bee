local bounds = require("bounds")
local grants = require("grants")
local M = {}
function M.build(raw: unknown): grants.Grant
    local input = assert(bounds.object(raw))
    local proposal = assert(bounds.object(input.proposal))
    local payload = assert(bounds.object(proposal.payload))
    local capability = assert(bounds.object(payload.capability))
    local scope = assert(bounds.object(capability.scope))
    local binding, subject = assert(bounds.id(payload.binding_id)),assert(bounds.id(payload.subject))
    assert(subject == input.requester_id,"gateway access subject differs")
    local approval = assert(bounds.id(input.approval_id))
    return {grant_id = approval .. ":grant",domain = "gateway_access",owner_node = assert(bounds.id(input.owner_node)),workspace_id = assert(bounds.id(input.workspace_id)),requester_id = subject,granted_by = assert(bounds.id(input.actor_id)),granted_definition = bounds.id(input.definition_id),
        subject = {principal_id = subject,audience = binding},scope = {type = "exact",parameters = proposal},terms = {kind = "binding",time_basis = "absolute"},
        provenance = {kind = "decision",approval_id = approval,reviewed_digest = input.reviewed_digest},metadata = {binding_id = binding,configuration_digest = payload.configuration_digest,traits = assert(bounds.ids(scope.traits,true))},
        state = "active",revision = 1,used = 0,reserved = 0,created_at = assert(bounds.timestamp(input.at)),approval_id = approval,decision_id = bounds.id(input.decision_id)}
end
return M
