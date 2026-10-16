return require("migration").define(function()
    migration("Announce each approval change once from the approval owner", function()
        database("sqlite", function()
            up(function(db)
                local _, err = db:execute([[CREATE TABLE bee_approval_attention (
                    id INTEGER PRIMARY KEY CHECK (id = 1), announced_seq INTEGER NOT NULL)]])
                if err then error(err) end
                _, err = db:execute([[INSERT INTO bee_approval_attention (id, announced_seq)
                    SELECT 1, COALESCE((SELECT seq FROM sqlite_sequence WHERE name = 'bee_approval_inbox'), 0)]])
                if err then error(err) end
            end)
        end)
    end)
end)
