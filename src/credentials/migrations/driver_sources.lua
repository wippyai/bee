-- MIT. The built-in drivers' API key variables live in the bee/drivers module,
-- so workspace credential definitions name the bee/drivers sources. Each
-- variable keeps its storage and name, so a definition keeps its destination
-- and its measurement changes only by the source it names.
local canonical = require("canonical")
local rewrites = require("rewrites")
type Variable = {storage: string, variable: string, readonly: boolean?}
local VARIABLES: {[string]: Variable} = {
    agy = {storage = "bee.credentials.env:entered_values", variable = "agy_api_key"},
    claude = {storage = "bee.harness.host:environment", variable = "ANTHROPIC_API_KEY", readonly = true},
    grok = {storage = "bee.credentials.env:entered_values", variable = "grok_api_key"},
    muse = {storage = "bee.credentials.env:entered_values", variable = "muse_api_key"},
}
return require("migration").define(function()
    migration("Name the bee/drivers API key sources in credential definitions", function()
        database("sqlite", function()
            up(function(db)
                for provider, variable in pairs(VARIABLES) do
                    local old, ref = rewrites.driver_entry(provider, "env:api_key")
                    local rows = assert(db:query("SELECT workspace_id, name, provider, destination, optional FROM bee_credential_definitions WHERE source_kind = 'env_variable' AND source_ref = ?", {old}))
                    for _, row in ipairs(rows) do
                        local digest = assert(canonical.digest({provider = row.provider, source_kind = "env_variable", source_ref = ref,
                            variable = {kind = "env.variable", storage = variable.storage, variable = variable.variable, readonly = variable.readonly},
                            projection_kind = "environment", destination = row.destination, optional = row.optional == 1}))
                        assert(db:execute("UPDATE bee_credential_definitions SET source_ref = ?, digest = ? WHERE workspace_id = ? AND name = ?",
                            {ref, digest, row.workspace_id, row.name}))
                    end
                end
            end)
        end)
    end)
end)
