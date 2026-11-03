-- MIT. A session keeps the name a person or agent gives it; without one its
-- title is the automatic one.
return require("migration").define(function()
    migration("Sessions keep an explicit name", function()
        database("sqlite", function()
            up(function(db)
                assert(db:execute("ALTER TABLE bee_sessions ADD COLUMN name TEXT CHECK(name IS NULL OR length(CAST(name AS BLOB)) BETWEEN 1 AND 128)"))
            end)
            down(function(db)
                assert(db:execute("ALTER TABLE bee_sessions DROP COLUMN name"))
            end)
        end)
    end)
end)
