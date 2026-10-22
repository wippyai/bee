local sql = require("sql")
local bounds = require("bounds")
local function handle(value: unknown): unknown
    local input = assert(bounds.object(value))
    local db = assert(sql.get("bee:db"))
    local _, err = db:execute("INSERT INTO bee_test_hook_calls(text) VALUES (?)", {input.text})
    db:release()
    assert(not err, tostring(err))
    return input.mode == "large_output" and string.rep("original", 700) or input.text
end
return {handle = handle}
