-- SPDX-License-Identifier: MIT
-- Inject two boot/retry failures, then prove the supervisor retries to recovery.
local sql = require("sql")
local function pending(): boolean
    local db = assert(sql.get("bee:db"))
    assert(db:execute("INSERT INTO bee_test_boot_probe (attempt) VALUES (1)"))
    local rows = assert(db:query("SELECT COUNT(*) AS attempts FROM bee_test_boot_probe"))
    db:release()
    if assert(tonumber(rows[1].attempts)) <= 2 then error("injected Gateway boot backlog failure") end
    return false
end
return {pending = pending}
