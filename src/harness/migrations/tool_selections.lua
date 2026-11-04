local rewrites = require("rewrites")
return require("migration").define(function()
    migration("Move retained tool selections beside their traits", function()
        database("sqlite", function()
            up(function(db)
                local rows = assert(rewrites.ids(db, {table = "bee_sync_projections", column = "value_json", where = "t.feed LIKE 'harness.profiles:%' AND t.tombstone = 0", columns = {"owner_id", "feed"}},
                    rewrites.selection_paths("$"), rewrites.RETIRED_TOOLS))
                local feeds: {[string]: rewrites.Feed} = {}
                for _, row in ipairs(rows) do
                    feeds[tostring(row.owner_id) .. ":" .. tostring(row.feed)] = {owner = tostring(row.owner_id), feed = tostring(row.feed)}
                end
                assert(not rewrites.fence_feeds(db, feeds))
            end)
        end)
    end)
end)
