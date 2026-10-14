-- MIT. Driver method configure for native Wippy driver: the in-process
-- runner projects nothing into files or arguments, so only a request
-- without provider, gateway or instructions delivers empty.
local configuration = require("configuration")

local function handle(value: unknown): {[string]: unknown}
    local request, request_error = configuration.decode_request(value)
    if not request then return {ok = false, error = request_error or "invalid configuration request"} end
    if request.provider_ref or request.provider then
        return {ok = false, error = "native driver projects no provider configuration"}
    end
    if request.gateway then
        return {ok = false, error = "native driver projects no gateway configuration"}
    end
    if request.instructions or request.instruction_builder then
        return {ok = false, error = "native driver projects no instructions file"}
    end
    return {
        ok = true,
        delivery = {
            arguments = {},
            files = {},
        },
    }
end

return {handle = handle}
