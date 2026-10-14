-- MIT. Replica fixtures remove their synthetic sources after their assertions.
local replicas = require("replicas")
local M = {}

function M.run(cases, sources: {string}, options)
    local ok, result = pcall(cases, options)
    local store = assert(replicas.open())
    local tx = assert(store.db:begin())
    for _, source in ipairs(sources) do
        for _, table_name in ipairs({"bee_sync_replica_chunks", "bee_sync_replica_transfers",
            "bee_sync_replica_versions", "bee_sync_replica_sources"}) do
            local _, problem = tx:execute("DELETE FROM " .. table_name .. " WHERE source_owner = ?", {source})
            assert(not problem, tostring(problem))
        end
    end
    assert(tx:commit())
    assert(replicas.close(store))
    if not ok then error(tostring(result)) end
    return result
end

return M
