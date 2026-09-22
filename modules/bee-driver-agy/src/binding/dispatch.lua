-- MIT. Driver method dispatch for agy: the next turn is a new process
-- on the resumed session; there is no in-process input channel.
local launch = require("launch")
local types = require("types")

local function handle(request: unknown): {ok: boolean, error: string?, launch: types.Launch?}
    local decoded, err = launch.decode(request)
    if not decoded then return {ok = false, error = err} end
    if not decoded.resume_ref then return {ok = false, error = "a dispatched turn needs resume_ref"} end
    return {ok = true, launch = launch.specification(decoded)}
end

return {handle = handle}
