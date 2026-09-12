-- MIT. Runtime retains the authenticated caller while adding only store access.
local authoring = require("authoring")
local function handle(request: unknown): authoring.Result
    return authoring.call(request)
end
return {handle = handle}
