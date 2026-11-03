local json = require("json")
local canonical = require("canonical")
local folds = require("folds")
return require("migration").define(function()
    migration("Move session tool selections and trait declarations to the tools that carry them", function()
        database("sqlite", function()
            up(function(db)
                for _, row in ipairs(assert(db:query("SELECT rowid AS row_id, route_json FROM bee_sessions"))) do
                    local route = json.decode(row.route_json)
                    local profile = type(route) == "table" and route.effective_profile or nil
                    if type(profile) == "table" and folds.profile(profile) then
                        route.profile_digest = assert(canonical.digest(profile))
                        assert(db:execute("UPDATE bee_sessions SET route_json = ? WHERE rowid = ?", {assert(canonical.encode(route)), row.row_id}))
                    end
                end
                for _, table_name in ipairs({"bee_session_traits", "bee_session_trait_intervals"}) do
                    for _, row in ipairs(assert(db:query("SELECT rowid AS row_id, declaration_json FROM " .. table_name))) do
                        local declaration = json.decode(row.declaration_json)
                        if type(declaration) == "table" and folds.declaration(declaration) then
                            assert(db:execute("UPDATE " .. table_name .. " SET declaration_json = ? WHERE rowid = ?", {assert(canonical.encode(declaration)), row.row_id}))
                        end
                    end
                end
            end)
        end)
    end)
end)
