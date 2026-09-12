-- MIT. Driver method prepare for agy: a declarative launch specification.
local launch = require("launch")
local types = require("types")

local function handle(request: unknown): {ok: boolean, error: string?, launch: types.Launch?}
    local decoded, err = launch.decode(request)
    if not decoded then return {ok = false, error = err} end
    return {ok = true, launch = launch.specification(decoded)}
end

return {handle = handle}
