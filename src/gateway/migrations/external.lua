-- SPDX-License-Identifier: MIT
return require("migration").define(function()
    migration("Record external MCP principals", function()
        database("sqlite", function()
            up(function(db)
                local _, err = db:execute([[CREATE TABLE bee_gateway_external_clients (
                    client_id TEXT PRIMARY KEY,
                    name TEXT NOT NULL CHECK(length(CAST(name AS BLOB)) BETWEEN 1 AND 80),
                    workspace_id TEXT NOT NULL,
                    caller TEXT NOT NULL,
                    binding_id TEXT NOT NULL UNIQUE REFERENCES bee_gateway_bindings(binding_id),
                    approval_id TEXT,
                    issued INTEGER NOT NULL DEFAULT 0 CHECK(issued IN (0, 1)),
                    created_at TEXT NOT NULL
                )]])
                if err then error(err) end
                local _, index_error = db:execute("CREATE INDEX bee_gateway_external_workspace ON bee_gateway_external_clients(workspace_id, created_at)")
                if index_error then error(index_error) end
            end)
            down(function(db)
                local _, err = db:execute("DROP TABLE bee_gateway_external_clients")
                if err then error(err) end
            end)
        end)
    end)
end)
