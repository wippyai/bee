return require("migration").define(function()
    migration("Record approved configuration base digests", function()
        database("sqlite", function()
            up(function(db)
                local _, err = db:execute([[CREATE TABLE bee_configuration_admissions (
                    workspace_id TEXT NOT NULL, source_ref TEXT NOT NULL, source_path TEXT NOT NULL,
                    digest TEXT NOT NULL, approval_id TEXT NOT NULL,
                    PRIMARY KEY (workspace_id, source_ref, source_path))]])
                if err then error(err) end
            end)
            down(function(db)
                local _, err = db:execute("DROP TABLE bee_configuration_admissions")
                if err then error(err) end
            end)
        end)
    end)
end)
