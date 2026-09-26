-- MIT. Authority method register_app_alias: the broker attests the stable
-- app an instance was opened for.
local boundary = require("boundary")
local app_alias = require("app_alias")
local types = require("types")
local function handle(request: unknown): types.Reply
    return boundary.run(app_alias.register, request, true)
end
return {handle = handle}
