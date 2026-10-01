-- MIT. The pure OpenCode configuration contract: the carrier and placement
-- select both this method and its gateway from their pinned host records.
-- OpenCode takes no provider entry: models stay user-configured, so a
-- request naming one is refused rather than rendered.
local configuration = require("configuration")
local configure_protocol = require("configure_protocol")
local universal = require("universal")
local function handle(request: configure_protocol.Request): {[string]: unknown}
    if request.provider_ref or request.provider then
        return {ok = false, error = "opencode configures no model provider; the user selects models in their own OpenCode home"}
    end
    local prompt_files: {configure_protocol.Configuration} = {}
    local prompt_path: string? = nil
    if request.instructions then
        if not request.home_directory then return {ok = false, error = "Prompt append requires a private home"} end
        prompt_path = request.home_directory .. "/" .. assert(request.instructions_path)
    end
    if (not request.gateway or #request.gateway.tools == 0) and not prompt_path then
        if request.gateway then
            for _, event in ipairs(request.gateway.hooks) do
                return {ok = false, error = "opencode does not support gateway hook event " .. event}
            end
        end
        if request.private_home ~= true then return {ok = true, delivery = {arguments = {}, files = {}}} end
        local file, file_error = configuration.login_configuration()
        if not file then return {ok = false, error = tostring(file_error)} end
        return {ok = true, delivery = {arguments = {}, files = {file}}}
    end
    local no_tools: {string} = {}
    local no_hooks: {string} = {}
    local empty_gateway: configure_protocol.GatewayInput = {endpoint = "", action_id = "", tools = no_tools, hooks = no_hooks, token_environment = "BEE_UNUSED"}
    local gateway = request.gateway or empty_gateway
    local file, file_error = configuration.settings_file(gateway, prompt_path)
    if not file then return {ok = false, error = tostring(file_error)} end
    prompt_files[#prompt_files + 1] = file
    return {ok = true, delivery = {arguments = {}, files = prompt_files}}
end
return {handle = universal.configure("opencode", {opencode = handle}, "bee.driver.opencode.descriptor:cli")}
