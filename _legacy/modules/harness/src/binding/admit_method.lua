-- MIT. Launch method admit: the caller's actor, one operation.
local admission = require("admission")
 local function handle(request: unknown): admission.Reply
    return admission.admit(request)
end
return {handle = handle}
