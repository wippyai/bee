local json = require("json")
local bounds = require("bounds")
local canonical = require("canonical")
local protocol = require("protocol")
return require("migration").define(function()
    migration("Pin saved driver options to their registry schema", function()
        database("sqlite", function()
            up(function(db)
                local feeds: {[string]: {owner: string, feed: string}} = {}
                for _, row in ipairs(assert(db:query("SELECT owner_id,feed,projection_key,value_json FROM bee_sync_projections WHERE feed LIKE 'harness.profiles:%' AND tombstone = 0"))) do
                    local source = bounds.object(json.decode(row.value_json))
                    if source and source.schema_revision == protocol.SCHEMA then
                        local profile, invalid = protocol.profile(source)
                        local stored: {[string]: unknown}? = nil
                        if profile then stored, invalid = protocol.storage(profile) end
                        if not stored then
                            stored = {schema_revision = "bee.agent-profile-migration@1", source = source, draft = source,
                                reasons = {invalid or "Driver option schema is unavailable"}}
                        end
                        local encoded = assert(canonical.encode(stored))
                        if encoded ~= canonical.encode(source) then
                        assert(db:execute("UPDATE bee_sync_projections SET value_json = ? WHERE owner_id = ? AND feed = ? AND projection_key = ?",
                            {encoded, row.owner_id, row.feed, row.projection_key}))
                        for _, grant in ipairs(assert(db:query("SELECT grant_id,scope_json FROM bee_approval_grants WHERE domain = 'profile_choices' AND owner_node = ? AND json_extract(metadata_json,'$.profile_id') = ?", {row.owner_id, row.projection_key}))) do
                            local scope = assert(bounds.object(json.decode(grant.scope_json)))
                            local parameters = bounds.object(scope.parameters)
                            if parameters and canonical.encode(parameters.configuration) == canonical.encode(source) then
                                parameters.configuration = stored
                                assert(db:execute("UPDATE bee_approval_grants SET scope_json = ? WHERE grant_id = ?", {assert(canonical.encode(scope)), grant.grant_id}))
                            end
                        end
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
