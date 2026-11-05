-- MIT. Launch environment resolution: environment values, working directory and admitted write roots.
local env = require("env")
local sql = require("sql")
local resources = require("resources")
local types = require("types")
local paths = require("paths")
local workdir_preparers = require("workdir_preparers")
local writable_roots = require("writable_roots")
local M = {}
local function resolve_environment(request: types.LaunchRequest, home: string): ({[string]: string}?, string?)
    local values: {[string]: string} = {}
    for name, value in pairs(request.environment) do values[name] = value end
    for name, ref in pairs(request.environment_refs) do
        local value, err = env.get(ref)
        if err or type(value) ~= "string" then return nil, "environment " .. name .. " unavailable from " .. ref end
        values[name] = value
    end
    if request.environment_refs.HOME == "bee.env:machine_home" then
        local selected = values.HOME
        if not selected or selected:sub(1, 1) ~= "/" or selected:find("[%z\r\n]") then
            return nil, "host user home is unavailable"
        end
    else
        values.HOME = home
    end
    local provider_home = request.launch.provider_home
    if provider_home and provider_home.private and provider_home.variable and provider_home.directory then
        values[provider_home.variable] = home .. "/" .. provider_home.directory
    end
    if provider_home and provider_home.private then
        for _, item in ipairs(provider_home.extra_variables or {}) do values[item.variable] = home .. "/" .. item.directory end
    end
    return values, nil
end
local function resolve_work_dir(request: types.LaunchRequest, home: string): (string?, string?)
    local ref = request.launch.working_directory_ref
    if not ref then return home, nil end
    for _, grant in ipairs(request.resources) do
        if grant.name == ref then
            local directory, err = resources.directory(grant.root_ref)
            if not directory then return nil, err end
            if grant.subpath == "" then return directory, nil end
            return directory .. "/" .. grant.subpath, nil
        end
    end
    return nil, "working directory grant is missing"
end
local function admitted_roots(request: types.LaunchRequest, executor: string, write_only: boolean): ({string}?, string?)
    local roots: {string} = {}
    for _, grant in ipairs(request.resources) do
        if not write_only or grant.access == "write" then
            local root, root_error = resources.directory(grant.root_ref)
            if not root then return nil, root_error or "write-granted root unavailable" end
            if grant.subpath == "" then
                roots[#roots + 1] = root
            else
                local granted, granted_error = paths.admit(root .. "/" .. grant.subpath, {root}, executor)
                if not granted then return nil, "write grant " .. grant.name .. ": " .. tostring(granted_error) end
                roots[#roots + 1] = granted
            end
        end
    end
    return roots, nil
end
function M.write_roots(request: types.LaunchRequest, executor: string): ({string}?, string?)
    return admitted_roots(request, executor, true)
end
local function prepare_workdir_and_arguments(db: sql.DB, request: types.LaunchRequest, attempt_id: string, initial_work_dir: string): (string?, {string}?, string?)
    local executor, executor_error = resources.executor()
    if not executor then return nil, nil, executor_error or "placement executor unavailable" end
    local write_roots, roots_error = M.write_roots(request, executor)
    if not write_roots then return nil, nil, roots_error or "write-granted root unavailable" end
    local work_dir, extra_roots, preparer_error = workdir_preparers.setup(db, request, attempt_id, initial_work_dir, write_roots)
    if not work_dir or not extra_roots or preparer_error then
        return nil, nil, preparer_error or "workdir preparation failed"
    end
    local delivery = request.delivery
    local declared = delivery and delivery.git_writable_roots or nil
    if not declared or #extra_roots == 0 then
        return work_dir, {}, nil
    end
    local writable_workdir = false
    for _, grant in ipairs(request.resources) do
        if grant.name == request.launch.working_directory_ref and grant.access == "write" then writable_workdir = true end
    end
    if not writable_workdir or not writable_roots.enabled(declared, request.launch.argv) then
        return work_dir, {}, nil
    end
    local sandbox_args, args_error = writable_roots.arguments(declared, extra_roots)
    if not sandbox_args then
        return nil, nil, args_error or "render writable roots arguments"
    end
    return work_dir, sandbox_args, nil
end
M.resolve_environment = resolve_environment
M.resolve_work_dir = resolve_work_dir
M.admitted_roots = admitted_roots
M.prepare_workdir_and_arguments = prepare_workdir_and_arguments
return M
