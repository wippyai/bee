-- MIT. The built-in CLI drivers live in the bee/drivers module, so carrier
-- checkpoints name the bee/drivers bindings a saved window continues under.
local BINDINGS = {
    ["bee.driver.agy.binding:binding"] = "bee.drivers.agy.binding:binding",
    ["bee.driver.claude.binding:binding"] = "bee.drivers.claude.binding:binding",
    ["bee.driver.codex.binding:binding"] = "bee.drivers.codex.binding:binding",
    ["bee.driver.grok.binding:binding"] = "bee.drivers.grok.binding:binding",
    ["bee.driver.muse.binding:binding"] = "bee.drivers.muse.binding:binding",
    ["bee.driver.opencode.binding:binding"] = "bee.drivers.opencode.binding:binding",
}
return require("migration").define(function()
    migration("Name the bee/drivers bindings in carrier checkpoints", function()
        database("sqlite", function()
            up(function(db)
                for old, new in pairs(BINDINGS) do
                    assert(db:execute("UPDATE bee_thread_carriers SET checkpoint_json = json_set(checkpoint_json, '$.binding_ref', ?) WHERE checkpoint_json IS NOT NULL AND json_extract(checkpoint_json, '$.binding_ref') = ?", {new, old}))
                end
            end)
        end)
    end)
end)
