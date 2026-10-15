local TOOLS = {
    ["bee.gov.binding:overlay_call"] = "bee.gov.traits:overlay_call",
    ["bee.gov.binding:delivery_call"] = "bee.gov.traits:delivery_call",
    ["bee.node.binding:tests_call"] = "bee.gov.traits:tests_call",
    ["bee.hub.binding:call"] = "bee.hub.traits:call",
    ["bee.docs.binding:call"] = "bee.docs.traits:call",
}
return require("migration").define(function()
    migration("Move retained tool selections beside their traits", function()
        database("sqlite", function()
            up(function(db)
                for old, new in pairs(TOOLS) do
                    for _, row in ipairs(assert(db:query([[SELECT t.rowid AS row_id, j.fullkey AS path FROM bee_approval_grants t, json_tree(t.scope_json) j WHERE t.domain = 'profile_choices' AND j.type = 'text' AND j.value = ? AND (j.fullkey LIKE '$.parameters.configuration.bee.mcp[%].tool' OR j.fullkey LIKE '$.parameters.configuration.mcp_tools[%]' OR j.fullkey LIKE '$.parameters.configuration.draft.bee.mcp[%].tool' OR j.fullkey LIKE '$.parameters.configuration.draft.mcp_tools[%]')]], {old}))) do
                        assert(db:execute("UPDATE bee_approval_grants SET scope_json = json_set(scope_json, ?, ?) WHERE rowid = ?", {row.path, new, row.row_id}))
                    end
                end
                for old, new in pairs(TOOLS) do
                    for _, row in ipairs(assert(db:query([[SELECT t.rowid AS row_id, j.fullkey AS path FROM bee_approval_grants t, json_tree(t.scope_json) j WHERE t.domain = 'gateway_access' AND j.type = 'text' AND j.value = ? AND (j.fullkey LIKE '$.parameters.payload.declarations[%].tools[%]')]], {old}))) do
                        assert(db:execute("UPDATE bee_approval_grants SET scope_json = json_set(scope_json, ?, ?) WHERE rowid = ?", {row.path, new, row.row_id}))
                    end
                end
            end)
        end)
    end)
end)
