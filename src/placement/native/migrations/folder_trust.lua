return require("migration").define(function()
    migration("Track isolated folder trust lifetime", function()
        database("sqlite", function()
            up(function(db)
                assert(db:execute([[CREATE TABLE bee_placement_trust (
                    attempt_id TEXT PRIMARY KEY REFERENCES bee_placement_attempts(attempt_id),
                    grant_id TEXT NOT NULL, home_path TEXT NOT NULL UNIQUE, mapping_json TEXT NOT NULL)]]))
                assert(db:execute("CREATE INDEX bee_placement_trust_grant ON bee_placement_trust(grant_id)"))
            end)
        end)
    end)
end)
