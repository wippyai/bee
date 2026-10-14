-- MIT. Application test runs: the request a run was made with and the results
-- the node's test runner writes, keyed by run.
return require("migration").define(function()
    migration("Create node test runs", function()
        database("sqlite", function()
            up(function(db)
                local _, err = db:execute([[
                    CREATE TABLE bee_node_test_runs (
                        run_id TEXT PRIMARY KEY,
                        workspace_id TEXT NOT NULL,
                        actor_id TEXT NOT NULL,
                        overlay TEXT NOT NULL,
                        application TEXT NOT NULL,
                        plan_json TEXT NOT NULL,
                        state TEXT NOT NULL,
                        result_json TEXT,
                        created_ms INTEGER NOT NULL
                    )
                ]])
                if err then error(err) end
            end)
            down(function(db)
                local _, err = db:execute("DROP TABLE IF EXISTS bee_node_test_runs")
                if err then error(err) end
            end)
        end)
    end)
end)
