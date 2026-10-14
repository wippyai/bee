local hash = require("hash")
local json = require("json")
local bounds = require("bounds")
local authority = require("authority")
return require("migration").define(function()
    migration("Move saved profile authority to common Grants",function()
        database("sqlite",function()
            up(function(db)
                local workspaces: {[string]: string} = {}
                for _, row in ipairs(assert(db:query("SELECT id FROM bee_node_workspaces"))) do workspaces["harness.profiles:" .. assert(hash.sha256(row.id))] = row.id end
                for _, row in ipairs(assert(db:query("SELECT feed,payload_json FROM bee_sync_events WHERE feed LIKE 'harness.profiles:%'"))) do
                    local payload = bounds.object(json.decode(row.payload_json))
                    local workspace = payload and bounds.id(payload.workspace_id)
                    if workspace and row.feed == "harness.profiles:" .. hash.sha256(workspace) then workspaces[row.feed] = workspace end
                end
                for _, row in ipairs(assert(db:query("SELECT feed,request_json FROM bee_sync_receipts WHERE feed LIKE 'harness.profiles:%'"))) do
                    local request = bounds.object(json.decode(row.request_json))
                    local payload = request and bounds.object(request.payload)
                    local workspace = payload and bounds.id(payload.workspace_id)
                    if workspace and row.feed == "harness.profiles:" .. hash.sha256(workspace) then workspaces[row.feed] = workspace end
                end
                for _, row in ipairs(assert(db:query("SELECT p.*,e.payload_json FROM bee_sync_projections p LEFT JOIN bee_sync_events e ON p.owner_id = e.owner_id AND p.feed = e.feed AND p.last_sequence = e.sequence AND p.projection_key = e.projection_key AND p.revision = e.projection_revision WHERE p.feed LIKE 'harness.profiles:%' AND p.tombstone = 0"))) do
                    local workspace = workspaces[row.feed] or "legacy:" .. row.feed
                    local payload = type(row.payload_json) == "string" and bounds.object(json.decode(row.payload_json)) or nil
                    if workspace then
                        local record, err = authority.save(db,row.owner_id,workspace,row.projection_key,row.revision,json.decode(row.value_json),payload and bounds.id(payload.actor_id) or "legacy:" .. row.owner_id,true,row.updated_at)
                        if not record then error(err) end
                        if not workspaces[row.feed] then
                            assert(db:execute("UPDATE bee_approval_grants SET state = 'revoked' WHERE grant_id = ?",{record.grant_id}))
                        end
                    end
                end
            end)
        end)
    end)
end)
