-- MIT. Launch method start: the caller's actor, one operation.
local admission = require("admission")
 local function handle(request: unknown): admission.Reply
    return admission.start(request)
end
return {handle = handle}
