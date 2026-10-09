local schema = require("grant_schema")
local grants = require("grants")
local clock = require("clock")
local json = require("json")
local sql = require("sql")
local bounds = require("bounds")
return require("migration").define(function()
    migration("Move governance envelope authority to common Grant records", function()
        database("sqlite", function()
            up(function(db)
                local err = schema.ensure(db)
                if err then error(err) end
                local rows = assert(db:query("SELECT * FROM bee_governance_leases"))
                local tx = db
                for _, row in ipairs(rows) do
                    local reserved = assert(tx:query("SELECT COUNT(*) AS n FROM bee_governance_lease_uses WHERE owner_node = ? AND workspace_id = ? AND lease_id = ? AND state = 'reserved'",{row.owner_node,row.workspace_id,row.lease_id}))[1].n
                    local until_ms: integer? = nil
                    if row.expires_at then
                        local time = assert(tx:query("SELECT CAST((julianday(?) - 2440587.5)*86400000 AS INTEGER) AS ms",{row.expires_at}))[1]
                        until_ms = assert(bounds.integer(time.ms))
                    end
                    local grant: grants.Grant = {grant_id = grants.identity("governance_lease",row.owner_node,row.workspace_id,row.lease_id),domain = "governance_lease",owner_node = row.owner_node,workspace_id = row.workspace_id,
                        requester_id = row.owner_node,granted_by = row.granted_by,subject = {principal_id = row.owner_node,audience = row.target},
                        scope = {type = "governance_envelope",parameters = {target = row.target,envelope = json.decode(row.envelope_bytes)}},
                        terms = {kind = "bounded",time_basis = "absolute"},provenance = {kind = "legacy",source = "governance_lease",approval_id = row.source_approval_id,proposal_digest = row.source_approval_proposal_digest},
                        metadata = {lease_id = row.lease_id,target = row.target,envelope_bytes = row.envelope_bytes,envelope_digest = row.envelope_digest,source_approval_proposal_digest = row.source_approval_proposal_digest,source_approval_owner_incarnation = row.source_approval_owner_incarnation},
                        state = row.state,revision = row.revision,used = row.applies_used - reserved,reserved = reserved,until_ms = until_ms,max_uses = row.max_applies,created_at = row.created_at,approval_id = row.source_approval_id,revoked_at = row.revoked_at,revoked_by = row.revoked_by}
                    assert(tx:execute("DELETE FROM bee_approval_grants WHERE domain = 'decision' AND approval_id = ?",{row.source_approval_id}))
                    local create_error = grants.create(tx,grant)
                    if create_error then error(create_error) end
                    for _, use in ipairs(assert(tx:query("SELECT * FROM bee_governance_lease_uses WHERE owner_node = ? AND workspace_id = ? AND lease_id = ?",{row.owner_node,row.workspace_id,row.lease_id}))) do
                        assert(tx:execute("INSERT INTO bee_approval_grant_uses(grant_id,effect_key,request_digest,state,created_at,admitted_at) VALUES (?,?,?,?,?,?)",{grant.grant_id,use.intent_id,use.proposal_snapshot_digest,use.state,use.applied_at,use.admitted_at or sql.NULL}))
                    end
                    assert(tx:execute("UPDATE bee_approval_grant_history SET kind = 'grant.migrated' WHERE grant_id = ?",{grant.grant_id}))
                end
                assert(db:execute("ALTER TABLE bee_governance_lease_uses RENAME TO bee_governance_lease_uses_prev"))
                assert(db:execute([[CREATE TABLE "bee_governance_lease_uses" ( owner_node TEXT NOT NULL, workspace_id TEXT NOT NULL, lease_id TEXT NOT NULL, intent_id TEXT NOT NULL, approval_id TEXT NOT NULL, approval_proposal_digest TEXT NOT NULL CHECK(length(approval_proposal_digest) = 64), proposal_snapshot_bytes BLOB NOT NULL CHECK(length(CAST(proposal_snapshot_bytes AS BLOB)) BETWEEN 1 AND 65536), proposal_snapshot_digest TEXT NOT NULL CHECK(length(proposal_snapshot_digest) = 64), state TEXT NOT NULL CHECK(state IN ('reserved', 'admitted', 'fenced')), applied_at TEXT NOT NULL, admitted_at TEXT, PRIMARY KEY(owner_node, workspace_id, lease_id, intent_id), UNIQUE(owner_node, workspace_id, intent_id) )]]))
                assert(db:execute("INSERT INTO bee_governance_lease_uses SELECT * FROM bee_governance_lease_uses_prev"))
                assert(db:execute("DROP TABLE bee_governance_lease_uses_prev"))
                assert(db:execute("DROP TABLE bee_governance_leases"))
            end)
        end)
    end)
end)
