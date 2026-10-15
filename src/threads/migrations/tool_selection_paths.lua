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
    migration("Repair retained tool selections across SQLite JSON path formats", function()
        database("sqlite", function()
            up(function(db)
                for old, new in pairs(TOOLS) do
                    for _, row in ipairs(assert(db:query([[SELECT t.rowid AS row_id, '$.effective_profile.bee.mcp[' || j.key || '].tool' AS path FROM bee_sessions t, json_each(t.route_json, '$.effective_profile.bee.mcp') j WHERE 1 AND typeof(j.key) = 'integer' AND j.type = 'object' AND CASE WHEN j.type = 'object' THEN json_extract(j.value, '$.tool') END = ?1
UNION ALL
SELECT t.rowid AS row_id, '$.effective_profile.mcp_tools[' || j.key || ']' AS path FROM bee_sessions t, json_each(t.route_json, '$.effective_profile.mcp_tools') j WHERE 1 AND typeof(j.key) = 'integer' AND j.type = 'text' AND j.value = ?1
UNION ALL
SELECT t.rowid AS row_id, '$.effective_profile.draft.bee.mcp[' || j.key || '].tool' AS path FROM bee_sessions t, json_each(t.route_json, '$.effective_profile.draft.bee.mcp') j WHERE 1 AND typeof(j.key) = 'integer' AND j.type = 'object' AND CASE WHEN j.type = 'object' THEN json_extract(j.value, '$.tool') END = ?1
UNION ALL
SELECT t.rowid AS row_id, '$.effective_profile.draft.mcp_tools[' || j.key || ']' AS path FROM bee_sessions t, json_each(t.route_json, '$.effective_profile.draft.mcp_tools') j WHERE 1 AND typeof(j.key) = 'integer' AND j.type = 'text' AND j.value = ?1]], {old}))) do
                        assert(db:execute("UPDATE bee_sessions SET route_json = json_set(route_json, ?, ?) WHERE rowid = ?", {row.path, new, row.row_id}))
                        local saved = assert(db:query("SELECT route_json FROM bee_sessions WHERE rowid = ?", {row.row_id}))[1]
                        local route = assert(json.decode(saved.route_json))
                        local digest = assert(canonical.digest(route.effective_profile))
                        assert(db:execute("UPDATE bee_sessions SET route_json = json_set(route_json, '$.profile_digest', ?) WHERE rowid = ?", {digest, row.row_id}))
                    end
                end
                for old, new in pairs(TOOLS) do
                    for _, row in ipairs(assert(db:query([[SELECT t.rowid AS row_id, '$.tools[' || j.key || ']' AS path FROM bee_session_traits t, json_each(t.declaration_json, '$.tools') j WHERE 1 AND typeof(j.key) = 'integer' AND j.type = 'text' AND j.value = ?1]], {old}))) do
                        assert(db:execute("UPDATE bee_session_traits SET declaration_json = json_set(declaration_json, ?, ?) WHERE rowid = ?", {row.path, new, row.row_id}))
                    end
                end
                for old, new in pairs(TOOLS) do
                    for _, row in ipairs(assert(db:query([[SELECT t.rowid AS row_id, '$.tools[' || j.key || ']' AS path FROM bee_session_trait_intervals t, json_each(t.declaration_json, '$.tools') j WHERE 1 AND typeof(j.key) = 'integer' AND j.type = 'text' AND j.value = ?1]], {old}))) do
                        assert(db:execute("UPDATE bee_session_trait_intervals SET declaration_json = json_set(declaration_json, ?, ?) WHERE rowid = ?", {row.path, new, row.row_id}))
                    end
                end
            end)
        end)
    end)
end)
