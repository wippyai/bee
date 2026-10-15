-- SPDX-License-Identifier: MIT
local sql = require("sql")
local function pending(): boolean
    local db = assert(sql.get("bee:db"))
    local rows, problem = db:query("SELECT run_id FROM bee_node_test_runs WHERE state IN ('pending', 'running') LIMIT 1")
    db:release()
    if not rows then error(problem) end
    return #rows > 0
end
return {pending = pending}
