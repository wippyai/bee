local sql = require("sql")
local function handle(offset: integer): {[string]: unknown}
    local db = assert(sql.get("bee:db"))
    local _, err = db:execute("UPDATE bee_test_hook_clock SET offset_ms=? WHERE id=1", {offset})
    db:release()
    assert(not err, tostring(err))
    return {ok = true, value = {}}
end
return {handle = handle}
