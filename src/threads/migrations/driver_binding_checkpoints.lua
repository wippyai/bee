-- MIT. The built-in CLI drivers live in the bee/drivers module, so carrier
-- checkpoints name the bee/drivers bindings a saved window continues under.
local rewrites = require("rewrites")
return require("migration").define(function()
    migration("Name the bee/drivers bindings in carrier checkpoints", function()
        database("sqlite", function()
            up(function(db)
                for old, new in pairs(rewrites.driver_bindings()) do
                    assert(db:execute("UPDATE bee_thread_carriers SET checkpoint_json = json_set(checkpoint_json, '$.binding_ref', ?) WHERE checkpoint_json IS NOT NULL AND json_extract(checkpoint_json, '$.binding_ref') = ?", {new, old}))
                end
            end)
        end)
    end)
end)
