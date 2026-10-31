-- MIT. The built-in drivers' API key variables live in the bee/drivers module,
-- so workspace credential definitions name the bee/drivers sources. Each
-- variable keeps its storage and name, so a definition keeps its destination
-- and its measurement changes only by the source it names.
local canonical = require("canonical")
type Variable = {storage: string, variable: string, readonly: boolean?}
local SOURCES: {[string]: {ref: string, variable: Variable}} = {
    ["bee.driver.agy.env:api_key"] = {ref = "bee.drivers.agy.env:api_key", variable = {storage = "bee.credentials.env:entered_values", variable = "agy_api_key"}},
    ["bee.driver.claude.env:api_key"] = {ref = "bee.drivers.claude.env:api_key", variable = {storage = "bee.harness.host:environment", variable = "ANTHROPIC_API_KEY", readonly = true}},
    ["bee.driver.grok.env:api_key"] = {ref = "bee.drivers.grok.env:api_key", variable = {storage = "bee.credentials.env:entered_values", variable = "grok_api_key"}},
    ["bee.driver.muse.env:api_key"] = {ref = "bee.drivers.muse.env:api_key", variable = {storage = "bee.credentials.env:entered_values", variable = "muse_api_key"}},
}
return require("migration").define(function()
    migration("Name the bee/drivers API key sources in credential definitions", function()
        database("sqlite", function()
            up(function(db)
                for old, source in pairs(SOURCES) do
                    local rows = assert(db:query("SELECT workspace_id, name, provider, destination, optional FROM bee_credential_definitions WHERE source_kind = 'env_variable' AND source_ref = ?", {old}))
                    for _, row in ipairs(rows) do
                        local digest = assert(canonical.digest({provider = row.provider, source_kind = "env_variable", source_ref = source.ref,
                            variable = {kind = "env.variable", storage = source.variable.storage, variable = source.variable.variable, readonly = source.variable.readonly},
                            projection_kind = "environment", destination = row.destination, optional = row.optional == 1}))
                        assert(db:execute("UPDATE bee_credential_definitions SET source_ref = ?, digest = ? WHERE workspace_id = ? AND name = ?",
                            {source.ref, digest, row.workspace_id, row.name}))
                    end
                end
            end)
        end)
    end)
end)
