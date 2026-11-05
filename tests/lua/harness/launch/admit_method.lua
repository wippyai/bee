-- MIT. Launch method admit: the caller's actor, one operation.
local admission = require("admission")
local resolution = require("resolution")
 local function handle(request: unknown): resolution.Reply
    return admission.admit(request)
end
return {handle = handle}
