local rewrites = require("rewrites")
return require("migration").define(function()
    migration("Move retained tool selections beside their traits", function()
        database("sqlite", function()
            up(function(db)
                assert(rewrites.ids(db, {table = "bee_approval_grants", column = "scope_json", where = "t.domain = 'profile_choices'"},
                    rewrites.selection_paths("$.parameters.configuration"), rewrites.RETIRED_TOOLS))
                assert(rewrites.ids(db, {table = "bee_approval_grants", column = "scope_json", where = "t.domain = 'gateway_access'"},
                    {{arrays = {"$.parameters.payload.declarations", "$.tools"}}}, rewrites.RETIRED_TOOLS))
            end)
        end)
    end)
end)
