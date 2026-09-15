-- MIT. Render the fixture child's endpoint from admitted driver input.
local M = {}
function M.configure(value: unknown): {[string]: unknown}
    local configuration = require("configuration")
    local hash = require("hash")
    local request, request_error = configuration.decode_request(value)
    if not request then return {ok = false, error = request_error} end
    local gateway = request.gateway
    if not gateway then return {ok = true, delivery = {arguments = {}, files = {}}} end
    local content = "http://" .. gateway.endpoint .. "/hook/" .. gateway.action_id .. "\n"
    local digest, digest_error = hash.sha256(content)
    if not digest then return {ok = false, error = tostring(digest_error)} end
    return {ok = true, delivery = {arguments = {}, files = {{revision = "bee.window-hooks-fixture@1",
        path = "hook-url", content = content, digest = digest, provider_ref = "bee:gateway_endpoint"}}}}
end

return M
