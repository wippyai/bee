local grants = require("grants")
local canonical = require("canonical")
local bounds = require("bounds")
local clock = require("clock")
local json = require("json")
return require("migration").define(function()
    migration("Separate follow recovery progress from common consent authority", function()
        database("sqlite", function()
            up(function(db)
                assert(db:execute("ALTER TABLE bee_governance_follow RENAME TO bee_governance_follow_progress"))
                for _, raw in ipairs(assert(db:query("SELECT * FROM bee_governance_follow_progress"))) do
                    local row = assert(bounds.object(json.decode(raw.state_json)))
                    local selected_mode = row.mode
                    local id = grants.identity("follow_source",raw.owner_node,raw.workspace_id,assert(canonical.encode({source_node = raw.source_node,source_workspace = raw.source_workspace,component = raw.component,revision = row.revision})))
                    local grant: grants.Grant = {grant_id = id,domain = "follow_source",owner_node = raw.owner_node,workspace_id = raw.workspace_id,requester_id = raw.owner_node,granted_by = "legacy:" .. raw.owner_node,
                        subject = {principal_id = raw.owner_node,audience = raw.component},scope = {type = "follow_source",parameters = {source_node = raw.source_node,source_workspace = raw.source_workspace,component = raw.component}},
                        terms = {kind = "until_revoked",time_basis = "absolute"},provenance = {kind = "legacy",source = "follow_source",consenting_actor = "unrecorded"},metadata = {mode = selected_mode},
                        state = selected_mode == "following" and "active" or "revoked",revision = 1,used = 0,reserved = 0,created_at = clock.now()}
                    local err = grants.create(db,grant)
                    if err then error(err) end
                    row.mode,row.grant_id = nil,id
                    assert(db:execute("UPDATE bee_governance_follow_progress SET state_json = ? WHERE owner_node = ? AND workspace_id = ? AND source_node = ? AND source_workspace = ? AND component = ?",{canonical.encode(row),raw.owner_node,raw.workspace_id,raw.source_node,raw.source_workspace,raw.component}))
                    assert(db:execute("UPDATE bee_approval_grant_history SET kind = 'grant.migrated' WHERE grant_id = ?",{id}))
                end
            end)
        end)
    end)
end)
