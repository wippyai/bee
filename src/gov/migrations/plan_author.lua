-- MIT. Let a staged plan keep the name of the agent that made its version.
return require("migration").define(function()
    migration("Record the agent that made a staged application version", function()
        database("sqlite", function()
            up(function(db)
                local _, err = db:execute([[ALTER TABLE bee_governance_plans ADD COLUMN author TEXT CHECK(author IS NULL OR length(CAST(author AS BLOB)) BETWEEN 1 AND 320)]])
                if err then error(err) end
            end)
        end)
    end)
end)
