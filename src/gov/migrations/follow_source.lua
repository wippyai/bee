-- MIT. Destination-local source following.
return require("migration").define(function()
    migration("Persist application following consent and publication progress", function()
        database("sqlite", function()
            up(function(db)
                local _, err = db:execute([[CREATE TABLE bee_governance_follow (owner_node TEXT NOT NULL, workspace_id TEXT NOT NULL, source_node TEXT NOT NULL, source_workspace TEXT NOT NULL, component TEXT NOT NULL, state_json TEXT NOT NULL, PRIMARY KEY(owner_node, workspace_id, source_node, source_workspace, component))]])
                if err then error(err) end
            end)
        end)
    end)
end)
