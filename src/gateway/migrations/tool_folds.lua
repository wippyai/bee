local json = require("json")
local folds = require("folds")
return require("migration").define(function()
    migration("Move binding tool lists to the tools that carry them", function()
        database("sqlite", function()
            up(function(db)
                for _, row in ipairs(assert(db:query("SELECT rowid AS row_id, tools_json FROM bee_gateway_bindings"))) do
                    local names = json.decode(row.tools_json)
                    if type(names) == "table" and folds.any(names) then
                        assert(db:execute("UPDATE bee_gateway_bindings SET tools_json = ? WHERE rowid = ?", {assert(json.encode(folds.names(names))), row.row_id}))
                    end
                end
            end)
        end)
    end)
end)
