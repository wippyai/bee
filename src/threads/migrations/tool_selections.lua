local canonical = require("canonical")
local json = require("json")
local rewrites = require("rewrites")
return require("migration").define(function()
    migration("Move retained tool selections beside their traits", function()
        database("sqlite", function()
            up(function(db)
                local rows = assert(rewrites.ids(db, {table = "bee_sessions", column = "route_json"},
                    rewrites.selection_paths("$.effective_profile"), rewrites.RETIRED_TOOLS))
                for _, row in ipairs(rows) do
                    local saved = assert(db:query("SELECT route_json FROM bee_sessions WHERE rowid = ?", {row.row_id}))[1]
                    local route = assert(json.decode(saved.route_json))
                    local digest = assert(canonical.digest(route.effective_profile))
                    assert(db:execute("UPDATE bee_sessions SET route_json = json_set(route_json, '$.profile_digest', ?) WHERE rowid = ?", {digest, row.row_id}))
                end
                for _, name in ipairs({"bee_session_traits", "bee_session_trait_intervals"}) do
                    assert(rewrites.ids(db, {table = name, column = "declaration_json"}, {{arrays = {"$.tools"}}}, rewrites.RETIRED_TOOLS))
                end
            end)
        end)
    end)
end)
