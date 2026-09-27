-- MIT. The module's linked resources: the receipts database, the placement
-- root, the executor and the runner host. The host fills the references
-- through requirements; nothing here names a resource directly.
local registry = require("registry")
local bounds = require("bounds")
local resource_authority = require("resource_authority")
local M = {}
M.DATABASE_REF = "bee.placement.native:database_ref"
M.ROOT_REF = "bee.placement.native:root_ref"
M.RUNNER = "bee.placement.native.service:runner"
M.RUNNER_HOST_REF = "bee.placement.native:runner_host_ref"
M.EXECUTOR_REF = "bee.placement.native:executor_ref"
M.HOST_FILES_REF = "bee.placement.native:host_files_ref"
M.ADMITTED_ROOTS_REF = "bee.placement.native:admitted_roots_ref"
M.RESOURCE_MODE_REF = "bee.placement.native:resource_mode_ref"
M.WORKDIR_PREPARERS_REF = "bee.placement.native:workdir_preparers_ref"
M.RESOLVE = "bee.resources.binding:resolve"
M.CREDENTIAL_CHECK = "bee.credentials.binding:check"
M.CREDENTIAL_MATERIALIZE = "bee.credentials.binding:materialize"
M.CREDENTIAL_WRITE_BACK = "bee.credentials.binding:write_back"
M.GATEWAY_CHECK = "bee.gateway.binding:check"
M.GATEWAY_MATERIALIZE = "bee.gateway.binding:materialize"
M.GATEWAY_REVOKE = "bee.gateway.binding:revoke"
M.GATEWAY_SEAL = "bee.gateway.binding:seal"
M.GATEWAY_REVOKE_ATTEMPT = "bee.gateway.binding:revoke_attempt"
M.GATEWAY_AUTHORIZE = "bee.gateway.binding:authorize_materialization"
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
function M.executor(): (string?, string?)
    return reference(M.EXECUTOR_REF, "resource_ref", "placement executor")
end
function M.host_files(): (string?, string?)
    return reference(M.HOST_FILES_REF, "resource_ref", "host files")
end
-- The host's admitted resource roots: fs.directory entries a launch may
-- name, each with the widest access the host allows. This is host policy,
-- not a delegated grant; a request naming any other root or wider access
-- is refused at prepare.
function M.admitted_roots(): ({[string]: string}?, string?)
    local root_ref, root_error = reference(M.ADMITTED_ROOTS_REF, "resource_ref", "admitted roots")
    if not root_ref then return nil, root_error end
    local entry, err = registry.get(root_ref)
    if err or not entry then return nil, "admitted roots unavailable" end
    local data = bounds.object(entry.data)
    if not data then return nil, "admitted roots declaration is not an object" end
    local unknown_field = bounds.fields(data, {"roots"})
    if unknown_field then return nil, "admitted roots: " .. unknown_field end
    if data.roots == nil then return {}, nil end
    return resource_authority.decode_roots(data.roots)
end
-- The host's resource mode: host_configured roots, or grants resolved by
-- the resource authority. The host selects it; a request cannot.
type ResourceMode = "granted" | "host_configured"
type ResourceModeErrorCode = "UNAVAILABLE" | "INVALID"
function M.resource_mode(): (ResourceMode?, string?, ResourceModeErrorCode?)
    local mode_ref, reference_error = reference(M.RESOURCE_MODE_REF, "resource_ref", "resource mode")
    if not mode_ref then return nil, reference_error or "resource mode is not linked", "UNAVAILABLE" end
    local entry, err = registry.get(mode_ref)
    if err or not entry then return nil, "resource mode is unavailable", "UNAVAILABLE" end
    local data = bounds.object(entry.data)
    if not data then return nil, "resource mode declaration is not an object", "INVALID" end
    local unknown_field = bounds.fields(data, {"mode"})
    if unknown_field then return nil, "resource mode: " .. unknown_field, "INVALID" end
    if data.mode == "granted" then return "granted", nil, nil end
    if data.mode == "host_configured" then return "host_configured", nil, nil end
    return nil, "resource mode must be granted or host_configured", "INVALID"
end
-- The OS directory behind an admitted fs.directory root.
function M.directory(root_ref: string): (string?, string?)
    return resource_authority.directory(root_ref)
end
function M.workdir_preparers(): ({string}?, string?)
    local ref, ref_error = reference(M.WORKDIR_PREPARERS_REF, "resource_ref", "workdir preparers")
    if not ref then return nil, ref_error end
    local entry, err = registry.get(ref)
    if err or not entry then return nil, "workdir preparers entry unavailable" end
    local data = bounds.object(entry.data)
    if not data then return nil, "workdir preparers declaration is not an object" end
    local extra = bounds.fields(data, {"preparers"})
    if extra then return nil, extra end
    local preparers = bounds.array(data.preparers, 32)
    if not preparers then return nil, "preparers must be a dense bounded array" end
    local result: {string} = {}
    local seen: {[string]: boolean} = {}
    for _, item in ipairs(preparers) do
        local id = bounds.id(item)
        if not id or seen[id] then return nil, "invalid or duplicate preparer binding" end
        seen[id] = true
        result[#result + 1] = id
    end
    return result, nil
end
return M
