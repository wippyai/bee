-- MIT. Authority method register_app_alias: the broker attests an app instance
-- opened for the stable app and backfills retained instances at startup.
local boundary = require("boundary")
local app_alias = require("app_alias")
local types = require("types")
local function handle(request: unknown): types.Reply
    return boundary.run(app_alias.register, request)
end
return {handle = handle}
