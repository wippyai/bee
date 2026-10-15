local TOOLS = {
    ["bee.gov.binding:overlay_call"] = "bee.gov.traits:overlay_call",
    ["bee.gov.binding:delivery_call"] = "bee.gov.traits:delivery_call",
    ["bee.node.binding:tests_call"] = "bee.gov.traits:tests_call",
    ["bee.hub.binding:call"] = "bee.hub.traits:call",
    ["bee.docs.binding:call"] = "bee.docs.traits:call",
}
return require("migration").define(function()
    migration("Repair retained tool selections across SQLite JSON path formats", function()
        database("sqlite", function()
            up(function(db)
                local feeds = {}
                for old, new in pairs(TOOLS) do
                    for _, row in ipairs(assert(db:query([[SELECT t.rowid AS row_id, '$.bee.mcp[' || j.key || '].tool' AS path, t.owner_id, t.feed FROM bee_sync_projections t, json_each(t.value_json, '$.bee.mcp') j WHERE t.feed LIKE 'harness.profiles:%' AND t.tombstone = 0 AND typeof(j.key) = 'integer' AND j.type = 'object' AND CASE WHEN j.type = 'object' THEN json_extract(j.value, '$.tool') END = ?1
UNION ALL
SELECT t.rowid AS row_id, '$.mcp_tools[' || j.key || ']' AS path, t.owner_id, t.feed FROM bee_sync_projections t, json_each(t.value_json, '$.mcp_tools') j WHERE t.feed LIKE 'harness.profiles:%' AND t.tombstone = 0 AND typeof(j.key) = 'integer' AND j.type = 'text' AND j.value = ?1
UNION ALL
SELECT t.rowid AS row_id, '$.draft.bee.mcp[' || j.key || '].tool' AS path, t.owner_id, t.feed FROM bee_sync_projections t, json_each(t.value_json, '$.draft.bee.mcp') j WHERE t.feed LIKE 'harness.profiles:%' AND t.tombstone = 0 AND typeof(j.key) = 'integer' AND j.type = 'object' AND CASE WHEN j.type = 'object' THEN json_extract(j.value, '$.tool') END = ?1
UNION ALL
SELECT t.rowid AS row_id, '$.draft.mcp_tools[' || j.key || ']' AS path, t.owner_id, t.feed FROM bee_sync_projections t, json_each(t.value_json, '$.draft.mcp_tools') j WHERE t.feed LIKE 'harness.profiles:%' AND t.tombstone = 0 AND typeof(j.key) = 'integer' AND j.type = 'text' AND j.value = ?1]], {old}))) do
                        assert(db:execute("UPDATE bee_sync_projections SET value_json = json_set(value_json, ?, ?) WHERE rowid = ?", {row.path, new, row.row_id}))
                        feeds[row.owner_id .. ":" .. row.feed] = {owner = row.owner_id, feed = row.feed}
                    end
                end
                for _, feed in pairs(feeds) do
                    assert(db:execute("UPDATE bee_sync_feeds SET head_sequence = head_sequence + 1, earliest_sequence = head_sequence + 2 WHERE owner_id = ? AND feed = ?", {feed.owner, feed.feed}))
                end
            end)
        end)
    end)
end)
