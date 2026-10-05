-- MIT. Workspace identities take their canonical form, 32 lowercase hex
-- digits, in the workspaces and the desktops that work in them.
return require("migration").define(function()
    migration("Canonical workspace identities", function()
        database("sqlite", function()
            up(function(db)
                local _, err = db:execute("PRAGMA defer_foreign_keys = ON")
                if err then error(err) end
                _, err = db:execute("UPDATE bee_node_workspaces SET id = lower(replace(id, '-', '')) WHERE id LIKE '%-%'")
                if err then error(err) end
                _, err = db:execute("UPDATE bee_node_desktops SET workspace_id = lower(replace(workspace_id, '-', '')) WHERE workspace_id LIKE '%-%'")
                if err then error(err) end
            end)
        end)
    end)
end)
