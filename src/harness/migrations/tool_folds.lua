local json = require("json")
local canonical = require("canonical")
local folds = require("folds")
return require("migration").define(function()
    migration("Move saved profile tool selections to the tools that carry them", function()
        database("sqlite", function()
            up(function(db)
                local feeds = {}
                for _, row in ipairs(assert(db:query("SELECT rowid AS row_id, owner_id, feed, value_json FROM bee_sync_projections WHERE feed LIKE 'harness.profiles:%' AND tombstone = 0"))) do
                    local value = json.decode(row.value_json)
                    if type(value) == "table" and folds.profile(value) then
                        assert(db:execute("UPDATE bee_sync_projections SET value_json = ? WHERE rowid = ?", {assert(canonical.encode(value)), row.row_id}))
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
