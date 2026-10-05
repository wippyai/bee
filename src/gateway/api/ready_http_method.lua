-- MIT. GET /ready?nonce=…: the listener answers with the generation the
-- store and the supervisor hold and a proof over the nonce under the
-- listener secret, so bee.gateway.binding:ready can tell this gateway's answer
-- from any other process on the port. It carries no binding.
local http = require("http")
local gateway = require("gateway")
local function handle(): nil
    local request = http.request()
    local response = http.response()
    if not request or not response then return nil end
    response:set_content_type(http.CONTENT.JSON)
    local nonce = request:query("nonce")
    if not nonce or nonce == "" or #nonce > 128 then
        response:set_status(http.STATUS.BAD_REQUEST)
        response:write_json({error = {code = "INVALID", message = "nonce required"}})
        return nil
    end
    local report, failure = gateway.ready_report(nonce)
    if not report then
        response:set_status(http.STATUS.SERVICE_UNAVAILABLE)
        response:write_json({error = failure and failure.error or {code = "UNAVAILABLE", message = "not ready"}})
        return nil
    end
    response:set_status(http.STATUS.OK)
    response:write_json(report)
    return nil
end
return {handle = handle}
