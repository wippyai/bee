-- SPDX-License-Identifier: MIT
local sql = require("sql")
local M: {[string]: (unknown?) -> unknown} = {}

M["bee.gov.service.started"] = function(): unknown
    local db = assert(sql.get("bee:db"))
    assert(db:execute("INSERT INTO bee_test_recovery_starts VALUES (1)"))
    db:release()
    return nil
end

M["bee.gov.service.backlog.disabled"] = function(): unknown return true end

return M
