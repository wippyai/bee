-- MIT. Frozen credential formats move to bee.credential-format@2: a single
-- environment_destination becomes the one-entry environments list, so stored
-- definitions and projections keep their destinations under the shared
-- bee/drivers decoder.
local TABLES = {"bee_credential_definitions", "bee_credential_projections"}
return require("migration").define(function()
    migration("Carry frozen credential formats to bee.credential-format@2", function()
        database("sqlite", function()
            up(function(db)
                for _, name in ipairs(TABLES) do
                    local _, err = db:execute("UPDATE " .. name .. [[ SET format_json = json_set(json_remove(format_json, '$.environment_destination'),
                        '$.schema_revision', 'bee.credential-format@2',
                        '$.environments', CASE WHEN json_extract(format_json, '$.environment_destination') IS NULL THEN json('[]')
                            ELSE json_array(json_extract(format_json, '$.environment_destination')) END)
                        WHERE format_json <> '' AND json_extract(format_json, '$.schema_revision') = 'bee.credential-format@1']])
                    if err then error(err) end
                end
            end)
        end)
    end)
end)
