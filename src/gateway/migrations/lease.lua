-- MIT. A binding records its lease length, so the placement that supervises a
-- live attempt renews the binding for the same term.
return require("migration").define(function()
    migration("Record each gateway binding's lease length", function()
        database("sqlite", function()
            up(function(db)
                local _, add_error = db:execute("ALTER TABLE bee_gateway_bindings ADD COLUMN lease_ms INTEGER CHECK (lease_ms > 0)")
                if add_error then error(add_error) end
                local _, fill_error = db:execute("UPDATE bee_gateway_bindings SET lease_ms = MAX(1, CAST(ROUND((julianday(expires_at) - julianday(created_at)) * 86400000) AS INTEGER))")
                if fill_error then error(fill_error) end
            end)
            down(function(db)
                local _, err = db:execute("ALTER TABLE bee_gateway_bindings DROP COLUMN lease_ms")
                if err then error(err) end
            end)
        end)
    end)
end)
