-- MIT. The pure OpenCode configuration contract: the carrier and placement
-- select both this method and its gateway from their pinned host records.
-- OpenCode takes no provider entry: models stay user-configured, so a
-- request naming one is refused rather than rendered.
local configuration = require("configuration")
local configure_protocol = require("configure_protocol")
local universal = require("universal")
local observer_events = require("observer_events")
local bounds = require("bounds")
local function handle(request: configure_protocol.Request): {[string]: unknown}
    if request.provider_ref or request.provider then
        return {ok = false, error = "opencode configures no model provider; the user selects models in their own OpenCode home"}
    end
    local files: {configure_protocol.Configuration} = {}
    local gateway = request.gateway
    if gateway then
        for _, event in ipairs(gateway.hooks) do
            if not bounds.member(event, observer_events.HOOKS) then return {ok = false, error = "opencode does not support gateway hook event " .. event} end
        end
    end
    if gateway and #gateway.tools > 0 then
        local file, err = configuration.settings_file(gateway)
        if not file then return {ok = false, error = tostring(err)} end
        files[#files + 1] = file
    elseif request.private_home == true then
        local file, err = configuration.login_configuration()
        if not file then return {ok = false, error = tostring(err)} end
        files[#files + 1] = file
    end
    return {ok = true, delivery = {arguments = {}, files = files}}
end
return {handle = universal.configure("opencode", {opencode = handle}, "bee.driver.opencode.descriptor:cli")}
