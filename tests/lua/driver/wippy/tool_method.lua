-- MIT. Test tool implementation for native driver test suite.
local function handle(value: unknown): {[string]: unknown}
    return {ok = true, value = value}
end

return {handle = handle}
