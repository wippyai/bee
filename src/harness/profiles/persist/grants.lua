local grants = require("grants")
local bounds = require("bounds")
local canonical = require("canonical")
local clock = require("clock")
local M = {}
function M.id(owner: string, workspace: string, profile: string, revision: integer): string
    return grants.identity("profile_choices",owner,workspace,profile .. ":" .. tostring(revision))
end
function M.save(tx: sql.Transaction | sql.DB, owner: string, workspace: string, profile: string, revision: integer, configuration: unknown, actor: string, legacy: boolean, at: string): (grants.Grant?, string?)
    local id = M.id(owner,workspace,profile,revision)
    local existing, read_error = grants.read(tx,id)
    if existing or read_error then return existing,read_error end
    local issuer, definition = grants.principal(actor)
    local record: grants.Grant = {grant_id = id,domain = "profile_choices",owner_node = owner,workspace_id = workspace,requester_id = legacy and actor or issuer,granted_by = legacy and actor or issuer,granted_definition = not legacy and definition or nil,
        subject = {principal_id = owner,audience = profile},scope = {type = "exact",parameters = {profile_id = profile,profile_revision = revision,configuration = configuration}},terms = {kind = "until_revoked",time_basis = "absolute"},
        provenance = {kind = legacy and "legacy" or "consent",source = "saved_profile",consenting_actor = legacy and (actor:match("^legacy:") and "unrecorded" or actor) or issuer},metadata = {profile_id = profile,profile_revision = revision},state = "active",revision = 1,used = 0,reserved = 0,created_at = at}
    local err = grants.create(tx,record)
    if err then return nil,err end
    return record,nil
end
function M.retire(tx: sql.Transaction | sql.DB, owner: string, workspace: string, profile: string, actor: string): string?
    local rows, err = tx:query("SELECT * FROM bee_approval_grants WHERE domain = 'profile_choices' AND owner_node = ? AND workspace_id = ? AND json_extract(metadata_json,'$.profile_id') = ? AND state = 'active'",{owner,workspace,profile})
    if not rows or err then return "read saved profile authority" end
    for _, raw in ipairs(rows) do
        local record, invalid = grants.decode(raw)
        if not record then return invalid end
        local revoke_error = grants.revoke(tx,record,record.revision,actor,clock.milliseconds())
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
    value.grant_state = record and grants.state(record,clock.milliseconds()) or "missing"
    return nil
end
return M
