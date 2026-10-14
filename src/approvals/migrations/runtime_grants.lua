local STATEMENTS = {
    [[INSERT INTO bee_approval_grants(grant_id,approval_id,subject_json,scope_json,terms_json,state,revision,used,until_ms,max_uses,created_at,domain,owner_node,workspace_id,requester_id,granted_by,provenance_json,metadata_json,revoked_at)
        SELECT l.lease_ref || ':grant',l.lease_ref,json_object('principal_id',l.subject),json_object('type','exact','parameters',json_object('tool',l.tool,'input_digest',l.input_digest)),'{"kind":"bounded","time_basis":"absolute"}',CASE WHEN l.revoked_at IS NULL THEN 'active' ELSE 'revoked' END,1,(SELECT COUNT(*) FROM bee_approval_runtime_lease_uses u WHERE u.lease_ref = l.lease_ref),l.expires_ms,l.max_uses,COALESCE(r.decided_at,r.created_at,strftime('%Y-%m-%dT%H:%M:%fZ','now')),'runtime_lease',l.owner_node,l.workspace_id,l.subject,COALESCE(r.decider_id,l.subject),json_object('kind','legacy','source','runtime_lease','approval_id',l.lease_ref,'proposal_digest',l.source_digest),json_object('lease_ref',l.lease_ref,'ceiling',json_object('subject',l.subject,'workspace_id',l.workspace_id,'tool',l.tool,'input_digest',l.input_digest,'expires_ms',l.expires_ms,'max_uses',l.max_uses)),l.revoked_at FROM bee_approval_runtime_leases l LEFT JOIN bee_approval_requests r ON r.approval_id = l.lease_ref WHERE true
        ON CONFLICT(grant_id) DO UPDATE SET subject_json = excluded.subject_json,scope_json = excluded.scope_json,terms_json = excluded.terms_json,state = CASE WHEN bee_approval_grants.state = 'revoked' THEN 'revoked' ELSE excluded.state END,revision = bee_approval_grants.revision + 1,used = excluded.used,until_ms = excluded.until_ms,max_uses = excluded.max_uses,domain = excluded.domain,provenance_json = excluded.provenance_json,metadata_json = excluded.metadata_json,revoked_at = excluded.revoked_at]],
    [[INSERT INTO bee_approval_grant_uses(grant_id,effect_key,request_digest,state,created_at,admitted_at) SELECT u.lease_ref || ':grant',u.effect_key,u.request_digest,'admitted',g.created_at,g.created_at FROM bee_approval_runtime_lease_uses u JOIN bee_approval_grants g ON g.grant_id = u.lease_ref || ':grant']],
    [[INSERT INTO bee_approval_grant_history SELECT grant_id,revision,'grant.migrated',granted_by,provenance_json,created_at FROM bee_approval_grants WHERE domain = 'runtime_lease']],
    [[DROP TABLE bee_approval_runtime_lease_uses]],
    [[DROP TABLE bee_approval_runtime_leases]],
}
return require("migration").define(function()
    migration("Move runtime lease authority and effect uses to common Grants",function()
        database("sqlite",function()
            up(function(db)
                for _, statement in ipairs(STATEMENTS) do
                    local _, err = db:execute(statement)
                    if err then error(err) end
                end
            end)
        end)
    end)
end)
