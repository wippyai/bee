-- MIT. Launch request checks run before intent and at materialization: required host files, login notice and environment ownership.
local env = require("env")
local fs = require("fs")
local resources = require("resources")
local types = require("types")
local M = {}
-- A launch may declare a host file it needs before it starts, named by the
-- environment variable that locates its directory plus a safe relative path,
-- or by the host home and a default directory. Placement checks existence
-- only through the read-only host volume: it never reads contents and never
-- copies the file into a private home. A missing file refuses before intent.
function M.required_file_missing(request: types.LaunchRequest): string?
    local required = request.launch.required_files
    if not required or #required == 0 then return nil end
    local host_files, host_files_error = resources.host_files()
    local volume = host_files and fs.get(host_files) or nil
    if not volume and host_files_error then return "host files are unavailable: " .. host_files_error end
    if not volume then return "host files are unavailable for " .. request.launch.executable .. "'s required file" end
    for _, file in ipairs(required) do
        local directory = request.environment[file.variable]
        if directory ~= nil and directory == "" then directory = nil end
        local variable_ref = request.environment_refs[file.variable]
        if directory == nil and variable_ref ~= nil then
            local resolved, resolve_error = env.get(variable_ref)
            if not resolve_error and type(resolved) == "string" and resolved ~= "" then directory = resolved end
        end
        if directory == nil then
            local home = request.environment.HOME
            if home ~= nil and home == "" then home = nil end
            if home == nil and request.environment_refs.HOME == "bee.env:machine_home" then
                local resolved, resolve_error = env.get("bee.env:machine_home")
                if not resolve_error and type(resolved) == "string" and resolved ~= "" then home = resolved end
            end
            if home == nil then return "the launch requires " .. file.path .. " and its host home is unavailable" end
            if file.default_directory then directory = home .. "/" .. file.default_directory else directory = home end
        end
        if volume:exists(directory .. "/" .. file.path) ~= true then
            return "the required host file " .. file.path .. " is not installed in " .. directory
        end
    end
    return nil
end
-- The warning is advisory. An evidence file may be created by the provider's
-- sign-in flow after prepare, so this examines existence only at prepare time.
-- All declared paths are already decoded as safe relative paths.
function M.login_notice(request: types.LaunchRequest, selected_home: string,
    is_file: (string) -> boolean?, projected_login_path: string?): types.LoginNotice?
    local login = request.launch.login
    if request.profile_id ~= "window" or not login then return nil end
    if selected_home:sub(1, 1) ~= "/" then return nil end
    for _, file in ipairs(login.files) do
        local directory = request.environment[file.variable]
        if directory == "" then directory = nil end
        if file.variable == "HOME" then directory = selected_home end
        if not directory then
            directory = selected_home
            if file.default_directory then directory = directory .. "/" .. file.default_directory end
        end
        -- A relative override depends on the eventual working directory and
        -- cannot be diagnosed from this home without guessing.
        if directory:sub(1, 1) ~= "/" or directory:find("[%z\r\n]") then return nil end
        local path = directory .. "/" .. file.path
        if path == projected_login_path then return nil end
        local present = is_file(path)
        if present == nil or present == true then return nil end
    end
    -- This advisory has no authority to execute a status command or inspect
    -- environment credentials. Unobserved alternatives leave login unknown.
    for _, evidence in ipairs(login.any_of or {}) do
        if evidence.kind ~= "file_exists" then return nil end
    end
    return {code = "LOGIN_REQUIRED", provider = login.provider, command = login.command}
end
function M.prepare_login_notice(request: types.LaunchRequest, private_home: string,
    projected_login_path: string?): types.LoginNotice?
    if request.profile_id ~= "window" or not request.launch.login then return nil end
    local selected_home = private_home
    if request.environment_refs.HOME == "bee.env:machine_home" then
        local resolved, err = env.get("bee.env:machine_home")
        if err or type(resolved) ~= "string" then return nil end
        selected_home = resolved
    end
    local host_files = resources.host_files()
    local volume = host_files and fs.get(host_files) or nil
    if not volume then return nil end
    return M.login_notice(request, selected_home, function(path: string): boolean?
        local info, stat_error = volume:stat(path)
        if info then return info.type == "file" and info.is_dir ~= true end
        if stat_error and stat_error:kind() == errors.NOT_FOUND then return false end
        return nil
    end, projected_login_path)
end
-- Native placement selects either its private home or the host's user home.
-- Arbitrary HOME values remain refused; an admitted gateway owns its tokens.
-- Check before intent and again when materializing a retained request.
function M.environment_conflict(request: types.LaunchRequest): string?
    local owners: {[string]: string} = {HOME = "native placement"}
    local provider_home = request.launch.provider_home
    if provider_home and provider_home.private and provider_home.variable then
        if owners[provider_home.variable] then return "provider-home variable " .. provider_home.variable .. " is already assigned" end
        owners[provider_home.variable] = "native provider home"
    end
    if provider_home and provider_home.private then
        for _, item in ipairs(provider_home.extra_variables or {}) do
            if owners[item.variable] then return "provider-home variable " .. item.variable .. " is already assigned" end
            owners[item.variable] = "native provider home"
        end
    end
    if request.gateway then
        local gateway = request.gateway
        if owners[gateway.destination] then return "gateway destination " .. gateway.destination .. " is owned by native placement" end
        owners[gateway.destination] = "gateway"
        if gateway.hook_destination then
            if owners[gateway.hook_destination] then return "hook destination " .. gateway.hook_destination .. " is already assigned" end
            owners[gateway.hook_destination] = "gateway hooks"
        end
    end
    for name, owner in pairs(owners) do
        local inherited_home = name == "HOME" and request.environment[name] == nil
            and request.environment_refs[name] == "bee.env:machine_home"
        if not inherited_home and (request.environment[name] ~= nil or request.environment_refs[name] ~= nil) then
            return "environment destination " .. name .. " is owned by " .. owner
        end
    end
    return nil
end
return M
