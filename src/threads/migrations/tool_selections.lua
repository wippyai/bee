local canonical = require("canonical")
local json = require("json")
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
                    for _, row in ipairs(assert(db:query([[SELECT t.rowid AS row_id, j.fullkey AS path FROM bee_sessions t, json_tree(t.route_json) j WHERE 1 AND j.type = 'text' AND j.value = ? AND (j.fullkey LIKE '$.effective_profile.bee.mcp[%].tool' OR j.fullkey LIKE '$.effective_profile.mcp_tools[%]' OR j.fullkey LIKE '$.effective_profile.draft.bee.mcp[%].tool' OR j.fullkey LIKE '$.effective_profile.draft.mcp_tools[%]')]], {old}))) do
                        assert(db:execute("UPDATE bee_sessions SET route_json = json_set(route_json, ?, ?) WHERE rowid = ?", {row.path, new, row.row_id}))
                        local saved = assert(db:query("SELECT route_json FROM bee_sessions WHERE rowid = ?", {row.row_id}))[1]
                        local route = assert(json.decode(saved.route_json))
                        local digest = assert(canonical.digest(route.effective_profile))
                        assert(db:execute("UPDATE bee_sessions SET route_json = json_set(route_json, '$.profile_digest', ?) WHERE rowid = ?", {digest, row.row_id}))
                    end
                end
                for old, new in pairs(TOOLS) do
                    for _, row in ipairs(assert(db:query([[SELECT t.rowid AS row_id, j.fullkey AS path FROM bee_session_traits t, json_tree(t.declaration_json) j WHERE 1 AND j.type = 'text' AND j.value = ? AND (j.fullkey LIKE '$.tools[%]')]], {old}))) do
                        assert(db:execute("UPDATE bee_session_traits SET declaration_json = json_set(declaration_json, ?, ?) WHERE rowid = ?", {row.path, new, row.row_id}))
                    end
                end
                for old, new in pairs(TOOLS) do
                    for _, row in ipairs(assert(db:query([[SELECT t.rowid AS row_id, j.fullkey AS path FROM bee_session_trait_intervals t, json_tree(t.declaration_json) j WHERE 1 AND j.type = 'text' AND j.value = ? AND (j.fullkey LIKE '$.tools[%]')]], {old}))) do
                        assert(db:execute("UPDATE bee_session_trait_intervals SET declaration_json = json_set(declaration_json, ?, ?) WHERE rowid = ?", {row.path, new, row.row_id}))
                    end
                end
            end)
        end)
    end)
end)
