-- MIT. The built-in CLI drivers live in the bee/drivers module, so saved
-- profiles and the profile grants that hold their configuration name the
-- bee.drivers bindings.
local BINDINGS = {
    ["bee.driver.agy.binding:binding"] = "bee.drivers.agy.binding:binding",
    ["bee.driver.claude.binding:binding"] = "bee.drivers.claude.binding:binding",
    ["bee.driver.codex.binding:binding"] = "bee.drivers.codex.binding:binding",
    ["bee.driver.grok.binding:binding"] = "bee.drivers.grok.binding:binding",
    ["bee.driver.muse.binding:binding"] = "bee.drivers.muse.binding:binding",
    ["bee.driver.opencode.binding:binding"] = "bee.drivers.opencode.binding:binding",
}
return require("migration").define(function()
    migration("Name the bee/drivers bindings in saved profiles and profile grants", function()
        database("sqlite", function()
            up(function(db)
                local feeds = {}
                for old, new in pairs(BINDINGS) do
                    for _, row in ipairs(assert(db:query([[SELECT t.rowid AS row_id, j.fullkey AS path, t.owner_id, t.feed FROM bee_sync_projections t, json_tree(t.value_json) j WHERE t.feed LIKE 'harness.profiles:%' AND t.tombstone = 0 AND j.type = 'text' AND j.value = ? AND j.key = 'driver_binding_ref' AND j.path IN ('$', '$.draft')]], {old}))) do
                        assert(db:execute("UPDATE bee_sync_projections SET value_json = json_set(value_json, ?, ?) WHERE rowid = ?", {row.path, new, row.row_id}))
                        feeds[row.owner_id .. ":" .. row.feed] = {owner = row.owner_id, feed = row.feed}
                    end
                    assert(db:execute([[UPDATE bee_approval_grants SET scope_json = json_set(scope_json, '$.parameters.configuration.driver_binding_ref', ?) WHERE json_extract(scope_json, '$.parameters.configuration.driver_binding_ref') = ?]], {new, old}))
                end
                for _, feed in pairs(feeds) do
                    assert(db:execute("UPDATE bee_sync_feeds SET head_sequence = head_sequence + 1, earliest_sequence = head_sequence + 2 WHERE owner_id = ? AND feed = ?", {feed.owner, feed.feed}))
                end
            end)
        end)
    end)
end)
