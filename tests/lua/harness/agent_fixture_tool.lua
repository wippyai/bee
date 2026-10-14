-- MIT. Test-only framework tool target. The agent resolver reads the tool's
-- registry entry as data; nothing calls this entry in the suite.
local function handle(value: unknown): {[string]: unknown}
    return {ok = true, value = value}
end
return {handle = handle}
