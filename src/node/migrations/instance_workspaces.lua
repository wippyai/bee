-- MIT. A kept app instance names the workspace it was opened in, so it comes
-- back there even after its desktop moves to another workspace. Instances
-- kept before name their desktop's workspace.
return require("migration").define(function()
    migration("Kept instances name their workspace", function()
        database("sqlite", function()
            up(function(db)
                local _, err = db:execute("ALTER TABLE bee_node_instances ADD COLUMN workspace_id TEXT REFERENCES bee_node_workspaces(id) ON DELETE CASCADE")
                if err then error(err) end
                _, err = db:execute([[UPDATE bee_node_instances SET workspace_id =
                    (SELECT workspace_id FROM bee_node_desktops WHERE bee_node_desktops.id = bee_node_instances.desktop_id)]])
                if err then error(err) end
            end)
        end)
    end)
end)
