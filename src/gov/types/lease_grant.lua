local bounds = require("bounds")
local canonical = require("canonical")
local hash = require("hash")
local grants = require("grants")
local clock = require("clock")
local model = require("lease_model")
local capability = require("capability_model")
local M = {}
type Object = {[string]: unknown}
function M.build(raw: unknown): grants.Grant
    local input = assert(bounds.object(raw))
    local proposal = assert(bounds.object(input.proposal))
    local payload = assert(bounds.object(proposal.payload))
    local ttl, max, err = model.bounded(payload.ttl_seconds,payload.max_applies)
    assert(not err,tostring(err))
    local envelope = assert(capability.grants(payload.envelope))
    local encoded = assert(canonical.encode(envelope,65536))
    local approval, owner, workspace = assert(bounds.id(input.approval_id)),assert(bounds.id(input.owner_node)),assert(bounds.id(input.workspace_id))
    local lease_id = "lease-" .. assert(hash.sha256("bee.gov.lease_grant\n" .. approval))
    local at, now = assert(bounds.timestamp(input.at)),assert(bounds.integer(input.now))
    return {grant_id = grants.identity("governance_lease",owner,workspace,lease_id),domain = "governance_lease",owner_node = owner,workspace_id = workspace,requester_id = assert(bounds.id(input.requester_id)),granted_by = assert(bounds.id(input.actor_id)),granted_definition = bounds.id(input.definition_id),
        subject = {principal_id = owner,audience = payload.target},scope = {type = "governance_envelope",parameters = {target = payload.target,envelope = envelope}},
        terms = {kind = "bounded",time_basis = "relative",ttl_seconds = ttl,max_uses = max},provenance = {kind = "decision",approval_id = approval,reviewed_digest = input.reviewed_digest},
        metadata = {lease_id = lease_id,target = payload.target,envelope_bytes = encoded,envelope_digest = assert(hash.sha256(encoded)),source_approval_proposal_digest = input.proposal_digest,source_approval_owner_incarnation = input.owner_incarnation},
        state = "active",revision = 1,used = 0,reserved = 0,until_ms = ttl and now + ttl * 1000,max_uses = max,created_at = at,approval_id = approval,decision_id = bounds.id(input.decision_id)}
end
return M
