-- MIT. Authority method retire_app_alias: the broker ends family inheritance
-- when it closes an application instance.
local boundary = require("boundary")
local app_alias = require("app_alias")
local types = require("types")
local function handle(request: unknown): types.Reply
    return boundary.run(app_alias.retire, request)
end
return {handle = handle}
