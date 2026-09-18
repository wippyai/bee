local function define_migration()
    migration("Add probe audit", function()
        database("sqlite", function()
            up(function(db)
                local _, err = db:execute("CREATE TABLE probe_audit (id INTEGER PRIMARY KEY, event TEXT NOT NULL)")
                if err then error(err) end
                local _, insert_err = db:execute("INSERT INTO probe_audit (event) VALUES ('second')")
                if insert_err then error(insert_err) end
            end)
            down(function(db)
                local _, err = db:execute("DROP TABLE IF EXISTS probe_audit")
                if err then error(err) end
            end)
        end)
    end)
end

return {run = migration.define(define_migration)}
