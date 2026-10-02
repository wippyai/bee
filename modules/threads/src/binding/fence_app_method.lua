-- MIT. Authority method fence_app: the trusted broker deactivates the
-- stable family's active threads after admission loss.
local boundary = require("boundary")
local app_alias = require("app_alias")
local types = require("types")
local function handle(request: unknown): types.Reply
    return boundary.run(app_alias.fence, request, true)
end
return {handle = handle}
