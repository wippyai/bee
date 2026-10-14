return require("migration").define(function()
    migration("Fence approval requests from closed transport origins", function()
        database("sqlite", function()
            up(function(db)
                local _, err = db:execute([[CREATE TABLE bee_approval_closed_origins (
                    requester_id TEXT NOT NULL, instance_id TEXT NOT NULL, closed_at TEXT NOT NULL,
                    PRIMARY KEY (requester_id, instance_id))]])
                if err then error(err) end
            end)
        end)
    end)
end)
