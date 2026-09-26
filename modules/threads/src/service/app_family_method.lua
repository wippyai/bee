-- MIT. Authority method app_family: the broker reads the stable family's
-- active threads to fence them after admission loss.
local boundary = require("boundary")
local app_alias = require("app_alias")
local types = require("types")
local function handle(request: unknown): types.Reply
    return boundary.run(app_alias.family, request)
end
return {handle = handle}
