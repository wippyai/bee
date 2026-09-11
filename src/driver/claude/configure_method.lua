-- MIT. Claude uses its host-selected environment projection and has no
-- provider file. The explicit nil result keeps that decision in the contract.
local configure_protocol = require("configure_protocol")
local function handle(value: unknown): {[string]: unknown}
    local request, request_error = configure_protocol.decode_request(value)
    if not request then return {ok = false, error = request_error or "invalid configuration request"} end
    if request.provider_ref ~= nil or request.provider ~= nil or request.gateway_section ~= nil then
        return {ok = false, error = "claude accepts no provider configuration"}
    end
    return {ok = true, configuration = nil}
end
return {handle = handle}
