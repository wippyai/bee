-- MIT
return require("migration").define(function()
    migration("Create Hive mutation receipts", function()
        database("sqlite", function()
            up(function(db)
                local _, err = db:execute([[CREATE TABLE bee_hive_receipts (
                    receipt_key TEXT PRIMARY KEY,
                    fingerprint TEXT NOT NULL,
                    reply_json TEXT
                )]])
                if err then error(err) end
            end)
            down(function(db)
                local _, err = db:execute("DROP TABLE IF EXISTS bee_hive_receipts")
                if err then error(err) end
            end)
        end)
    end)
end)
