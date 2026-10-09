return require("migration").define(function()
    migration("Record configuration setup effect receipts", function()
        database("sqlite", function()
            up(function(db)
                local _, err = db:execute("CREATE TABLE bee_configuration_effects (approval_id TEXT PRIMARY KEY, receipt_json TEXT NOT NULL)")
                if err then error(err) end
            end)
            down(function(db)
                local _, err = db:execute("DROP TABLE bee_configuration_effects")
                if err then error(err) end
            end)
        end)
    end)
end)
