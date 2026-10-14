local schema = require("grant_schema")
local STATEMENTS = {
    [[ALTER TABLE bee_approval_grants RENAME TO bee_approval_grants_prev]],
}
local COPY = {
    [[INSERT INTO bee_approval_grants(grant_id,approval_id,decision_id,subject_json,scope_json,terms_json,state,revision,used,until_ms,max_uses,created_at,owner_node,workspace_id,requester_id,granted_by,provenance_json)
        SELECT g.grant_id,g.approval_id,g.decision_id,g.subject_json,g.scope_json,g.terms_json,g.state,g.revision,g.used,g.until_ms,g.max_uses,g.created_at,r.owner_node,r.workspace_id,r.requester_id,COALESCE(r.decider_id,''),json_object('kind',CASE WHEN r.contract_version = 1 THEN 'legacy' ELSE 'decision' END,'approval_id',r.approval_id,'reviewed_digest',r.reviewed_digest) FROM bee_approval_grants_prev g JOIN bee_approval_requests r ON r.approval_id = g.approval_id]],
    [[DELETE FROM bee_approval_grants WHERE approval_id IN (SELECT grant_id FROM bee_approval_window_grants)]],
    [[INSERT INTO bee_approval_grants(grant_id,approval_id,decision_id,subject_json,scope_json,terms_json,state,revision,until_ms,max_uses,created_at,domain,owner_node,workspace_id,requester_id,granted_by,granted_definition,metadata_json,provenance_json,revoked_at)
        SELECT w.grant_id,w.grant_id,(SELECT decision_id FROM bee_approval_decisions d WHERE d.approval_id = w.grant_id ORDER BY revision DESC LIMIT 1),json_object('principal_id',w.requester_id),json_object('type','exact','parameters',json(r.proposal_json)),json_object('kind',CASE WHEN w.until_ms = 253402300799000 THEN 'until_revoked' ELSE 'window' END,'time_basis','absolute'),CASE WHEN w.revoked_at IS NOT NULL THEN 'revoked' ELSE 'active' END,1,w.until_ms,NULL,w.granted_at,'approval_window',w.owner_node,w.workspace_id,w.requester_id,w.granted_by,w.granted_definition,json_object('policy',w.policy,'scope_digest',w.scope_digest,'granted_ms',w.granted_ms,'until_at',w.until_at),json_object('kind','legacy','source','approval_window','approval_id',w.grant_id),w.revoked_at FROM bee_approval_window_grants w JOIN bee_approval_requests r ON r.approval_id = w.grant_id]],
    [[INSERT INTO bee_approval_grant_history SELECT grant_id,revision,'grant.migrated',granted_by,provenance_json,created_at FROM bee_approval_grants]],
    [[DROP TABLE bee_approval_grants_prev]],
    [[DROP TABLE bee_approval_window_grants]],
}
return require("migration").define(function()
    migration("Common grant authority and legacy approval windows", function()
        database("sqlite", function()
            up(function(db)
                for _, statement in ipairs(STATEMENTS) do
                    local _, err = db:execute(statement)
                    if err then error(err) end
                end
                local schema_error = schema.ensure(db)
                if schema_error then error(schema_error) end
                for _, statement in ipairs(COPY) do
                    local _, err = db:execute(statement)
                    if err then error(err) end
                end
            end)
        end)
    end)
end)
