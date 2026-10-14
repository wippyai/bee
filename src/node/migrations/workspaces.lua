-- MIT. The node's workspace locations.
return require("migration").define(function()
    migration("Create node workspaces", function()
        database("sqlite", function()
            up(function(db)
                local _, err = db:execute([[
                    CREATE TABLE bee_node_workspaces (
                        id TEXT PRIMARY KEY,
                        path TEXT NOT NULL UNIQUE,
                        label TEXT NOT NULL,
                        created_at TEXT NOT NULL
                    )
                ]])
                if err then error(err) end
            end)
            down(function(db)
                local _, err = db:execute("DROP TABLE IF EXISTS bee_node_workspaces")
                if err then error(err) end
            end)
        end)
    end)
end)
