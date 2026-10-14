-- MIT. A grant records its lease length, so the placement that supervises a
-- live attempt renews the grant for the same term.
return require("migration").define(function()
    migration("Record each resource grant's lease length", function()
        database("sqlite", function()
            up(function(db)
                local _, add_error = db:execute("ALTER TABLE bee_resource_grants ADD COLUMN lease_ms INTEGER CHECK (lease_ms > 0)")
                if add_error then error(add_error) end
                local _, fill_error = db:execute("UPDATE bee_resource_grants SET lease_ms = MAX(1, CAST(ROUND((julianday(expires_at) - julianday(created_at)) * 86400000) AS INTEGER))")
                if fill_error then error(fill_error) end
            end)
            down(function(db)
                local _, err = db:execute("ALTER TABLE bee_resource_grants DROP COLUMN lease_ms")
                if err then error(err) end
            end)
        end)
    end)
end)
