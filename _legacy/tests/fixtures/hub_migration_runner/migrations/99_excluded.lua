local function define_migration()
    migration("Excluded migration", function()
        database("sqlite", function()
            up(function(db)
                local _, err = db:execute("CREATE TABLE probe_excluded (id INTEGER PRIMARY KEY)")
                if err then error(err) end
            end)
            down(function(db)
                local _, err = db:execute("DROP TABLE IF EXISTS probe_excluded")
                if err then error(err) end
            end)
        end)
    end)
end

return {run = migration.define(define_migration)}
