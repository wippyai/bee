-- MIT. Linked references of the resource authority: the store and the
-- host's admitted roots, the ceiling every association stays under.
local registry = require("registry")
local env = require("env")
local system = require("system")
local bounds = require("bounds")
local M = {}
M.DATABASE_REF = "bee.resources.env:database_ref"
M.ROOTS_REF = "bee.resources.env:roots_ref"
M.MAX_ROOTS = 64
local function reference(id: string, field: string, label: string): (string?, string?)
    local entry, err = registry.get(id)
    if err or not entry then return nil, label .. " reference unavailable" end
    local data = entry.data
    local ref = type(data) == "table" and data[field] or nil
    if type(ref) ~= "string" or ref == "" then return nil, label .. " reference is not linked" end
    return ref, nil
end
function M.database(): (string?, string?)
    return reference(M.DATABASE_REF, "resource_ref", "resource database")
end
function M.decode_roots(value: unknown): ({[string]: string}?, string?)
    local rows, array_error = bounds.array(value, M.MAX_ROOTS)
    if not rows then return nil, "host roots must be a bounded dense list: " .. tostring(array_error) end
    local roots: {[string]: string} = {}
    for index, raw in ipairs(rows) do
        local item = bounds.object(raw)
        if not item then return nil, "host roots[" .. tostring(index) .. "] must be an object" end
        local unknown_field = bounds.fields(item, {"root_ref", "access"})
        if unknown_field then return nil, "host roots[" .. tostring(index) .. "]: " .. unknown_field end
        local root_ref = bounds.id(item.root_ref)
        local access = bounds.member(item.access, {"read", "write"})
        if not root_ref or not access then return nil, "host roots[" .. tostring(index) .. "] has an invalid root or access" end
        if roots[root_ref] then return nil, "host roots repeat " .. root_ref end
        roots[root_ref] = access
    end
    return roots, nil
end
-- Host roots: fs.directory entries with the widest access the host allows.
function M.host_roots(): ({[string]: string}?, string?)
    local roots_entry, roots_error = reference(M.ROOTS_REF, "resource_ref", "host roots")
    if not roots_entry then return nil, roots_error end
    local entry, err = registry.get(roots_entry)
    if err or not entry then return nil, "host roots unavailable" end
    local data = bounds.object(entry.data)
    if not data then return nil, "host roots declaration is not an object" end
    local unknown_field = bounds.fields(data, {"roots"})
    if unknown_field then return nil, "host roots: " .. unknown_field end
    if data.roots == nil then return {}, nil end
    return M.decode_roots(data.roots)
end
local function resolve_directory(directory: string, root_ref: string): (string?, string?)
    local variable, rest = directory:match("^%${env:([^}]+)}(.*)$")
    if variable then
        local value, env_error = env.get(variable)
        if env_error or type(value) ~= "string" or value == "" then
            return nil, "resource root " .. root_ref .. " names an unset variable " .. variable
        end
        directory = value .. rest
    end
    if directory:find("%${") then return nil, "resource root " .. root_ref .. " has an unresolved placeholder" end
    if not directory:find("^/") then
        local cwd, cwd_error = system.process.cwd()
        if cwd_error or type(cwd) ~= "string" or cwd == "" then
            return nil, "resource root " .. root_ref .. " is relative and the working directory is unavailable"
        end
        directory = cwd .. "/" .. directory:gsub("^%./", "")
    end
    return directory, nil
end
function M.directory(root_ref: string): (string?, string?)
    local entry, err = registry.get(root_ref)
    if err or not entry then return nil, "resource root " .. root_ref .. " is not in the registry" end
    if entry.kind ~= "fs.directory" then return nil, "resource root " .. root_ref .. " is not a directory" end
    local data = bounds.object(entry.data)
    local directory = data and bounds.text(data.directory)
    if not directory or directory == "" then return nil, "resource root " .. root_ref .. " has no directory" end
    return resolve_directory(directory, root_ref)
end
-- The fs.directory entry behind a root, as it is now.
function M.root(root_ref: string): ({[string]: unknown}?, string?)
    local entry, err = registry.get(root_ref)
    if err or not entry then return nil, "resource root " .. root_ref .. " is not in the registry" end
    if entry.kind ~= "fs.directory" then return nil, "resource root " .. root_ref .. " is not a directory" end
    local data = bounds.object(entry.data)
    local directory = data and bounds.text(data.directory)
    if not directory or directory == "" then return nil, "resource root " .. root_ref .. " has no directory" end
    -- Resource identity follows the resolved host path. Keeping only the
    -- registry placeholder in the digest would let a changed host cwd or
    -- host-selected variable silently retarget an existing grant.
    local resolved, resolve_error = resolve_directory(directory, root_ref)
    if not resolved then return nil, resolve_error end
    local resolved_data: {[string]: unknown} = {}
    if type(data) == "table" then
        for key, value in pairs(data) do resolved_data[key] = value end
    end
    resolved_data.directory = resolved
    return {kind = entry.kind, meta = entry.meta, data = resolved_data}, nil
end
return M
