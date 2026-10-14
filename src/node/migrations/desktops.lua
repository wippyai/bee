-- MIT. Desktops: named sets of apps on a workspace, and the app instances
-- each holds, kept so a node restores its desktops when it starts.
return require("migration").define(function()
    migration("Create desktops and their app instances", function()
        database("sqlite", function()
            up(function(db)
                local _, err = db:execute([[
                    CREATE TABLE bee_node_desktops (
                        id TEXT PRIMARY KEY,
                        workspace_id TEXT NOT NULL REFERENCES bee_node_workspaces(id) ON DELETE CASCADE,
                        title TEXT NOT NULL,
                        created_at TEXT NOT NULL
                    )
                ]])
                if err then error(err) end
                _, err = db:execute([[
                    CREATE TABLE bee_node_instances (
                        id TEXT PRIMARY KEY,
                        desktop_id TEXT NOT NULL REFERENCES bee_node_desktops(id) ON DELETE CASCADE,
                        app TEXT NOT NULL,
                        args TEXT NOT NULL,
                        created_at TEXT NOT NULL
                    )
                ]])
                if err then error(err) end
            end)
            down(function(db)
                local _, err = db:execute("DROP TABLE IF EXISTS bee_node_instances")
                if err then error(err) end
                _, err = db:execute("DROP TABLE IF EXISTS bee_node_desktops")
                if err then error(err) end
            end)
        end)
    end)
end)
