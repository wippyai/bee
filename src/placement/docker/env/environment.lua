-- SPDX-License-Identifier: MIT
local M = {}
type Selection = {workspace: string, profile: string, digest: string, network: string, policy: string}
type Approval = {approval_id: string, proposal_digest: string, owner_incarnation: integer}
type Receipt = {grant_id: string?, state: string, selection_digest: string, approval_id: string, proposal_digest: string, owner_incarnation: integer, address: string?}
type IO = {
    load: () -> (Receipt?, string?), save: (Receipt) -> string?,
    request: (Selection) -> (Approval?, string?), await: (Approval) -> (string?, string?),
    check: (Receipt, Selection) -> string?, consume: (Approval) -> string?, provision: (Selection) -> (string?, string?),
    activate: (Receipt) -> string?, progress: (string) -> (),
}
function M.prepare(io: IO, selected: Selection): (Receipt?, string?)
    local receipt, load_error = io.load()
    if load_error then return nil, load_error end
    if receipt and receipt.selection_digest ~= selected.digest then return nil, "Docker environment selection changed; review its admission again" end
    if receipt and receipt.state == "denied" then return nil, "The person declined Docker network and gateway admission" end
    if receipt and (receipt.state == "approved" or receipt.state == "revoked") then
        local authority_error = io.check(receipt,selected)
        if authority_error then return nil,authority_error end
        io.progress("Connecting the approved Docker gateway")
        local address, provision_error = io.provision(selected)
        if not address then return nil, provision_error or "Approved Docker network is unavailable" end
        local refreshed: Receipt = {grant_id = receipt.grant_id,state = receipt.state, selection_digest = receipt.selection_digest,
            approval_id = receipt.approval_id, proposal_digest = receipt.proposal_digest,
            owner_incarnation = receipt.owner_incarnation, address = address}
        local save_error = io.save(refreshed)
        if save_error then return nil, save_error end
        local activate_error = io.activate(refreshed)
        if activate_error then return nil, activate_error end
        return refreshed, nil
    end
    if not receipt then
        io.progress("Waiting for approval to provision the Docker network and restricted Bee gateway")
        local approval, request_error = io.request(selected)
        if not approval then return nil, request_error or "Docker environment approval could not be recorded" end
        receipt = {grant_id = approval.approval_id .. ":grant",state = "pending", selection_digest = selected.digest, approval_id = approval.approval_id,
            proposal_digest = approval.proposal_digest, owner_incarnation = approval.owner_incarnation}
        local saved = io.save(receipt)
        if saved then return nil, saved end
    end
    local approval: Approval = {approval_id = receipt.approval_id, proposal_digest = receipt.proposal_digest, owner_incarnation = receipt.owner_incarnation}
    local decision, wait_error = io.await(approval)
    if wait_error then return nil, wait_error end
    if decision ~= "approved" and decision ~= "denied" then
        return nil, "Docker environment approval " .. tostring(decision or "is unavailable") .. "; no launch occurred"
    end
    if decision == "denied" then
        receipt.state = "denied"
        local saved = io.save(receipt)
        return nil, saved or "The person declined Docker network and gateway admission"
    end
    local consume_error = io.consume(approval)
    if consume_error then return nil, consume_error end
    local authority_error = io.check(receipt,selected)
    if authority_error then return nil,authority_error end
    io.progress("Provisioning the approved Docker network and restricted gateway")
    local address, provision_error = io.provision(selected)
    if not address then return nil, provision_error or "Docker environment provisioning outcome is unknown" end
    receipt.state, receipt.address = "approved", address
    local saved = io.save(receipt)
    if saved then return nil, saved end
    local activate_error = io.activate(receipt)
    if activate_error then return nil, activate_error end
    io.progress("Docker network and Bee gateway ready")
    return receipt, nil
end
return M
