-- MIT. Probe outputs are executable measurements recorded with the file
-- identity in bee_placement_executable_measurements; the probe output table,
-- whose size and modification time pin no file version, goes. Its rows are
-- measured again on the next probe.
return require("migration").define(function()
    migration("Retire harness probe outputs", function()
        database("sqlite", function()
            up(function(db)
                assert(db:execute("DROP TABLE IF EXISTS bee_harness_probe_outputs"))
            end)
            down(function(db)
                assert(db:execute([[
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
                ]]))
            end)
        end)
    end)
end)
