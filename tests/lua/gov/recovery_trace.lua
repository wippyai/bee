-- SPDX-License-Identifier: MIT
local sql = require("sql")
local function record()
    local db = assert(sql.get("bee:db"))
    assert(db:execute("CREATE TABLE IF NOT EXISTS bee_test_recovery_starts (started INTEGER NOT NULL)"))
    assert(db:execute("INSERT INTO bee_test_recovery_starts VALUES (1)"))
    db:release()
end
return {record = record}
