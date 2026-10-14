local json = require("json")
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
local mcp = require("mcp")
return require("migration").define(function()
    migration("Represent saved consent tools as active profile traits", function()
        database("sqlite", function()
            up(function(db)
                local feeds: {[string]: {owner: string, feed: string}} = {}
                for _, row in ipairs(assert(db:query([[SELECT p.owner_id,p.feed,p.projection_key,p.value_json,g.grant_id,g.scope_json,g.provenance_json,g.workspace_id
                    FROM bee_sync_projections p JOIN bee_approval_grants g ON g.domain = 'profile_choices'
                    AND g.owner_node = p.owner_id AND json_extract(g.metadata_json,'$.profile_id') = p.projection_key
                    AND json_extract(g.metadata_json,'$.profile_revision') = p.revision
                    WHERE p.feed LIKE 'harness.profiles:%' AND p.tombstone = 0]]))) do
                    local profile = assert(bounds.object(json.decode(row.value_json)))
                    local scope = assert(bounds.object(json.decode(row.scope_json)))
                    local provenance = assert(bounds.object(json.decode(row.provenance_json)))
                    local parameters = assert(bounds.object(scope.parameters))
                    local active = bounds.ids(profile.active_traits or {}, true)
                    local requestable = bounds.ids(profile.requestable or {}, true)
                    if profile.schema_revision == "bee.agent-profile@3" and active and #active == 0 and requestable and #requestable == 0
                        and row.feed == "harness.profiles:" .. hash.sha256(row.workspace_id)
                        and canonical.encode(parameters.configuration) == canonical.encode(profile) then
                        local bee = bounds.object(profile.bee)
                        local chosen: {[string]: boolean} = {}
                        for _, raw in ipairs(bee and bounds.array(bee.mcp, 64) or {}) do
                            local item = bounds.object(raw)
                            local tool = item and bounds.id(item.tool)
                            if tool then chosen[tool] = true end
                        end
                        for _, trait in ipairs(mcp.CONSENT_TRAITS) do
                            for _, name in ipairs(trait.tools) do
                                if chosen[name] then active[#active + 1] = trait.id; break end
                            end
                        end
                        if #active > 0 then
                            profile.active_traits, profile.requestable = active, requestable
                            parameters.configuration = profile
                            if provenance.kind == "legacy" then provenance.kind = "consent"; provenance.source = "saved_profile_migration" end
                            assert(db:execute("UPDATE bee_sync_projections SET value_json = ? WHERE owner_id = ? AND feed = ? AND projection_key = ?",
                                {assert(canonical.encode(profile)), row.owner_id, row.feed, row.projection_key}))
                            assert(db:execute("UPDATE bee_approval_grants SET scope_json = ?, provenance_json = ? WHERE grant_id = ?",
                                {assert(canonical.encode(scope)), assert(canonical.encode(provenance)), row.grant_id}))
                            feeds[row.owner_id .. ":" .. row.feed] = {owner = row.owner_id, feed = row.feed}
                        end
                    end
                end
                for _, item in pairs(feeds) do
                    assert(db:execute("UPDATE bee_sync_feeds SET head_sequence = head_sequence + 1, earliest_sequence = head_sequence + 2 WHERE owner_id = ? AND feed = ?", {item.owner, item.feed}))
                end
            end)
        end)
    end)
end)
