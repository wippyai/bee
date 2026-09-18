local function define_migration()
    migration("Create probe users", function()
        database("sqlite", function()
            up(function(db)
                local _, err = db:execute("CREATE TABLE probe_users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
                if err then error(err) end
                local _, insert_err = db:execute("INSERT INTO probe_users (name) VALUES ('first')")
                if insert_err then error(insert_err) end
            end)
            down(function(db)
                local _, err = db:execute("DROP TABLE IF EXISTS probe_users")
                if err then error(err) end
            end)
        end)
    end)
end

return {run = migration.define(define_migration)}
