-- MIT. The module's linked resources: the receipts database, the placement
-- root, the executor and the runner host. The host fills the references
-- through requirements; nothing here names a resource directly.
local registry = require("registry")
local env = require("env")
local system = require("system")
local M = {}
M.DATABASE_REF = "bee.placement.native:database_ref"
M.ROOT_REF = "bee.placement.native:root_ref"
M.EXECUTOR = "bee.placement.native:executor"
M.RUNNER = "bee.placement.native:runner"
M.RUNNER_HOST_REF = "bee.placement.native:runner_host_ref"
M.ADMITTED_ROOTS = "bee.placement.native:admitted_roots"
-- The host filesystem, read for executable measurement only.
M.HOST_FILES = "bee.placement.native:host_files"
M.RESOURCE_MODE = "bee.placement.native:resource_mode"
M.RESOLVE = "bee.resources.binding:resolve"
M.CREDENTIAL_CHECK = "bee.credentials:check"
M.CREDENTIAL_MATERIALIZE = "bee.credentials:materialize"
M.GATEWAY_CHECK = "bee.gateway:check"
M.GATEWAY_MATERIALIZE = "bee.gateway:materialize"
M.GATEWAY_REVOKE = "bee.gateway:revoke"
M.GATEWAY_SEAL = "bee.gateway:seal"
M.GATEWAY_REVOKE_ATTEMPT = "bee.gateway:revoke_attempt"
M.GATEWAY_AUTHORIZE = "bee.gateway:authorize_materialization"
local function reference(id: string, field: string, label: string): (string?, string?)
    local entry, err = registry.get(id)
    if err or not entry then return nil, label .. " reference unavailable" end
    local data = entry.data
    local ref = type(data) == "table" and data[field] or nil
    if type(ref) ~= "string" or ref == "" then return nil, label .. " reference is not linked" end
    return ref, nil
end
function M.database(): (string?, string?)
    return reference(M.DATABASE_REF, "resource_ref", "placement database")
end
function M.root(): (string?, string?)
    return reference(M.ROOT_REF, "resource_ref", "placement root")
end
function M.runner_host(): (string?, string?)
    return reference(M.RUNNER_HOST_REF, "host_ref", "placement runner host")
end
-- The host's admitted resource roots: fs.directory entries a launch may
-- name, each with the widest access the host allows. This is host policy,
-- not a delegated grant; a request naming any other root or wider access
-- is refused at prepare.
function M.admitted_roots(): ({[string]: string}?, string?)
    local entry, err = registry.get(M.ADMITTED_ROOTS)
    if err or not entry then return nil, "admitted roots unavailable" end
    local data = entry.data
    local roots: {[string]: string} = {}
    local list = type(data) == "table" and data.roots or nil
    if type(list) ~= "table" then return roots, nil end
    for _, item in ipairs(list :: {unknown}) do
        if type(item) == "table" then
            local declared = item :: {[string]: unknown}
            if type(declared.root_ref) == "string" and (declared.access == "read" or declared.access == "write") then
                roots[declared.root_ref :: string] = declared.access :: string
            end
        end
    end
    return roots, nil
end
-- The host's resource mode: host_configured roots, or grants resolved by
-- the resource authority. The host selects it; a request cannot.
function M.resource_mode(): string
    local entry, err = registry.get(M.RESOURCE_MODE)
    if err or not entry then return "host_configured" end
    local data = entry.data
    local mode = type(data) == "table" and data.mode or nil
    if mode == "granted" then return "granted" end
    return "host_configured"
end
-- The OS directory behind an admitted fs.directory root.
function M.directory(root_ref: string): (string?, string?)
    local entry, err = registry.get(root_ref)
    if err or not entry then return nil, "resource root " .. root_ref .. " is not in the registry" end
    if entry.kind ~= "fs.directory" then return nil, "resource root " .. root_ref .. " is not a directory" end
    local data = entry.data
    local directory = type(data) == "table" and data.directory or nil
    if type(directory) ~= "string" or directory == "" then return nil, "resource root " .. root_ref .. " has no directory" end
    -- The registry hands back the declared text; an ${env:entry} placeholder
    -- is resolved through the declared variable it names, as the runtime
    -- does when it mounts the directory.
    local variable, rest = directory:match("^%${env:([^}]+)}(.*)$")
    if variable then
        local value, env_error = env.get(variable)
        if env_error or type(value) ~= "string" or value == "" then return nil, "resource root " .. root_ref .. " names an unset variable " .. variable end
        directory = value .. rest
    end
    if directory:find("%${") then return nil, "resource root " .. root_ref .. " has an unresolved placeholder" end
    -- Children receive this path as their home or working directory, so it
    -- is made absolute against the runtime's own working directory.
    if not directory:find("^/") then
        local cwd, cwd_error = system.process.cwd()
        if cwd_error or type(cwd) ~= "string" or cwd == "" then return nil, "resource root " .. root_ref .. " is relative and the working directory is unavailable" end
        directory = cwd .. "/" .. directory:gsub("^%./", "")
    end
    return directory, nil
end
return M
