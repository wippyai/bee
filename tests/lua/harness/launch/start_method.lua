-- MIT. Launch method start: the caller's actor, one operation.
local admission = require("admission")
local resolution = require("resolution")
 local function handle(request: unknown): resolution.Reply
    return admission.start(request)
end
return {handle = handle}
