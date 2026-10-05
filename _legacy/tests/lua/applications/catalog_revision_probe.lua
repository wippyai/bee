-- MIT.
local catalog = require("catalog")

type Request = {workspace_id: string}

local function run(request: Request): string
    return catalog.revision(request.workspace_id)
end

return {run = run}
