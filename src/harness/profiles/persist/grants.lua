local grants = require("grants")
local bounds = require("bounds")
local canonical = require("canonical")
local clock = require("clock")
local security = require("security")
local ctx = require("ctx")
local M = {}
function M.id(owner: string, workspace: string, profile: string, revision: integer): string
    return grants.identity("profile_choices",owner,workspace,profile .. ":" .. tostring(revision))
end
function M.authorize(tx: sql.Transaction | sql.DB, workspace: string, configuration: unknown): (grants.Grant?, string?)
    local bound = bounds.object(ctx.get("bee.gateway.binding"))
    if not bound and security.can("bee.approvals.decide", workspace) then return nil, nil end
    local id = bound and bounds.id(bound.approving_grant_id)
    if not id then return nil, "DENIED: delegated profile writes require the approving grant" end
    local parent, err = grants.read(tx, id)
    local issuer = grants.principal("")
    if not parent or err or parent.workspace_id ~= workspace or grants.state(parent, clock.milliseconds()) ~= "active"
        or bound.subject ~= issuer then return nil, "DENIED: approving profile grant is no longer valid" end
    local parameters = bounds.object(parent.scope.parameters)
    local approved = parameters and bounds.object(parameters.configuration)
    local requested = bounds.object(configuration)
    if parent.domain ~= "profile_choices" or M.live(tx, parent) or not approved or not requested then return nil, "DENIED: grant does not approve profile choices" end
    for _, field in ipairs({"definition_ref", "driver_binding_ref", "provider", "bee", "placement", "workdir", "thread", "agent_ref", "owner_component_revision", "spec_digest"}) do
        if canonical.encode(approved[field]) ~= canonical.encode(requested[field]) then return nil, "DENIED: delegated profile exceeds approved " .. field end
    end
    return parent, nil
end
function M.live(tx: sql.Transaction | sql.DB, record: grants.Grant): string?
    local seen: {[string]: boolean} = {}
    local current = record
    for _ = 1, 16 do
        if grants.state(current, clock.milliseconds()) ~= "active" then return "profile consent is no longer active" end
        if current.provenance.kind ~= "delegated" then return nil end
        local id = bounds.id(current.provenance.approving_grant_id)
        if not id or seen[id] then return "invalid delegated profile provenance" end
        seen[id] = true
        local parent, err = grants.read(tx, id)
        if not parent then return err or "approving profile grant is missing" end
        current = parent
    end
    return "delegated profile provenance exceeds its bound"
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
    local rows, err = tx:query("SELECT * FROM bee_approval_grants WHERE domain = 'profile_choices' AND owner_node = ? AND workspace_id = ? AND json_extract(metadata_json,'$.profile_id') = ? AND state = 'active'",{owner,workspace,profile})
    if not rows or err then return "read saved profile authority" end
    for _, raw in ipairs(rows) do
        local record, invalid = grants.decode(raw)
        if not record then return invalid end
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
    value.grant_state = record and (M.live(tx, record) and "revoked" or grants.state(record,clock.milliseconds())) or "missing"
    value.approving_grant_id = record and record.provenance.approving_grant_id or nil
    return nil
end
return M
