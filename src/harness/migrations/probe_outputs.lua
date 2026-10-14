-- MIT. Probe outputs measured from a CLI's executable file, keyed by the
-- file, the probe arguments and the home they ran with.
return require("migration").define(function()
    migration("Create harness probe outputs", function()
        database("sqlite", function()
            up(function(db)
                local _, err = db:execute([[
                    CREATE TABLE bee_harness_probe_outputs (
                        key_digest TEXT PRIMARY KEY,
                        executable_path TEXT NOT NULL,
                        size INTEGER NOT NULL,
                        modified INTEGER NOT NULL,
                        mode INTEGER NOT NULL,
                        exit_code INTEGER NOT NULL,
                        output TEXT NOT NULL CHECK (length(CAST(output AS BLOB)) <= 65536),
                        measured_at TEXT NOT NULL
                    )
                ]])
                if err then error(err) end
            end)
            down(function(db)
                local _, err = db:execute("DROP TABLE IF EXISTS bee_harness_probe_outputs")
                if err then error(err) end
            end)
        end)
    end)
end)
