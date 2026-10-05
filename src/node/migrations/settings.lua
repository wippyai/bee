-- MIT. Node settings, one string value per key.
return require("migration").define(function()
    migration("Create node settings", function()
        database("sqlite", function()
            up(function(db)
                local _, err = db:execute([[
                    CREATE TABLE bee_node_settings (
                        key TEXT PRIMARY KEY,
                        value TEXT NOT NULL
                    )
                ]])
                if err then error(err) end
            end)
            down(function(db)
                local _, err = db:execute("DROP TABLE IF EXISTS bee_node_settings")
                if err then error(err) end
            end)
        end)
    end)
end)
