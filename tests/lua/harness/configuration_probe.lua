-- MIT. Test-only driver requiring inputs that only placement can select.
local configuration = require("configuration")
local function handle(value: unknown): {[string]: unknown}
    local request, err = configuration.decode_request(value)
    if not request then return {ok = false, error = err or "invalid request"} end
    if not request.home_directory then return {ok = false, error = "placement HOME required"} end
    return {ok = true, delivery = {arguments = {"--fixture-home", request.home_directory}, files = {}}}
end
return {handle = handle}
