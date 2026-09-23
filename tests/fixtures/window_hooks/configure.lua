-- MIT. Render the fixture child's hook transport from admitted driver input.
-- A host-selected hook command yields one command per event, as command-hook
-- harnesses receive it; otherwise the child posts to the endpoint URL itself.
local M = {}
function M.configure(value: unknown): {[string]: unknown}
    local configuration = require("configuration")
    local hash = require("hash")
    local quote = require("quote")
    local request, request_error = configuration.decode_request(value)
    if not request then return {ok = false, error = request_error} end
    local gateway = request.gateway
    if not gateway then return {ok = true, delivery = {arguments = {}, files = {}}} end
    local files: {{[string]: unknown}} = {}
    local function add(path: string, content: string): string?
        local digest, digest_error = hash.sha256(content)
        if not digest then return tostring(digest_error) end
        table.insert(files, {revision = "bee.window-hooks-fixture@1", path = path, content = content, digest = digest,
            provider_ref = "bee:gateway_endpoint"})
        return nil
    end
    local executable = gateway.hook_command
    if executable then
        local token = gateway.hook_token_environment
        if not token then return {ok = false, error = "hook command requires a hook credential environment"} end
        for _, event in ipairs(gateway.hooks) do
            local failed = add("hook-" .. event, quote.line({executable, "hook-post", gateway.endpoint, gateway.action_id, token, event}) .. "\n")
            if failed then return {ok = false, error = failed} end
        end
    else
        local failed = add("hook-url", "http://" .. gateway.endpoint .. "/hook/" .. gateway.action_id .. "\n")
        if failed then return {ok = false, error = failed} end
    end
    return {ok = true, delivery = {arguments = {}, files = files}}
end

return M
