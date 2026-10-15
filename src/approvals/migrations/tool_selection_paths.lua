local TOOLS = {
    ["bee.gov.binding:overlay_call"] = "bee.gov.traits:overlay_call",
    ["bee.gov.binding:delivery_call"] = "bee.gov.traits:delivery_call",
    ["bee.node.binding:tests_call"] = "bee.gov.traits:tests_call",
    ["bee.hub.binding:call"] = "bee.hub.traits:call",
    ["bee.docs.binding:call"] = "bee.docs.traits:call",
}
return require("migration").define(function()
    migration("Repair retained tool selections across SQLite JSON path formats", function()
        database("sqlite", function()
            up(function(db)
                for old, new in pairs(TOOLS) do
                    for _, row in ipairs(assert(db:query([[SELECT t.rowid AS row_id, '$.parameters.configuration.bee.mcp[' || j.key || '].tool' AS path FROM bee_approval_grants t, json_each(t.scope_json, '$.parameters.configuration.bee.mcp') j WHERE t.domain = 'profile_choices' AND typeof(j.key) = 'integer' AND j.type = 'object' AND CASE WHEN j.type = 'object' THEN json_extract(j.value, '$.tool') END = ?1
UNION ALL
SELECT t.rowid AS row_id, '$.parameters.configuration.mcp_tools[' || j.key || ']' AS path FROM bee_approval_grants t, json_each(t.scope_json, '$.parameters.configuration.mcp_tools') j WHERE t.domain = 'profile_choices' AND typeof(j.key) = 'integer' AND j.type = 'text' AND j.value = ?1
UNION ALL
SELECT t.rowid AS row_id, '$.parameters.configuration.draft.bee.mcp[' || j.key || '].tool' AS path FROM bee_approval_grants t, json_each(t.scope_json, '$.parameters.configuration.draft.bee.mcp') j WHERE t.domain = 'profile_choices' AND typeof(j.key) = 'integer' AND j.type = 'object' AND CASE WHEN j.type = 'object' THEN json_extract(j.value, '$.tool') END = ?1
UNION ALL
SELECT t.rowid AS row_id, '$.parameters.configuration.draft.mcp_tools[' || j.key || ']' AS path FROM bee_approval_grants t, json_each(t.scope_json, '$.parameters.configuration.draft.mcp_tools') j WHERE t.domain = 'profile_choices' AND typeof(j.key) = 'integer' AND j.type = 'text' AND j.value = ?1]], {old}))) do
                        assert(db:execute("UPDATE bee_approval_grants SET scope_json = json_set(scope_json, ?, ?) WHERE rowid = ?", {row.path, new, row.row_id}))
                    end
                end
                for old, new in pairs(TOOLS) do
                    for _, row in ipairs(assert(db:query([[SELECT t.rowid AS row_id, '$.parameters.payload.declarations[' || d.key || '].tools[' || j.key || ']' AS path FROM bee_approval_grants t, json_each(t.scope_json, '$.parameters.payload.declarations') d, json_each(CASE WHEN d.type = 'object' THEN d.value ELSE '{}' END, '$.tools') j WHERE t.domain = 'gateway_access' AND typeof(d.key) = 'integer' AND typeof(j.key) = 'integer' AND j.type = 'text' AND j.value = ?1]], {old}))) do
                        assert(db:execute("UPDATE bee_approval_grants SET scope_json = json_set(scope_json, ?, ?) WHERE rowid = ?", {row.path, new, row.row_id}))
                    end
                end
            end)
        end)
    end)
end)
