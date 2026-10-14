local grants = require("grants")
local bounds = require("bounds")
local canonical = require("canonical")
local clock = require("clock")
local security = require("security")
local ctx = require("ctx")
local json = require("json")
local profile_values = require("profile_values")
local protocol = require("protocol")
local profile_grants = require("profile_grants")
local M = {}
function M.id(owner: string, workspace: string, profile: string, revision: integer): string
    return grants.identity("profile_choices",owner,workspace,profile .. ":" .. tostring(revision))
end
function M.authorize(tx: sql.Transaction | sql.DB, workspace: string, configuration: unknown): (grants.Grant?, string?)
    local bound = bounds.object(ctx.get("bee.gateway.binding"))
    if not bound and security.can("bee.approvals.decide", workspace) then return nil, nil end
    local requested_profile = bounds.object(configuration)
    local binding_ref = requested_profile and bounds.id(requested_profile.driver_binding_ref)
    local provider = requested_profile and bounds.object(requested_profile.provider)
    if binding_ref and provider then
        local person_only = profile_values.person_only(binding_ref, provider)
        if person_only then return nil, "DENIED: " .. person_only end
    end
    local id = bound and bounds.id(bound.approving_grant_id)
    if not id then return nil, "DENIED: delegated profile writes require the approving grant" end
    local parent, err = grants.read(tx, id)
    local issuer = grants.principal("")
    if not parent or err or parent.workspace_id ~= workspace or grants.state(parent, clock.milliseconds()) ~= "active"
        or bound.subject ~= issuer then return nil, "DENIED: approving profile grant is no longer valid" end
    local parameters = bounds.object(parent.scope.parameters)
    local approved = parameters and bounds.object(parameters.configuration)
    local requested = bounds.object(configuration)
    if approved then
        local decoded = protocol.profile(approved)
        if decoded then approved = decoded end
    end
    if requested then
        local decoded = protocol.profile(requested)
        if decoded then requested = decoded end
    end
    if parent.domain ~= "profile_choices" or profile_grants.live(tx, parent) or not approved or not requested then return nil, "DENIED: grant does not approve profile choices" end
    for _, field in ipairs({"definition_ref", "driver_binding_ref", "provider", "bee", "placement", "workdir", "thread", "agent_ref", "owner_component_revision", "spec_digest"}) do
        if canonical.encode(approved[field]) ~= canonical.encode(requested[field]) then return nil, "DENIED: delegated profile exceeds approved " .. field end
    end
    return parent, nil
end
function M.save(tx: sql.Transaction | sql.DB, owner: string, workspace: string, profile: string, revision: integer, configuration: unknown, actor: string, legacy: boolean, at: string, approving: grants.Grant?): (grants.Grant?, string?)
    local id = M.id(owner,workspace,profile,revision)
    local existing, read_error = grants.read(tx,id)
    if existing or read_error then return existing,read_error end
    local issuer, definition = grants.principal(actor)
    local parent, authorization_error = approving, nil
    if not legacy and not parent then parent, authorization_error = M.authorize(tx, workspace, configuration) end
    if authorization_error then return nil, authorization_error end
    local provenance: {[string]: unknown} = {kind = legacy and "legacy" or "consent", source = "saved_profile", consenting_actor = legacy and (actor:match("^legacy:") and "unrecorded" or actor) or issuer}
    if parent then provenance = {kind = "delegated", source = "saved_profile", approving_grant_id = parent.grant_id, delegated_actor = issuer} end
    local granting_definition = definition
    if parent then granting_definition = parent.granted_definition end
    if legacy then granting_definition = nil end
    local record: grants.Grant = {grant_id = id,domain = "profile_choices",owner_node = owner,workspace_id = workspace,requester_id = legacy and actor or issuer,granted_by = parent and parent.granted_by or (legacy and actor or issuer),granted_definition = granting_definition,
        subject = {principal_id = owner,audience = profile},scope = {type = "exact",parameters = {profile_id = profile,profile_revision = revision,configuration = configuration}},terms = {kind = "until_revoked",time_basis = "absolute"},
        provenance = provenance,metadata = {profile_id = profile,profile_revision = revision},state = "active",revision = 1,used = 0,reserved = 0,created_at = at}
    local err = grants.create(tx,record)
    if err then return nil,err end
    return record,nil
end
function M.retire(tx: sql.Transaction | sql.DB, owner: string, workspace: string, profile: string, actor: string, preserving: string?): string?
    local retained: {[string]: boolean} = {}
    local ancestor = preserving
    for _ = 1, 16 do
        if not ancestor then break end
        if retained[ancestor] then return "invalid delegated profile provenance" end
        retained[ancestor] = true
        local record, err = grants.read(tx, ancestor)
        if not record then return err or "approving profile grant is missing" end
        ancestor = record.provenance.kind == "delegated" and bounds.id(record.provenance.approving_grant_id) or nil
    end
    if ancestor then return "delegated profile provenance exceeds its bound" end
    local rows, err = grants.find(tx,{domain = "profile_choices",owner_node = owner,workspace_id = workspace,metadata_key = "profile_id",metadata_value = profile,active = true})
    if not rows or err then return "read saved profile authority" end
    for _, record in ipairs(rows) do
        local revoke_error = not retained[record.grant_id] and grants.revoke(tx,record,record.revision,actor,clock.milliseconds()) or nil
        if revoke_error then return revoke_error end
    end
    return nil
end
function M.decorate(tx: sql.Transaction, owner: string, value: {[string]: unknown}): string?
    local profile, workspace, revision = bounds.id(value.profile_id),bounds.id(value.workspace_id),bounds.integer(value.revision)
    if value.tombstone == true or value.profile == nil then return nil end
    if not profile or not workspace or not revision then return "invalid profile authority identity" end
    local record, err = grants.read(tx,M.id(owner,workspace,profile,revision))
    if err then return err end
    value.grant_id = record and record.grant_id or nil
    value.grant_state = record and (profile_grants.live(tx, record) and "revoked" or grants.state(record,clock.milliseconds())) or "missing"
    value.approving_grant_id = record and record.provenance.approving_grant_id or nil
    return nil
end
function M.save_folder(tx: sql.Transaction | sql.DB, parent: grants.Grant, workdir: string, binding: string, approval: string): (grants.Grant?, string?)
    local caller = security.actor()
    local metadata = caller and bounds.object(caller:meta())
    if ctx.get("bee.gateway.binding") ~= nil or not security.can("bee.approvals.decide", parent.workspace_id)
        or (metadata and metadata.definition_id ~= nil and metadata.definition_id ~= "bee.harness.app:app") then
        return nil, "Folder trust requires a person write with consent provenance"
    end
    local active, read_error = grants.read(tx, parent.grant_id)
    if not active or read_error or active.domain ~= "profile_choices" or profile_grants.live(tx, active) then return nil, read_error or "Profile consent is no longer active" end
    local parent_parameters = bounds.object(active.scope.parameters)
    local configuration = parent_parameters and bounds.object(parent_parameters.configuration)
    if not configuration or configuration.driver_binding_ref ~= binding then return nil, "Folder trust selects a different profile driver" end
    local consumer = grants.principal("")
    local rows, err = tx:query([[SELECT r.proposal_json,r.decider_id,d.decision_id,d.decider_json,r.decided_at
        FROM bee_approval_requests r JOIN bee_approval_decisions d ON d.approval_id=r.approval_id AND d.revision=r.revision
        WHERE r.approval_id=? AND r.workspace_id=? AND r.state='decided' AND r.decision='approved'
        AND r.consumer_id=? AND r.consumed_effect=r.approval_id]], {approval, parent.workspace_id, consumer})
    if not rows or err or #rows ~= 1 then return nil, "Folder trust requires a recorded person approval" end
    local row = rows[1]
    local proposal = bounds.object(json.decode(tostring(row.proposal_json)))
    local payload = proposal and bounds.object(proposal.payload)
    local target = payload and bounds.object(payload.target)
    if not proposal or proposal.ref ~= "bee.approvals:confirmation" or not payload or payload.action ~= "profile.folder_trust"
        or not target or target.parent_grant_id ~= parent.grant_id or target.canonical_workdir ~= workdir or target.driver_binding_ref ~= binding
        or target.folder_trust ~= "approved-workdir" then return nil, "Folder trust is outside recorded person approval" end
    local id = grants.identity("profile_choices", parent.owner_node, parent.workspace_id, approval)
    local previous, previous_error = grants.read(tx, id)
    if previous or previous_error then return previous, previous_error end
    local decider = bounds.object(json.decode(tostring(row.decider_json)))
    local profile = bounds.id(parent.metadata.profile_id)
    if not profile then return nil, "Folder trust requires a saved profile" end
    local record: grants.Grant = {grant_id = id, approval_id = approval, decision_id = tostring(row.decision_id), domain = "profile_choices",
        owner_node = parent.owner_node, workspace_id = parent.workspace_id, requester_id = parent.requester_id,
        granted_by = tostring(row.decider_id), granted_definition = decider and bounds.id(decider.definition_id),
        subject = parent.subject, scope = {type = "exact", parameters = {profile_id = profile, parent_grant_id = parent.grant_id,
            canonical_workdir = workdir, configuration = {driver_binding_ref = binding, provider = {options = {folder_trust = "approved-workdir"}}}}},
        terms = {kind = "until_revoked", time_basis = "absolute"}, provenance = {kind = "consent", source = "saved_profile", consenting_actor = row.decider_id},
        metadata = {profile_id = profile, folder_profile_grant = parent.grant_id, canonical_workdir = workdir}, state = "active", revision = 1,
        used = 0, reserved = 0, created_at = tostring(row.decided_at)}
    local created = grants.create(tx, record)
    if created then return nil, created end
    return record, nil
end
return M
