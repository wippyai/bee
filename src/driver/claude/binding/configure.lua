-- MIT. Claude receives fresh MCP and hook settings as exact argv literals.
local configure_protocol = require("configure_protocol")
local canonical = require("canonical")
local universal = require("universal")
local quote = require("quote")
local function gateway_delivery(gateway)
    if not gateway then return {arguments = {"--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}'}, files = {}}, nil end
    local url = "http://" .. gateway.endpoint .. "/mcp/" .. gateway.action_id
    local mcp, mcp_error = canonical.encode({mcpServers = {bee = {type = "http", url = url,
        headers = {Authorization = "Bearer ${" .. gateway.token_environment .. "}"}}}})
    if not mcp then return nil, mcp_error end
    -- Settings carry only the hook handlers; a gateway without hooks passes
    -- none, since Claude reads a settings literal it cannot parse as a path.
    if #gateway.hooks == 0 then return {arguments = {"--strict-mcp-config", "--mcp-config", mcp}, files = {}}, nil end
    local hook_url = "http://" .. gateway.endpoint .. "/hook/" .. gateway.action_id
    local hook_token = gateway.hook_token_environment
    if not hook_token then return nil, "Claude hooks require a token environment" end
    local handler = {type = "http", url = hook_url, headers = {Authorization = "Bearer ${" .. hook_token .. "}"}, allowedEnvVars = {gateway.hook_token_environment}, timeout = 2}
    local events = {}
    for _, event in ipairs(gateway.hooks) do
        local event_handler: {[string]: unknown}
        if event == "SessionStart" then
            -- Claude runs only command and MCP tool hooks at session start; the
            -- host hook command posts the event to the same gateway hook.
            if not gateway.hook_command then return nil, "Claude session start hooks require the host-selected hook command" end
            event_handler = {type = "command", command = quote.line({gateway.hook_command, "hook-post", gateway.endpoint, gateway.action_id, hook_token, event}), timeout = 3}
        else
            event_handler = {type = handler.type, url = handler.url, headers = handler.headers,
                allowedEnvVars = handler.allowedEnvVars, timeout = event == "PermissionRequest" and 650 or 2}
        end
        events[event] = {{matcher = "", hooks = {event_handler}}}
    end
    local settings, settings_error = canonical.encode({hooks = events, allowedHttpHookUrls = {hook_url},
        httpHookAllowedEnvVars = {gateway.hook_token_environment}})
    if not settings then return nil, settings_error end
    return {arguments = {"--strict-mcp-config", "--mcp-config", mcp, "--settings", settings}, files = {}}, nil
end
local function handle(request: configure_protocol.Request): {[string]: unknown}
    if request.provider_ref ~= nil or request.provider ~= nil then
        return {ok = false, error = "claude accepts no provider configuration"}
    end
    local delivery, delivery_error = gateway_delivery(request.gateway)
    if not delivery then return {ok = false, error = tostring(delivery_error)} end
    return {ok = true, delivery = delivery}
end
return {handle = universal.configure("claude", {claude = handle}, "bee.driver.claude.descriptor:cli")}
