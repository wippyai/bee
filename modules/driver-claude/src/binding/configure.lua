-- MIT. Claude receives fresh MCP and hook settings as exact argv literals.
local configure_protocol = require("configure_protocol")
local canonical = require("canonical")
local function gateway_delivery(gateway)
    if not gateway then return {arguments = {}, files = {}}, nil end
    local url = "http://" .. gateway.endpoint .. "/mcp/" .. gateway.action_id
    local mcp, mcp_error = canonical.encode({mcpServers = {bee = {type = "http", url = url,
        headers = {Authorization = "Bearer ${" .. gateway.token_environment .. "}"}}}})
    if not mcp then return nil, mcp_error end
    -- Settings carry only the hook handlers; a gateway without hooks passes
    -- none, since Claude reads a settings literal it cannot parse as a path.
    if #gateway.hooks == 0 then return {arguments = {"--mcp-config", mcp}, files = {}}, nil end
    local hook_url = "http://" .. gateway.endpoint .. "/hook/" .. gateway.action_id
    local handler = {type = "http", url = hook_url, headers = {Authorization = "Bearer ${" .. (gateway.hook_token_environment :: string) .. "}"}, allowedEnvVars = {gateway.hook_token_environment}, timeout = 2}
    local events = {}
    for _, event in ipairs(gateway.hooks) do events[event] = {{matcher = "", hooks = {handler}}} end
    local settings, settings_error = canonical.encode({hooks = events, allowedHttpHookUrls = {hook_url},
        httpHookAllowedEnvVars = {gateway.hook_token_environment}})
    if not settings then return nil, settings_error end
    return {arguments = {"--mcp-config", mcp, "--settings", settings}, files = {}}, nil
end
local function handle(value: unknown): {[string]: unknown}
    local request, request_error = configure_protocol.decode_request(value)
    if not request then return {ok = false, error = request_error or "invalid configuration request"} end
    if request.provider_ref ~= nil or request.provider ~= nil then
        return {ok = false, error = "claude accepts no provider configuration"}
    end
    local delivery, delivery_error = gateway_delivery(request.gateway)
    if not delivery then return {ok = false, error = tostring(delivery_error)} end
    if request.instructions then
        delivery.arguments[#delivery.arguments + 1] = "--append-system-prompt"
        delivery.arguments[#delivery.arguments + 1] = request.instructions
    end
    return {ok = true, delivery = delivery}
end
return {handle = handle}
