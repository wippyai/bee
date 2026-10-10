return require("migration").define(function()
    migration("Bind persistent grant revocation effects", function()
        database("sqlite", function()
            up(function(db)
                assert(db:execute([[CREATE TABLE bee_approval_grant_effects (
                    grant_id TEXT NOT NULL REFERENCES bee_approval_grants(grant_id),
                    destination TEXT NOT NULL, effect_id TEXT NOT NULL, context_json TEXT NOT NULL,
                    PRIMARY KEY(grant_id,destination,effect_id))]]))
            end)
        end)
    end)
end)
