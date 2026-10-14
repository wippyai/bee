-- MIT. Creates the gateway store in the node database.
local schema = require("schema")

return require("migration").define(function()
    migration("Create the gateway store", function()
        database("sqlite", function()
            up(function(db)
                for _, statement in ipairs(schema.STATEMENTS) do
                    local _, err = db:execute(statement)
                    if err then error(err) end
                end
            end)
            down(function(db)
                for _, name in ipairs(schema.TABLES) do
                    local _, err = db:execute("DROP TABLE IF EXISTS " .. name)
                    if err then error(err) end
                end
            end)
        end)
    end)
end)
