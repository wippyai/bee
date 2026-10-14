local bounds = require("bounds")
local grants = require("grants")
local clock = require("clock")
local canonical = require("canonical")
local hash = require("hash")
local M = {}
function M.build(node: string, receipt: {[string]: unknown}, source: {[string]: unknown}?, network: string): (grants.Grant?,string?)
    local state = bounds.member(receipt.state,{"approved","revoked"})
    local approval = bounds.id(receipt.approval_id)
    local digest = bounds.text(receipt.selection_digest,64)
    if not state or not approval or not digest or #digest ~= 64 then return nil,"invalid legacy Docker admission receipt" end
    local proposal = source and bounds.object(source.proposal)
    local payload = proposal and bounds.object(proposal.payload)
    local owner = source and bounds.id(source.owner_node) or node
    local audience = payload and bounds.id(payload.network) or network
    return {grant_id = approval .. ":grant",domain = "docker_environment",owner_node = owner,workspace_id = source and bounds.id(source.workspace_id) or "legacy:docker-node",requester_id = source and bounds.id(source.requester_id) or "legacy:" .. node,granted_by = source and bounds.id(source.decider_id) or "legacy:" .. node,
        subject = {principal_id = owner,audience = audience},scope = {type = "exact",parameters = {selection_digest = digest,network = audience}},terms = {kind = "until_revoked",time_basis = "absolute"},
        provenance = {kind = "legacy",source = "docker_environment",approval_id = approval,proposal_digest = receipt.proposal_digest,receipt_digest = hash.sha256(assert(canonical.encode(receipt))),consenting_actor = source and source.decider_id or "unrecorded"},metadata = {selection_digest = digest,network = audience},state = state == "revoked" and "revoked" or "active",revision = 1,used = 0,reserved = 0,created_at = source and bounds.text(source.decided_at,64) or clock.now(),approval_id = approval},nil
end
function M.import(tx: sql.Transaction | sql.DB, node: string, receipt: {[string]: unknown}, source: {[string]: unknown}?, network: string): (grants.Grant?,string?)
    local record, err = M.build(node,receipt,source,network)
    if not record then return nil,err end
    local existing, read_error = grants.read(tx,record.grant_id)
    if read_error then return nil,read_error end
    if existing and existing.domain == "decision" then
        if not source then
            local retained = {owner_node = existing.owner_node,workspace_id = existing.workspace_id,requester_id = existing.requester_id,decider_id = existing.granted_by,decided_at = existing.created_at,proposal = existing.scope.parameters}
            local recovered, recover_error = M.build(node,receipt,retained,network)
            if not recovered then return nil,recover_error end
            record = recovered
        end
        err = grants.convert_decision(tx,record)
        if err then return nil,err end
    elseif not existing then
        err = grants.create(tx,record)
        if err then return nil,err end
    elseif existing.domain ~= record.domain then return nil,"legacy Docker approval has incompatible authority"
    else return existing,nil end
    return record,nil
end
return M
