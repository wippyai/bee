-- MIT. The owner lifecycle function the supervised fixture service names; it
-- acknowledges no transition.
local function handle(_: unknown): {[string]: unknown}
    return {ok = false, message = "the fixture owner verifies no transition"}
end
return {handle = handle}
