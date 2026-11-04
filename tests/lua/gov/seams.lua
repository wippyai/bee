-- SPDX-License-Identifier: MIT
local sql = require("sql")

return {
    ["bee.gov.service.started"] = function()
        local db = assert(sql.get("bee:db"))
        assert(db:execute("INSERT INTO bee_test_recovery_starts VALUES (1)"))
        db:release()
        return nil
    end,
}
