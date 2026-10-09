local grants = require("grants")
local bounds = require("bounds")
local json = require("json")
local canonical = require("canonical")
local mcp = require("mcp")
local STATEMENTS = {
    [[ALTER TABLE bee_gateway_access_grants RENAME TO bee_gateway_access_receipts]],
    [[ALTER TABLE bee_gateway_access_receipts ADD COLUMN grant_id TEXT REFERENCES bee_approval_grants(grant_id)]],
    [[INSERT INTO bee_approval_grants(grant_id,approval_id,subject_json,scope_json,terms_json,state,revision,used,created_at,domain,owner_node,workspace_id,requester_id,granted_by,provenance_json,metadata_json)
        SELECT a.approval_id || ':grant',a.approval_id,json_object('principal_id',b.subject,'audience',b.binding_id),json_object('type','exact','parameters',json(COALESCE(r.proposal_json,json_object('binding_id',b.binding_id,'traits',json(a.traits_json))))), '{"kind":"binding","time_basis":"absolute"}',CASE WHEN b.revoked_at IS NULL AND b.sealed_at IS NULL THEN 'active' ELSE 'revoked' END,1,0,COALESCE(r.decided_at,b.created_at),'gateway_access',COALESCE(r.owner_node,'legacy:gateway'),COALESCE(r.workspace_id,b.workspace_id,'legacy:unscoped'),b.subject,COALESCE(r.decider_id,'legacy:' || b.subject),json_object('kind','legacy','source','gateway_access','approval_id',a.approval_id,'proposal_digest',a.proposal_digest),json_object('binding_id',b.binding_id,'configuration_digest',COALESCE(json_extract(r.proposal_json,'$.payload.configuration_digest'),'legacy'),'traits',json(a.traits_json)) FROM bee_gateway_access_receipts a JOIN bee_gateway_bindings b ON b.binding_id = a.binding_id LEFT JOIN bee_approval_requests r ON r.approval_id = a.approval_id WHERE true
        ON CONFLICT(grant_id) DO UPDATE SET subject_json = excluded.subject_json,scope_json = excluded.scope_json,terms_json = excluded.terms_json,state = CASE WHEN bee_approval_grants.state = 'revoked' THEN 'revoked' ELSE excluded.state END,revision = bee_approval_grants.revision + 1,used = 0,until_ms = NULL,max_uses = NULL,domain = excluded.domain,provenance_json = excluded.provenance_json,metadata_json = excluded.metadata_json]],
    [[UPDATE bee_gateway_access_receipts SET grant_id = approval_id || ':grant']],
    [[INSERT INTO bee_approval_grant_history SELECT grant_id,revision,'grant.migrated',granted_by,provenance_json,created_at FROM bee_approval_grants WHERE domain = 'gateway_access']],
}
return require("migration").define(function()
    migration("Move gateway access authority to common Grants and retain execution receipts",function()
        database("sqlite",function()
            up(function(db)
                for _, statement in ipairs(STATEMENTS) do
                    local _, err = db:execute(statement)
                    if err then error(err) end
                end
                for _, row in ipairs(assert(db:query("SELECT b.binding_id,b.subject,b.workspace_id,b.revoked_at,b.sealed_at,b.created_at,s.surface_json FROM bee_gateway_bindings b JOIN bee_gateway_surfaces s ON s.binding_id = b.binding_id"))) do
                    local configuration = assert(bounds.object(json.decode(row.surface_json)))
                    local base = assert(bounds.ids(configuration.base_tools,true))
                    local consent = configuration.profile ~= nil
                    for _, trait in ipairs(mcp.CONSENT_TRAITS) do for _, name in ipairs(trait.tools) do for _, tool in ipairs(base) do if tool == name then consent = true end end end end
                    if consent then
                        local workspace = row.workspace_id or "legacy:unscoped"
                        local id = grants.identity("gateway_access","legacy:gateway",workspace,row.binding_id .. ":surface")
                        local record: grants.Grant = {grant_id = id,domain = "gateway_access",owner_node = "legacy:gateway",workspace_id = workspace,requester_id = row.subject,granted_by = "legacy:" .. row.subject,
                            subject = {principal_id = row.subject,audience = row.binding_id},scope = {type = "exact",parameters = {configuration = configuration}},terms = {kind = "binding",time_basis = "absolute"},provenance = {kind = "legacy",source = "gateway_profile_surface",consenting_actor = "unrecorded"},metadata = {binding_id = row.binding_id,legacy_surface = true},state = (row.revoked_at ~= nil or row.sealed_at ~= nil) and "revoked" or "active",revision = 1,used = 0,reserved = 0,created_at = row.created_at}
                        local err = grants.create(db,record)
                        if err then error(err) end
                        configuration.authority_grant_id = id
                        assert(db:execute("UPDATE bee_gateway_surfaces SET surface_json = ? WHERE binding_id = ?",{canonical.encode(configuration),row.binding_id}))
                    end
                end
            end)
        end)
    end)
end)
